// D6 probe (plan §12): run the pinned capnp.wasm schema compiler under
// WasmKit with WASI preopens, capture its stdout (a CodeGeneratorRequest),
// and feed it to capnpc-swift on stdin. Exit 0 iff the pipeline matches the
// committed request bytes.
import Foundation
import WasmKit
import WasmKitWASI
import WASI

let args = CommandLine.arguments.dropFirst()
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: probe <capnp.wasm> <common-root> <src-prefix> <schema> [include]\n".utf8))
    exit(2)
}
func arg(_ i: Int) -> String { String(args[args.startIndex + i]) }
let wasmPath = arg(0), root = arg(1), srcPrefix = arg(2), schema = arg(3)
let includePath = args.count > 4 ? arg(4) : root

let bridge = try WASIBridgeToHost(
    args: ["capnp", "compile", "-o-", "--no-standard-import", "-I\(includePath)", "--src-prefix=\(srcPrefix)", schema],
    preopens: [.init(guestPath: "/", hostPath: root)]
)
let engine = Engine()
let store = Store(engine: engine)
var imports = Imports()
bridge.link(to: &imports, store: store)
let wasmBytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: wasmPath)))
let module = try parseWasm(bytes: wasmBytes)
let instance = try module.instantiate(store: store, imports: imports)
let exitCode = try bridge.start(instance)
FileHandle.standardError.write(Data("probe: wasm exited \(exitCode)\n".utf8))
if exitCode == 0 { exit(0) }
exit(1)
