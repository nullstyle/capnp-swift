// capnpc-driver: the D6 option-A pipeline (plan §6, §12). It runs the
// vendored wasm schema compiler under WasmKit (pure Swift, no Wasmtime, no
// Python), captures the CodeGeneratorRequest, and runs the native
// capnpc-swift plugin on it — the same split capnp-zig's capnp_tool.py uses
// (the compiler never spawns plugins; the driver does).
//
//   capnpc-driver --plugin <capnpc-swift> [--wasm <capnp.wasm>]
//                 [--include <dir>]... [--output-dir <dir>] [--check]
//                 <schema.capnp>...
//
// Paths are host paths; the driver computes their common root and maps it
// to "/" for the compiler (one WASI preopen), then relativizes every
// include, src-prefix and schema against it. The bundled standard schema
// tree (wasm/include) is always on the import path, like the toolchain's
// own -I<package>/include. --check regenerates into a temp dir and diffs
// the committed output instead of writing (exit 1 on any difference).

import Foundation
import WasmKit
import WasmKitWASI
import WASI

struct DriverError: Error, CustomStringConvertible {
    let description: String
}

@main
struct CapnpDriver {
    static func main() async {
        var plugin: String?
        var wasm: String?
        var includes: [String] = []
        var srcPrefixes: [String] = []
        var outputDir: String?
        var check = false
        var schemas: [String] = []

        var args: ArraySlice<String> = Array(CommandLine.arguments.dropFirst())[...]
        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "--plugin": if let v = args.popFirst() { plugin = v } else { fail("--plugin needs a path") }
            case "--wasm": if let v = args.popFirst() { wasm = v } else { fail("--wasm needs a path") }
            case "--include": if let v = args.popFirst() { includes.append(v) } else { fail("--include needs a path") }
            case "--src-prefix": if let v = args.popFirst() { srcPrefixes.append(v) } else { fail("--src-prefix needs a path") }
            case "--output-dir":
                if let v = args.popFirst() { outputDir = v } else { fail("--output-dir needs a path") }
            case let a where a.hasPrefix("--output-dir="):
                outputDir = String(a.dropFirst("--output-dir=".count))
            case "--check": check = true
            case let a where a.hasPrefix("-"): fail("unknown option \(a)")
            default: schemas.append(arg)
            }
        }
        guard !schemas.isEmpty else { fail("no schemas given") }

        // Locate the pieces. Defaults sit next to the driver binary (the
        // artifactbundle layout) or in the repo's known places (dev runs).
        let driverPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let driverDir = (driverPath as NSString).deletingLastPathComponent
        let repoRoot = findRepoRoot(from: driverDir)
        func firstExisting(_ candidates: [String]) -> String? {
            candidates.first { FileManager.default.fileExists(atPath: $0) }
        }
        let pluginBin = plugin
            ?? ProcessInfo.processInfo.environment["CAPNPC_SWIFT_PLUGIN"]
            ?? firstExisting([
                driverDir + "/capnpc-swift",
                repoRoot.map { $0 + "/tools/capnpc-swift/zig-out/bin/capnpc-swift" } ?? "",
            ].filter { !$0.isEmpty })
        let wasmBin = wasm
            ?? ProcessInfo.processInfo.environment["CAPNP_WASM"]
            ?? firstExisting([
                driverDir + "/capnp.wasm",
                repoRoot.map { $0 + "/tools/capnpc-swift/wasm/capnp.wasm" } ?? "",
            ].filter { !$0.isEmpty })
        let bundledInclude = firstExisting([
            driverDir + "/include",
            repoRoot.map { $0 + "/tools/capnpc-swift/wasm/include" } ?? "",
        ].filter { !$0.isEmpty })
        guard let pluginBin else { fail("cannot find capnpc-swift (pass --plugin or set CAPNPC_SWIFT_PLUGIN)") }
        guard let wasmBin else { fail("cannot find capnp.wasm (pass --wasm or set CAPNP_WASM)") }
        guard let bundledInclude else { fail("cannot find the bundled schema include tree") }

        // Absolute-ize everything, then compute the common root.
        func absolute(_ p: String) -> String {
            URL(fileURLWithPath: p).standardizedFileURL.path
        }
        let absSchemas = schemas.map(absolute)
        let absIncludes = (includes.map(absolute) + [absolute(bundledInclude)])
        if srcPrefixes.isEmpty {
            // Default: each schema's directory, so output names are clean
            // relative paths.
            srcPrefixes = Array(Set(absSchemas.map { ($0 as NSString).deletingLastPathComponent }))
        }
        let absPrefixes = srcPrefixes.map(absolute)

        var paths = absSchemas + absIncludes + absPrefixes + [absolute(wasmBin)]
        paths.removeAll { $0 == "/" }
        guard let root = commonRoot(paths) else { fail("cannot compute a common root for the inputs") }

        func guest(_ host: String) -> String {
            let rel = (host as NSString).substring(from: root.count)
            return rel.hasPrefix("/") ? String(rel.dropFirst()) : (rel.isEmpty ? "." : rel)
        }

        do {
            // 1. Compile: capnp.wasm under WasmKit, request bytes to stdout.
            var capnpArgs = ["capnp", "compile", "-o-", "--no-standard-import"]
            for inc in absIncludes { capnpArgs.append("-I" + guest(inc)) }
            for pre in absPrefixes { capnpArgs.append("--src-prefix=" + guest(pre)) }
            for schema in absSchemas { capnpArgs.append(guest(schema)) }

            let request = try runCompiler(wasm: wasmBin, root: root, args: capnpArgs)

            // 2. Generate: the native plugin on the request.
            if check {
                try runPluginCheck(plugin: pluginBin, request: request, outputDir: outputDir.map(absolute))
            } else {
                try runPlugin(plugin: pluginBin, request: request, outputDir: outputDir.map(absolute))
            }
        } catch {
            FileHandle.standardError.write(Data("capnpc-driver: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Run the wasm compiler with "/" preopen-mapped to `root`; stdout bytes.
    static func runCompiler(wasm: String, root: String, args: [String]) throws -> [UInt8] {
        // Capture stdout through a pipe fd handed to WASI; stdin is
        // /dev/null (an inherited pipe that never EOFs makes the compiler's
        // event loop wait forever when run under another process).
        let pipe = Pipe()
        let nullStdin = FileHandle(forReadingAtPath: "/dev/null")!
        let bridge = try WASIBridgeToHost(args: args, preopens: [.init(guestPath: "/", hostPath: root)], stdin: nullStdin.fileDescriptor, stdout: pipe.fileHandleForWriting.fileDescriptor)
        defer { try? bridge.close() }
        let engine = Engine()
        let store = Store(engine: engine)
        var imports = Imports()
        bridge.link(to: &imports, store: store)
        let module = try parseWasm(bytes: [UInt8](try Data(contentsOf: URL(fileURLWithPath: wasm))))
        let instance = try module.instantiate(store: store, imports: imports)
        // Drain stdout concurrently: requests exceed the pipe buffer, and
        // the compiler blocks in fd_write until space frees.
        final class Box: @unchecked Sendable { var data = Data() }
        let collected = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }
        let exitCode = try bridge.start(instance)
        // The bridge borrows the stdio fds and never closes them: close our
        // write end now so the reader sees EOF.
        try pipe.fileHandleForWriting.close()
        group.wait()
        if exitCode != 0 {
            throw DriverError(description: "capnp.wasm exited \(exitCode)")
        }
        guard !collected.data.isEmpty else { throw DriverError(description: "capnp.wasm produced no request") }
        return [UInt8](collected.data)
    }

    static func runPlugin(plugin: String, request: [UInt8], outputDir: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plugin)
        process.arguments = outputDir.map { ["--output-dir=\($0)"] } ?? []
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(request))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw DriverError(description: "capnpc-swift exited \(process.terminationStatus)")
        }
    }

    static func runPluginCheck(plugin: String, request: [UInt8], outputDir: String?) throws {
        guard let outputDir else { throw DriverError(description: "--check needs --output-dir") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("capnpc-driver-check-\(getpid())")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try runPlugin(plugin: plugin, request: request, outputDir: tmp.path)
        defer { try? fm.removeItem(at: tmp) }

        func swiftFiles(under root: String) -> [String] {
            var out: [String] = []
            guard let enumerator = fm.enumerator(atPath: root) else { return out }
            for case let rel as String in enumerator {
                if (rel as NSString).pathExtension == "swift" { out.append(rel) }
            }
            return out
        }

        let generatedRoot = tmp.path
        let produced = swiftFiles(under: generatedRoot)
        let committed = swiftFiles(under: outputDir)
        var mismatches: [String] = []
        for rel in produced {
            let committedPath = (outputDir as NSString).appendingPathComponent(rel)
            guard let committedData = try? Data(contentsOf: URL(fileURLWithPath: committedPath)) else {
                mismatches.append("missing: \(rel)")
                continue
            }
            let generatedData = try Data(contentsOf: URL(fileURLWithPath: (generatedRoot as NSString).appendingPathComponent(rel)))
            if committedData != generatedData {
                mismatches.append("differs: \(rel)")
            }
        }
        for rel in Set(committed).subtracting(produced).sorted() {
            mismatches.append("stale: \(rel)")
        }
        if !mismatches.isEmpty {
            throw DriverError(description: "generated code out of date:\n  " + mismatches.joined(separator: "\n  "))
        }
    }

    static func findRepoRoot(from path: String) -> String? {
        var dir = path
        while dir != "/" {
            if FileManager.default.fileExists(atPath: dir + "/tools/capnpc-swift/build.zig.zon") {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The longest directory prefix common to every path.
    static func commonRoot(_ paths: [String]) -> String? {
        guard var root = paths.first else { return nil }
        for p in paths {
            while !p.hasPrefix(root) {
                root = (root as NSString).deletingLastPathComponent
                if root.isEmpty { return nil }
            }
        }
        return root
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("capnpc-driver: \(message)\n".utf8))
    exit(2)
}
