// The capnp-generate command plugin (plan §6, D6 option A).
//
//   swift package --allow-writing-to-package-directory capnp-generate \
//       --output-dir Sources/Generated Schemas/foo.capnp
//
// Everything after the verb is passed to capnpc-driver (which runs the
// vendored capnp.wasm under WasmKit and the capnpc-swift plugin). Add
// --check for CI: it diffs instead of writing and exits nonzero when the
// committed code is out of date.
//
// The driver binary is found, in order: $CAPNPC_SWIFT_DRIVER, the
// artifactbundle tool (released packages), or the local build directory
// (`swift build --product capnpc-driver` first in development).

import Foundation
import PackagePlugin

struct PluginDriverError: Error { static let notFound = NSError(domain: "capnpc", code: 1) }

@main
struct CapnpGeneratePlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let driver = try findDriver(context: context)

        var args = arguments
        if !args.contains("--output-dir") && !args.contains(where: { $0.hasPrefix("--output-dir=") }) {
            Diagnostics.error("no --output-dir given (the directory the generated .swift files go into)")
            return
        }
        // In sandboxed runs the driver's temp files land outside the package;
        // writing only happens under --output-dir (the granted permission).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: driver)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        Diagnostics.remark("capnpc-driver \(args.joined(separator: " "))")
        try process.run()
        // Drain both pipes concurrently so the driver can never block on a
        // full buffer.
        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        if !errData.isEmpty {
            FileHandle.standardError.write(errData)
        }
        guard process.terminationStatus == 0 else {
            Diagnostics.error("capnpc-driver failed (exit \(process.terminationStatus))")
            return
        }
    }

    private func findDriver(context: PluginContext) throws -> String {
        if let fromEnv = ProcessInfo.processInfo.environment["CAPNPC_SWIFT_DRIVER"] {
            return fromEnv
        }
        // The released package ships the driver in an artifactbundle.
        if let tool = try? context.tool(named: "capnpc-driver").url.path {
            return tool
        }
        // Development: whatever `swift build --product capnpc-driver` made.
        let packageRoot = context.package.directory.string
        for candidate in [
            packageRoot + "/.build/debug/capnpc-driver",
            packageRoot + "/.build/out/Products/Debug/capnpc-driver",
            packageRoot + "/.build/release/capnpc-driver",
            packageRoot + "/.build/out/Products/Release/capnpc-driver",
        ] where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        Diagnostics.error("""
        cannot find capnpc-driver. Either:
          - swift build --product capnpc-driver   (development), or
          - set CAPNPC_SWIFT_DRIVER to its path
        """)
        throw PluginDriverError.notFound
    }
}
