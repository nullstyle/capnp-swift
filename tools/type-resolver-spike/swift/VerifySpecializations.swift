import Capnp
import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

@main
struct VerifySpecializations {
    static func check(_ condition: Bool, _ name: String) throws {
        if !condition { throw Failure(description: name) }
    }

    static func verify(_ reader: SpecializedRoot.Reader, producer: String) throws {
        let text: String = try reader.textBox().value()
        let data: [UInt8] = try reader.dataBox().value()
        let nested: String = try reader.nestedBox().value().value()
        try check(text == "héllo" && data == [0, 1, 255] && nested == "nested", "distinct and nested Box bindings")
        print("PASS: distinct and nested Box bindings (\(producer))")

        let numbers = try reader.listBox().value()
        let boxes = try reader.boxes()
        try check(numbers?.count == 3 && numbers?[0] == 1 && numbers?[1] == 65535 && numbers?[2] == 42 && boxes?.count == 2 && (try boxes?[0].value()) == "first" && (try boxes?[1].value()) == "second", "bound integer and struct lists")
        print("PASS: bound integer and struct lists (\(producer))")

        let head = reader.head()
        let children = try head.children()
        try check((try head.value()) == "head" && (try head.next().value()) == "tail" && children?.count == 2 && (try children?[0].value()) == "child0" && (try children?[1].next().value()) == "grandchild", "recursive applications and list elements")
        print("PASS: recursive applications and list elements (\(producer))")

        let outerText: String = try reader.lexical().outer()
        let innerData: [UInt8] = try reader.lexical().inner()
        let outerData: [UInt8] = try reader.otherLexical().outer()
        let innerText: String = try reader.otherLexical().inner()
        try check(outerText == "outer" && innerData == [9, 8] && outerData == [7, 6] && innerText == "inner", "lexical bindings keep both scope identities")
        print("PASS: lexical bindings keep both scope identities (\(producer))")
    }

    static func run() throws {
        let output = CommandLine.arguments[1]
        let message = MessageBuilder()
        let root = SpecializedRoot.initRoot(message)
        root.initTextBox().setValue("héllo")
        root.initDataBox().setValue([0, 1, 255])
        root.initNestedBox().initValue().setValue("nested")
        let numbers = root.initListBox().initValue(3)
        numbers[0] = 1
        numbers[1] = 65535
        numbers[2] = 42
        let boxes = root.initBoxes(2)
        boxes[0].setValue("first")
        boxes[1].setValue("second")
        let head = root.initHead()
        head.setValue("head")
        head.initNext().setValue("tail")
        let children = head.initChildren(2)
        children[0].setValue("child0")
        children[1].setValue("child1")
        children[1].initNext().setValue("grandchild")
        let lexical = root.initLexical()
        lexical.setOuter("outer")
        lexical.setInner([9, 8])
        let other = root.initOtherLexical()
        other.setOuter([7, 6])
        other.setInner("inner")
        let bytes = message.toBytes()
        try verify(SpecializedRoot.Reader(Message(bytes: bytes).rootStruct()), producer: "Swift builder")
        try Data(bytes).write(to: URL(fileURLWithPath: output))

        let empty = SpecializedRoot.Reader(try Message(bytes: MessageBuilder.emptyStruct()).rootStruct())
        try check((try empty.textBox().value()).isEmpty && (try empty.dataBox().value()).isEmpty && (try empty.head().next().value()).isEmpty && (try empty.boxes()) == nil && (try empty.listBox().value()) == nil, "null and missing fields retain schema defaults")
        print("PASS: null and missing fields retain schema defaults")
        if CommandLine.arguments.count == 3 {
            let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            try verify(SpecializedRoot.Reader(Message(bytes: Array(input)).rootStruct()), producer: "C++ encoder")
        }
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
