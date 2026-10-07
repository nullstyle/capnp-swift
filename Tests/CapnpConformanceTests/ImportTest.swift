// The two-target import gate (plan §8, M3): app.capnp's generated code (the
// CapnpImportApp target) references lib.capnp's types across the module
// boundary (the CapnpImportLib target, named through $Swift.module). Swift
// modules must be acyclic; cyclic schema imports need a shared module
// (compile both files in one request), which the corpus's brand_cross_file
// request covers.

import Capnp
import CapnpImportApp
import CapnpImportLib
import Testing

@Suite("ImportTargets")
struct ImportTargetsTests {
    @Test("a generated type crosses the module boundary with its default")
    func crossModuleType() throws {
        // A Boxed message carrying lib.capnp's default value, read through
        // the app target's cross-module reference.
        var bytes: [UInt8] = [0, 0, 0, 0, 2, 0, 0, 0] // 1 segment, 2 words
        bytes.append(contentsOf: [0, 0, 0, 0, 1, 0, 0, 0]) // root struct: offset 0 (the next word), 1 data word
        bytes.append(contentsOf: [42, 0, 0, 0, 0, 0, 0, 0])
        let boxed = try CapnpImportLib.Boxed.Reader(Message(bytes: bytes).rootStruct())
        #expect(boxed.value == 42)
        // UsesBox's box accessor names the foreign type through the module.
        let uses = try CapnpImportApp.UsesBox.Reader(Message(bytes: MessageBuilder.emptyStruct()).rootStruct())
        _ = uses.box
    }
}
