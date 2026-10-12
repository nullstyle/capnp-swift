@_spi(Generated) import Capnp

func require(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    let valid: Bool
    do { valid = try condition() }
    catch { preconditionFailure("TYPED_APPLICATION_FAIL: \(name): \(error)") }
    precondition(valid, "TYPED_APPLICATION_FAIL: \(name)")
    print("PASS: \(name)")
}

@main struct OpenApplicationsMain {
    static func main() throws {
        let text = try Box.Typed<CapnpText>.Value { try $0.setValue("text") }
        let textReader = try Box.Typed<CapnpText>.read(from: text.pointer)
        require(try textReader.value() == "text", "open text argument")
        let data = try Box.Typed<CapnpData>.Value { try $0.setValue([0, 255, 0]) }
        require(try Box.Typed<CapnpData>.read(from: data.pointer).value() == [0, 255, 0], "open data argument")
        let numbers = try Box.Typed<CapnpList<UInt16>>.Value { try $0.setValue([0, 256, 65535]) }
        require(try Box.Typed<CapnpList<UInt16>>.read(from: numbers.pointer).value() == [0, 256, 65535], "open integer list argument")
        // Not present among the fixture root's applications: no profile/generated specialization needed.
        let fresh = try Box.Typed<CapnpList<CapnpData>>.Value { try $0.setValue([[1, 2], [], [3]]) }
        require(try Box.Typed<CapnpList<CapnpData>>.read(from: fresh.pointer).value() == [[1, 2], [], [3]], "new call site pointer list argument")
        let nested = try Box.Typed<Box.Typed<CapnpText>>.Value { try $0.initValue().setValue("nested") }
        require(try Box.Typed<Box.Typed<CapnpText>>.read(from: nested.pointer).value().value() == "nested", "open nested struct argument")
        let first = try Outer.Typed<CapnpText>.Inner<CapnpData>.Value {
            try $0.setOuter("outer")
            try $0.setInner([7, 8])
        }
        let second = try Outer.Typed<CapnpData>.Inner<CapnpText>.Value {
            try $0.setOuter([9])
            try $0.setInner("inner")
        }
        let firstReader = try Outer.Typed<CapnpText>.Inner<CapnpData>.read(from: first.pointer)
        let secondReader = try Outer.Typed<CapnpData>.Inner<CapnpText>.read(from: second.pointer)
        require(try firstReader.outer() == "outer" && firstReader.inner() == [7, 8] && secondReader.outer() == [9] && secondReader.inner() == "inner", "nested lexical argument scopes")
        let list = try Box.Typed<CapnpList<Box.Typed<CapnpText>>>.Value { try $0.setValue([text, text]) }
        let listReader = try Box.Typed<CapnpList<Box.Typed<CapnpText>>>.read(from: list.pointer)
        require(try listReader.value().map { try $0.value() } == ["text", "text"], "generic inline composite list argument")
        let link = try Link.Typed<CapnpText>.Value {
            try $0.setValue("head")
            try $0.initNext().setValue("next")
            let children = $0.initChildren(2)
            try children[0].setValue("left")
            try children[1].setValue("right")
        }
        let linkReader = try Link.Typed<CapnpText>.read(from: link.pointer)
        let children = try linkReader.children()
        require(try linkReader.next().value() == "next" && children[0].value() == "left" && children[1].value() == "right", "recursive typed fields and struct list")
        let growing = try Grow.Typed<CapnpText>.Value { _ = $0.initNext().initNext().initNext() }
        _ = try Grow.Typed<CapnpText>.read(from: growing.pointer).next().next().next()
        require(try growing.pointer.serialized().bytes.count >= 48, "changing recursive applications remain finite declarations")
        require(!textReader.erased.valueIsNull, "legacy erased reader adapter")
        let erased = try UnboundRoot.Typed.Value { try $0.initBox().setValue(text.pointer.field(0)) }
        let recovered = try UnboundRoot.Typed.read(from: erased.pointer).box().value().read(as: CapnpText.self)
        require(recovered == "text", "unbranded application remains erased")
        let copy = try Box.Typed<CapnpText>.Value(copying: textReader)
        require(try Box.Typed<CapnpText>.read(from: copy.pointer).value() == "text", "typed owned copy")
        let retainedBuilder: Box.Typed<CapnpText>.Builder = {
            Box.Typed<CapnpText>.initRoot(MessageBuilder())
        }()
        try retainedBuilder.setValue("retained")
        require(try Box.Typed<CapnpText>.read(from: retainedBuilder.pointer.freeze()).value() == "retained", "builder retains message lifetime")
        let defaults = try Box.Typed<CapnpText>.Value()
        require(try Box.Typed<CapnpText>.read(from: defaults.pointer).value() == "", "generic null default")
    }
}
