// The pure-Swift message runtime subset (Sources/Capnp): builder -> reader
// round trips and malformed-input rejection.

import Capnp
import Testing

@Suite("Capnp.Message")
struct MessageTests {
    @Test("builder and reader agree on data, Text, Data, nested structs and capabilities")
    func roundTrip() throws {
        let mb = MessageBuilder()
        let root = mb.initRoot(dataWords: 2, pointerWords: 4)
        root.setUInt64(at: 0, 0x1122_3344_5566_7788)
        root.setUInt32(at: 8, 0xdead_beef)
        root.setUInt16(at: 12, 0xbeef)
        root.setUInt8(at: 14, 0x42)
        root.setBool(at: 15 * 8 + 3, true)
        root.setText(0, "héllo, wörld")
        root.setData(1, [1, 2, 3, 4, 5, 6, 7, 8, 9])
        root.setCapability(2, capIndex: 7)
        let inner = root.initStruct(3, dataWords: 1, pointerWords: 1)
        inner.setUInt64(at: 0, 99)
        inner.setText(0, "")
        let bytes = mb.toBytes()

        let message = try Message(bytes: bytes)
        let r = try message.rootStruct()
        #expect(r.readUInt64(at: 0) == 0x1122_3344_5566_7788)
        #expect(r.readUInt32(at: 8) == 0xdead_beef)
        #expect(r.readUInt16(at: 12) == 0xbeef)
        #expect(r.readUInt8(at: 14) == 0x42)
        #expect(r.readBool(at: 15 * 8 + 3))
        #expect(!r.readBool(at: 15 * 8 + 2))
        // Outside the data section: defaults, never a trap.
        #expect(r.readUInt64(at: 16) == 0)
        #expect(r.readUInt64(at: 1 << 40) == 0)
        #expect(try r.readText(0) == "héllo, wörld")
        #expect(try r.readData(1) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(try r.readCapabilityIndex(2) == 7)
        let i = try r.readStruct(3)
        #expect(i.readUInt64(at: 0) == 99)
        #expect(try i.readText(0) == "")
        // Outside the pointer section: null.
        #expect(r.isPointerNull(4))
        #expect(try r.readText(4) == "")
        #expect(try r.readCapabilityIndex(4) == nil)
        #expect(try r.readStruct(4).readUInt64(at: 0) == 0)
    }

    @Test("a root capability pointer (the shape of a bootstrap RETURN)")
    func rootCapability() throws {
        let mb = MessageBuilder()
        mb.setRootCapability(index: 3)
        let message = try Message(bytes: mb.toBytes())
        #expect(try message.rootCapabilityIndex() == 3)
        #expect(throws: CapnpError.wrongPointerKind(expected: "struct")) { try message.rootStruct() }
    }

    @Test("an empty struct message is 16 bytes and reads as defaults")
    func emptyStruct() throws {
        let bytes = MessageBuilder.emptyStruct()
        #expect(bytes.count == 16)
        let r = try Message(bytes: bytes).rootStruct()
        #expect(r.readUInt64(at: 0) == 0)
        #expect(r.isPointerNull(0))
    }

    @Test("malformed messages are rejected, never trapped")
    func malformed() throws {
        // Too short.
        #expect(throws: CapnpError.self) { try Message(bytes: [0, 0, 0, 0]) }
        // Segment larger than the message.
        #expect(throws: CapnpError.self) { try Message(bytes: [0, 0, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
        // Trailing bytes.
        #expect(throws: CapnpError.self) { try Message(bytes: [0, 0, 0, 0, 1, 0, 0, 0] + [UInt8](repeating: 0, count: 9)) }
        // A struct pointer 1000 words past the end.
        var bad: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]
        let word: UInt64 = (1000 << 2) | (1 << 32)
        for k in 0..<8 { bad.append(UInt8(truncatingIfNeeded: word >> (8 * UInt64(k)))) }
        let m = try Message(bytes: bad)
        #expect(throws: CapnpError.self) { try m.rootStruct() }
        // Text pointing at a list of the wrong element size.
        let mb = MessageBuilder()
        let root = mb.initRoot(dataWords: 0, pointerWords: 1)
        root.setCapability(0, capIndex: 1)
        let r = try Message(bytes: mb.toBytes()).rootStruct()
        #expect(throws: CapnpError.wrongPointerKind(expected: "list")) { try r.readText(0) }
        // Text without its NUL.
        let mb2 = MessageBuilder()
        let root2 = mb2.initRoot(dataWords: 0, pointerWords: 1)
        root2.setData(0, [104, 105])
        let r2 = try Message(bytes: mb2.toBytes()).rootStruct()
        #expect(throws: CapnpError.self) { try r2.readText(0) }
        #expect(try r2.readData(0) == [104, 105])
    }
}
