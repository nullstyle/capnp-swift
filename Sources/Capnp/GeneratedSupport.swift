// Support the generated code builds on (plan §6): the "wrong pointer kind
// reads as default" rule, trusted default-value messages, and the builder
// reads/setters the emitters call. Wire rules stay in Capnp.swift/Lists.swift.

/// A schema default's pointer value, held as its serialized message bytes
/// (produced by the schema compiler; trusted). Parsed once on first use; a
/// malformed byte array (a generator bug, caught by the conformance suite)
/// reads as empty rather than trapping.
public final class CapnpDefaultMessage: Sendable {
    private let storage: Storage

    private final class Storage: @unchecked Sendable {
        let message: Message
        init(bytes: [UInt8]) {
            message = (try? Message(bytes: bytes)) ?? Message.emptyMessage
        }
    }

    public init(bytes: [UInt8]) {
        storage = Storage(bytes: bytes)
    }

    /// The default value as a struct reader (empty when the bytes are not a
    /// standalone message — never throws, never traps).
    public func rootStruct() -> StructReader {
        (try? storage.message.rootStruct()) ?? StructReader.empty(in: storage.message, depth: 0)
    }
}

extension Message {
    /// A message whose one segment is a single null root pointer: every read
    /// returns its default. Only for the failure path of trusted default
    /// bytes and builder-side reads of unbuilt messages.
    static var emptyMessage: Message {
        // [0 segments minus one = 0, size 1 word] + a zero root pointer.
        var bytes: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return (try? Message(bytes: bytes)) ?? Message.unreachable
    }

    /// Unreachable in practice (the bytes above always parse); a second
    /// guard so `emptyMessage` never traps.
    static var unreachable: Message {
        // Construct directly: one segment holding a null pointer.
        Message(segments: [0..<8], bytes: [UInt8](repeating: 0, count: 8))
    }
}

extension StructReader {
    /// The plan §6 rule: a wrong pointer kind reads as the field's default.
    /// Text stays strict (NUL + UTF-8 errors are data corruption, not shape
    /// mismatch).
    public func readTextOrDefault(_ index: Int) throws -> String {
        do { return try readText(index) }
        catch let e as CapnpError { if case .wrongPointerKind = e { return "" }; throw e }
    }

    public func readDataOrDefault(_ index: Int) throws -> [UInt8] {
        do { return try readData(index) }
        catch let e as CapnpError { if case .wrongPointerKind = e { return [] }; throw e }
    }

    public func readStructOrDefault(_ index: Int) -> StructReader {
        (try? readStruct(index)) ?? StructReader.empty(in: message, depth: depth)
    }

    public func readFixedSizeListOrDefault<Element: FixedWidthInteger & Sendable>(_ index: Int, as: Element.Type = Element.self) throws -> FixedSizeListReader<Element>? {
        do { return try readFixedSizeList(index, as: Element.self) }
        catch let e as CapnpError { if case .wrongPointerKind = e { return nil }; throw e }
    }

    public func readBoolListOrDefault(_ index: Int) throws -> BitListReader? {
        do { return try readBoolList(index) }
        catch let e as CapnpError { if case .wrongPointerKind = e { return nil }; throw e }
    }

    public func readPointerListOrDefault(_ index: Int) throws -> PointerListReader? {
        do { return try readPointerList(index) }
        catch let e as CapnpError { if case .wrongPointerKind = e { return nil }; throw e }
    }

    public func readStructListOrDefault(_ index: Int) throws -> StructListReader? {
        do { return try readStructList(index) }
        catch let e as CapnpError { if case .wrongPointerKind = e { return nil }; throw e }
    }
}

extension StructBuilder {
    // Reads mirroring the setters (generated builders read back what they
    // wrote; defaults were applied at init).
    public func readUInt8(at byteOffset: Int) -> UInt8 { message.byte(at: dataStart + byteOffset) }
    public func readInt8(at byteOffset: Int) -> Int8 { Int8(bitPattern: readUInt8(at: byteOffset)) }
    public func readUInt16(at byteOffset: Int) -> UInt16 {
        UInt16(readUInt8(at: byteOffset)) | UInt16(readUInt8(at: byteOffset + 1)) << 8
    }
    public func readInt16(at byteOffset: Int) -> Int16 { Int16(bitPattern: readUInt16(at: byteOffset)) }
    public func readUInt32(at byteOffset: Int) -> UInt32 {
        UInt32(readUInt16(at: byteOffset)) | UInt32(readUInt16(at: byteOffset + 2)) << 16
    }
    public func readInt32(at byteOffset: Int) -> Int32 { Int32(bitPattern: readUInt32(at: byteOffset)) }
    public func readUInt64(at byteOffset: Int) -> UInt64 {
        UInt64(readUInt32(at: byteOffset)) | UInt64(readUInt32(at: byteOffset + 4)) << 32
    }
    public func readInt64(at byteOffset: Int) -> Int64 { Int64(bitPattern: readUInt64(at: byteOffset)) }
    public func readFloat32(at byteOffset: Int) -> Float32 { Float32(bitPattern: readUInt32(at: byteOffset)) }
    public func readFloat64(at byteOffset: Int) -> Float64 { Float64(bitPattern: readUInt64(at: byteOffset)) }
    public func readBool(at bitOffset: Int) -> Bool {
        let byte = readUInt8(at: bitOffset / 8)
        return (byte >> UInt8(bitOffset % 8)) & 1 == 1
    }

    // Signed and float setters (bit-pattern pass-throughs).
    public func setInt8(at byteOffset: Int, _ value: Int8) { setUInt8(at: byteOffset, UInt8(bitPattern: value)) }
    public func setInt16(at byteOffset: Int, _ value: Int16) { setUInt16(at: byteOffset, UInt16(bitPattern: value)) }
    public func setInt32(at byteOffset: Int, _ value: Int32) { setUInt32(at: byteOffset, UInt32(bitPattern: value)) }
    public func setInt64(at byteOffset: Int, _ value: Int64) { setUInt64(at: byteOffset, UInt64(bitPattern: value)) }
    public func setFloat32(at byteOffset: Int, _ value: Float32) { setUInt32(at: byteOffset, value.bitPattern) }
    public func setFloat64(at byteOffset: Int, _ value: Float64) { setUInt64(at: byteOffset, value.bitPattern) }
    public func setEnum16(at byteOffset: Int, _ rawValue: UInt16) { setUInt16(at: byteOffset, rawValue) }

    /// A struct field's reader (read back what was built).
    public func reader(_ index: Int, dataWords: UInt16, pointerWords: UInt16) -> StructReader {
        // Re-wrap the builder's own storage as a reader: same message bytes.
        // (The message is single-segment; the reader side parses those bytes.)
        StructReader(
            message: (try? Message(bytes: message.segmentBytes())) ?? Message.emptyMessage,
            segment: 0,
            dataStart: dataStart,
            dataBytes: Int(dataWords) * 8,
            pointerStart: dataStart + Int(dataWords) * 8,
            pointerCount: Int(pointerWords),
            depth: Message.maxDepth)
    }
}

extension MessageBuilder {
    /// The segment bytes without the segment table (builder-side reads).
    func segmentBytes() -> [UInt8] { segment }
}
