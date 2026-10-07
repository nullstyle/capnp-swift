// M3 runtime tests (plan §6): the list readers, the packed decoder and the
// list builders, against the vendored C++ fixtures (Tests/capnp_testdata)
// and hand-built round trips. The generated-code conformance suite replaces
// the hand-read fields once capnpc-swift emits test.capnp.

import Capnp
import Foundation
import Testing

/// Locates a fixture file inside Tests/capnp_testdata.
func testdata(_ path: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("capnp_testdata/\(path)")
    return try Data(contentsOf: url).map { $0 }
}

/// Reads TestAllTypes' first data word + text/data pointers from any of the
/// four fixture encodings (the C++ compiler wrote them; pretty.json holds
/// the expected values).
private func readProbeFixture(_ bytes: [UInt8]) throws -> StructReader {
    let message = try Message(bytes: bytes)
    return try message.rootStruct()
}

@Suite("CapnpRuntime")
struct CapnpRuntimeTests {
    @Test("the four fixture encodings agree on TestAllTypes' head fields")
    func fixtureEncodings() throws {
        let expectedText = "foo"
        let expectedData: [UInt8] = [98, 97, 114]
        for name in ["binary", "segmented", "packed", "segmented-packed"] {
            let raw = try testdata("testdata/\(name)")
            let unpacked = name.contains("packed") ? try Packed.unpack(raw) : raw
            let root = try readProbeFixture(unpacked)

            #expect(root.readBool(at: 0) == true)
            #expect(root.readInt8(at: 1) == -123)
            #expect(root.readInt16(at: 2) == -12345)
            #expect(root.readInt32(at: 4) == -12345678)
            #expect(root.readInt64(at: 8) == -123456789012345)
            #expect(root.readUInt8(at: 16) == 234)
            #expect(root.readUInt16(at: 18) == 45678)
            #expect(root.readUInt32(at: 20) == 3456789012)
            #expect(root.readUInt64(at: 24) == 12345678901234567890)
            #expect(root.readFloat32(at: 32) == 1234.5)
            #expect(root.readFloat64(at: 40) == -1.23e47)
            #expect(try root.readText(0) == expectedText)
            #expect(try root.readData(1) == expectedData)

            // structField (pointer slot 2) and two more levels, from
            // pretty.json: baz / nested / really nested.
            let nested = try root.readStruct(2)
            #expect(nested.readBool(at: 0) == true)
            #expect(nested.readInt8(at: 1) == -12)
            #expect(try nested.readText(0) == "baz")
            let inner = try nested.readStruct(2)
            #expect(try inner.readText(0) == "nested")
            #expect(try inner.readStruct(2).readText(0) == "really nested")
        }
    }

    @Test("fixed-size, bit, pointer and composite lists round-trip through the builder")
    func listRoundTrip() throws {
        let mb = MessageBuilder()
        let root = mb.initRoot(dataWords: 2, pointerWords: 5)

        // Fixed-size (u16) list at slot 0.
        let u16s = root.initFixedSizeList(0, count: 3, as: UInt16.self)
        u16s[0] = 11111
        u16s[1] = 40_000
        u16s[2] = 65_535

        // Bool list at slot 1.
        let bools = root.initBoolList(1, count: 9)
        bools[0] = true
        bools[8] = true

        // Struct list (composite) at slot 2: two 1-data-word elements.
        let structs = root.initStructList(2, dataWords: 1, pointerWords: 1, count: 2)
        structs[0].setUInt32(at: 0, 77)
        structs[0].setText(0, "first")
        structs[1].setUInt32(at: 0, 88)
        structs[1].setText(0, "second")

        // Text list (pointer elements) at slot 3: each element is a byte
        // list (NUL-terminated UTF-8), not a struct.
        let texts = root.initTextList(3, count: 2)
        texts.setTextElement(0, "plugh")
        texts.setTextElement(1, "xyzzy")

        let message = try Message(bytes: mb.toBytes())
        let reader = try message.rootStruct()

        let u16r = try #require(try reader.readFixedSizeList(0, as: UInt16.self))
        #expect(u16r.elements() == [11111, 40000, 65535])

        let boolr = try #require(try reader.readBoolList(1))
        #expect(boolr.elements() == [true, false, false, false, false, false, false, false, true])

        let structr = try #require(try reader.readStructList(2))
        #expect(structr.count == 2)
        #expect(structr[0].readUInt32(at: 0) == 77)
        #expect(try structr[0].readText(0) == "first")
        #expect(structr[1].readUInt32(at: 0) == 88)
        #expect(try structr[1].readText(0) == "second")

        let textr = try #require(try reader.readPointerList(3))
        #expect(textr.count == 2)
        #expect(try textr.textElement(0) == "plugh")
        #expect(try textr.textElement(1) == "xyzzy")
    }

    @Test("a truncated packed stream is malformed, never a partial word")
    func packedTruncation() throws {
        let raw = try testdata("testdata/packed")
        // Chop the tail: unpacking may drop a trailing word, but the
        // message parse must reject every truncation.
        for cut in [1, 3, 7] {
            #expect(throws: CapnpError.self) {
                _ = try Packed.message([UInt8](raw.dropLast(cut)))
            }
        }
        // The intact stream unpacks to the same bytes as the plain fixture.
        let unpacked = try Packed.unpack(raw)
        let plain = try testdata("testdata/binary")
        #expect(unpacked == plain)
    }
}
