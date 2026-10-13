import Capnp
import Foundation

@main struct LegacyDefaultsMain {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ name: String) {
        do { let valid = try condition(); precondition(valid, "LEGACY_DEFAULT_FAIL: \(name)") }
        catch { fatalError("LEGACY_DEFAULT_FAIL: \(name): \(error)") }
        print("PASS: \(name)")
    }

    static func main() throws {
        let reader = Widget.Reader(try Message(bytes: MessageBuilder.emptyStruct()).rootStruct())
        require(try reader.inner.id == 42 && reader.inner.label() == "inner", "nonempty struct default is framed")
        require(try reader.nums()?.elements() == [1, 2, 3], "nonempty list default preserves pointer offset")

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Tests/capnp_test_vendor/uInt8DefaultValueTest.bin")
        let defaults = TestDefaults.Reader(try Message(bytes: Array(Data(contentsOf: fixture))).rootStruct())
        let nested = defaults.structField
        require(try nested.boolField && nested.int8Field == -12 && nested.textField() == "baz" && nested.structField.textField() == "nested" && nested.structField.structField.textField() == "really nested", "vendor nested struct defaults retain data and pointers")
        require(try defaults.boolList()?.elements() == [true, false, false, true] && defaults.int16List()?.elements() == [11111, -11111] && defaults.uInt64List()?.elements() == [11111111111111111111], "vendor bit and integer list defaults")
        let floats = try defaults.float64List()?.elements()
        require(floats?.count == 4 && floats?[0] == 7777.75 && floats?[1] == .infinity && floats?[2] == -.infinity && floats?[3].isNaN == true, "vendor float list defaults preserve nonfinite values")
        let texts = try defaults.textList(), data = try defaults.dataList()
        require(try texts?.count == 3 && texts?.textElement(1) == "xyzzy" && data?.count == 3 && data?.dataElement(2) == Array("rfc3092".utf8), "vendor text and data list defaults")
        let structs = try defaults.structList()
        require(try structs?.count == 3 && structs?[0].textField() == "structlist 1" && structs?[2].textField() == "structlist 3", "vendor struct list defaults retain composite layout")
        require(try defaults.enumListElements() == [.foo, .garply], "vendor enum list defaults")
        let listDefaults = LegacyListDefaults.Reader(try Message(bytes: MessageBuilder.emptyStruct()).rootStruct())
        let nesting = try listDefaults.nesting()
        require(try nesting?.count == 3 && nesting?.listElement(0)?.pointer.listElementCount == 2 && nesting?.listElement(1)?.pointer.listElementCount == 0 && nesting?.listElement(2)?.pointer.listElementCount == 1, "nested list defaults retain child pointers")

        let message = MessageBuilder()
        let builder = Widget.Builder(message.initRoot(dataWords: 1, pointerWords: 4))
        _ = builder.initNums(0)
        var inner = builder.initInner()
        inner.id = 9
        inner.setLabel("wire value")
        let override = Widget.Reader(try Message(bytes: message.toBytes()).rootStruct())
        require(try override.nums()?.count == 0 && override.inner.id == 9 && override.inner.label() == "wire value", "explicit empty and populated wire values override defaults")
        try message.rootPointer().field(2).setNull()
        let cleared = Widget.Reader(try Message(bytes: message.toBytes()).rootStruct())
        require(try cleared.nums()?.elements() == [1, 2, 3] && cleared.inner.id == 9, "explicit null selects schema default without overriding other wire fields")
    }
}
