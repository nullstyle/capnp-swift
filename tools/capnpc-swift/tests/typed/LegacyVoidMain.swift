import Capnp

@main struct LegacyVoidMain {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ name: String) {
        do { let valid = try condition(); precondition(valid, "LEGACY_VOID_FAIL: \(name)") }
        catch { fatalError("LEGACY_VOID_FAIL: \(name): \(error)") }
        print("PASS: \(name)")
    }

    static func main() throws {
        let defaults = LegacyListDefaults.Reader(try Message(bytes: MessageBuilder.emptyStruct()).rootStruct())
        let defaultList: VoidListReader? = try defaults.voids()
        require(defaultList?.count == 3 && defaultList?.indices == 0..<3, "compiler produced Void list defaults preserve count")
        let message = MessageBuilder()
        let raw = message.initRoot(dataWords: 0, pointerWords: 2)
        let builder = LegacyListDefaults.Builder(raw)
        let elements: VoidListBuilder = builder.initVoids(4)
        elements[2] = ()
        let populated = LegacyListDefaults.Reader(try Message(bytes: message.toBytes()).rootStruct())
        let written = try populated.voids()
        let _: Void? = written?[2]
        require(written?.count == 4 && elements.indices == 0..<4 && message.toBytes().count == 32, "Void list builders write count without element storage")
        _ = builder.initVoids(0)
        let empty = LegacyListDefaults.Reader(try Message(bytes: message.toBytes()).rootStruct())
        require(try empty.voids()?.isEmpty == true, "explicit empty Void lists override nonempty defaults")

        let wrongKind = MessageBuilder()
        let wrongRoot = wrongKind.initRoot(dataWords: 0, pointerWords: 1)
        wrongRoot.setText(0, "text")
        let wrongReader = try Message(bytes: wrongKind.toBytes()).rootStruct()
        require(try wrongReader.readVoidListOrDefault(0) == nil, "wrong Void list element kind reads as absent")
        let absent = try Message(bytes: MessageBuilder.emptyStruct()).rootStruct()
        require(try absent.readVoidList(0) == nil, "null Void list reads as absent")

        let words: [UInt64] = [UInt64(2) << 32, UInt64(1) << 48, 1 | UInt64(100) << 2 | UInt64(2) << 35]
        let bytes = words.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
        var rejected = false
        do { _ = try Message(bytes: bytes).rootStruct().readVoidListOrDefault(0) }
        catch let error as CapnpError { if case .malformed = error { rejected = true } }
        require(rejected, "malformed Void list offsets remain errors")
    }
}
