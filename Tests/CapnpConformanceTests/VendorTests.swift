// The kaos/capnp_test corpus (plan §8, M3 gate): the wasm compiler's
// `eval -obinary` output for each of `allTests`' four constants, read
// through capnpc-swift-generated code. This is CAPNP_TEST_APP's role in the
// upstream Makefile's terms: the app under test consumes compiler-produced
// bytes. Regenerate the fixtures and the committed request from a capnp-zig
// checkout at the pin (Tests/capnp_test_vendor/PROVENANCE.md).

import Capnp
import CapnpTestVendor
import Foundation
import Testing

private func vendorFixture(_ name: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("capnp_test_vendor/\(name)")
    return try Data(contentsOf: url).map { $0 }
}

@Suite("VendorCorpus")
struct VendorCorpusTests {
    @Test("simpleTest: an int and a text through generated readers")
    func simpleTest() throws {
        let root = try SimpleTestStruct.Reader(Message(bytes: vendorFixture("simpleTest.bin")).rootStruct())
        #expect(root.int == 1234567890)
        #expect(try root.msg() == "a short message...")
    }

    @Test("textListTypeTest: a text list")
    func textListType() throws {
        let root = try ListTest.Reader(Message(bytes: vendorFixture("textListTypeTest.bin")).rootStruct())
        let list = try #require(try root.textList())
        var texts: [String] = []
        for i in list.indices { texts.append(try list.textElement(i)) }
        #expect(texts == ["foo", "bar", "baz"])
    }

    @Test("uInt8DefaultValueTest: TestDefaults' schema defaults hold")
    func uint8Default() throws {
        let root = try TestDefaults.Reader(Message(bytes: vendorFixture("uInt8DefaultValueTest.bin")).rootStruct())
        // The fixture sets uInt8Field = 0; every other field reads its
        // schema default. Spot-check both sides of that line.
        #expect(root.uInt8Field == 0)
        #expect(try root.textField() == "foo")
        #expect(root.int32Field == -12345678)
        #expect(root.float64Field == -1.23e47)
    }

    @Test("constTest: a constant referenced from a default")
    func constTest() throws {
        let root = try SimpleTestStruct.Reader(Message(bytes: vendorFixture("constTest.bin")).rootStruct())
        #expect(root.int == 0)
        #expect(try root.msg() == "A const text test value.")
    }
}
