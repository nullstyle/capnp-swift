@_spi(Generated) import Capnp

func require(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    let valid: Bool
    do { valid = try condition() }
    catch { preconditionFailure("TYPED_STRUCT_FAIL: \(name): \(error)") }
    precondition(valid, "TYPED_STRUCT_FAIL: \(name)")
    print("PASS: \(name)")
}

@main struct OpenStructsMain {
    static func main() throws {
        let enumList = try Envelope.Typed<CapnpList<CapnpEnum<Choice>>>.Value {
            try $0.setValue([Choice.first, Choice(rawValue: 65535)])
        }
        let enumValues = try Envelope.Typed<CapnpList<CapnpEnum<Choice>>>.read(from: enumList.pointer).value()
        require(enumValues.map(\.rawValue) == [1, 65535], "enum list argument preserves unknown values")
        let defaults = try Envelope.Typed<CapnpText>.Value()
        let defaultReader = try Envelope.Typed<CapnpText>.read(from: defaults.pointer)
        require(try defaultReader.names() == ["default"] && defaultReader.numbers() == [2, 3] && defaultReader.choice == .first, "typed list and enum explicit defaults")
        let voids = try Envelope.Typed<CapnpText>.Value { try $0.initVoids(3) }
        require(try defaultReader.voids().count == 2 && Envelope.Typed<CapnpText>.read(from: voids.pointer).voids().count == 3, "void list initializer and default")
        let enumUnion = try Envelope.Typed<CapnpText>.Value { $0.choice = Choice(rawValue: 65535) }
        let enumReader = try Envelope.Typed<CapnpText>.read(from: enumUnion.pointer)
        require(enumReader.which == .choice && enumReader.choice.rawValue == 65535, "enum union setter selects and encodes default")
        let listUnion = try Envelope.Typed<CapnpText>.Value { try $0.setChoices([Choice.first, Choice(rawValue: 65535)]) }
        let listReader = try Envelope.Typed<CapnpText>.read(from: listUnion.pointer)
        require(try listReader.which == .choices && listReader.choices().map(\.rawValue) == [1, 65535], "typed list union setter and values")
        let listInitialized = try Envelope.Typed<CapnpText>.Value { $0.initChoices(1)[0] = 65535 }
        let initializedReader = try Envelope.Typed<CapnpText>.read(from: listInitialized.pointer)
        require(try initializedReader.which == .choices && initializedReader.choices().map(\.rawValue) == [65535], "typed list union initializer selects")
        let value = try Envelope.Typed<CapnpText>.Value {
            try $0.setValue("value")
            try $0.metadata.setEntry("group")
            let names = $0.initNames(2)
            names.setTextElement(0, "one")
            names.setTextElement(1, "two")
        }
        let reader = try Envelope.Typed<CapnpText>.read(from: value.pointer)
        require(reader.count == 42 && reader.metadata.flag, "scalar and group defaults")
        require(try reader.value() == "value" && reader.metadata.entry() == "group", "generic group views")
        let names = try reader.names()
        require(names == ["one", "two"], "legacy primitive list field")
        let scalarUnion = try Envelope.Typed<CapnpText>.Value {
            $0.number = -27
        }
        let scalarReader = try Envelope.Typed<CapnpText>.read(from: scalarUnion.pointer)
        require(scalarReader.which == .number && scalarReader.number == -27, "scalar union setter selects and encodes default")
        let pointerUnion = try Envelope.Typed<CapnpData>.Value { try $0.setPayload([3, 4]) }
        let pointerReader = try Envelope.Typed<CapnpData>.read(from: pointerUnion.pointer)
        require(try pointerReader.which == .payload && pointerReader.payload() == [3, 4], "generic union setter selects")
        let nested = try Root.Typed.Value {
            let child = $0.initInner()
            try child.setOuter([5])
            try child.setInner("inner")
        }
        let nestedReader = try Root.Typed.read(from: nested.pointer).inner()
        require(try nestedReader.outer() == [5] && nestedReader.inner() == "inner", "branded nested type field")
    }
}
