import Capnp

@main struct LegacyEnumMain {
    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), "LEGACY_ENUM_FAIL: \(name)")
        print("PASS: \(name)")
    }
    private static func isChoice(_ which: EnumDefaults.Which) -> Bool {
        if case .choice = which { return true }; return false
    }
    private static func isAlternate(_ which: EnumDefaults.Which) -> Bool {
        if case .alternate = which { return true }; return false
    }
    static func main() throws {
        let message = MessageBuilder()
        let root = message.initRoot(dataWords: 1, pointerWords: 0)
        var builder = EnumDefaults.Builder(root)
        require(builder.value == .first && builder.choice == .second, "unset enum builder getters apply schema defaults")
        builder.value = .second
        let known = EnumDefaults.Reader(try Message(bytes: message.toBytes()).rootStruct())
        require(builder.value == .second && known.value == .second, "known enum setters round trip through independent reader defaults")
        builder.value = .first
        let defaultReader = EnumDefaults.Reader(try Message(bytes: message.toBytes()).rootStruct())
        require(builder.value == .first && defaultReader.value == .first && root.readUInt16(at: 0) == 0, "setting enum default writes zero wire bits")
        builder.value = EnumChoice(rawValue: 65535)
        let unknown = EnumDefaults.Reader(try Message(bytes: message.toBytes()).rootStruct())
        require(builder.value.rawValue == 65535 && unknown.value.rawValue == 65535 && !unknown.value.isKnown, "unknown enum values survive default XOR")
        builder.choice = .first
        let choice = EnumDefaults.Reader(try Message(bytes: message.toBytes()).rootStruct())
        require(isChoice(choice.which) && builder.choice == .first && choice.choice == .first, "nonzero default enum setter selects its union member")
        builder.alternate = .second
        let alternate = EnumDefaults.Reader(try Message(bytes: message.toBytes()).rootStruct())
        require(isAlternate(alternate.which) && builder.alternate == .second && alternate.alternate == .second, "zero default enum setter selects its union member")
    }
}
