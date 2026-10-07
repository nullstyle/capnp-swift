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
        // Boxed.value defaults to 42; the wire stores value ^ default, so
        // zeroed storage reads as the default (capnp's default encoding).
        var bytes: [UInt8] = [0, 0, 0, 0, 2, 0, 0, 0] // 1 segment, 2 words
        bytes.append(contentsOf: [0, 0, 0, 0, 1, 0, 0, 0]) // root struct: offset 0, 1 data word
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        let defaulted = try CapnpImportLib.Boxed.Reader(Message(bytes: bytes).rootStruct())
        #expect(defaulted.value == 42)
        // A non-default value: 7 xor 42 = 45 on the wire reads back 7.
        bytes[16] = 45
        let seven = try CapnpImportLib.Boxed.Reader(Message(bytes: bytes).rootStruct())
        #expect(seven.value == 7)
        // UsesBox's box accessor names the foreign type through the module.
        let uses = try CapnpImportApp.UsesBox.Reader(Message(bytes: MessageBuilder.emptyStruct()).rootStruct())
        _ = uses.box
    }
}
