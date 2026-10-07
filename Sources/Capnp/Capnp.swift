// Capnp: the pure-Swift Cap'n Proto message runtime (plan §6, option Y).
//
// M1 ships the hand-written subset the MVP needs: a bounds-checked reader for
// standalone messages (segment table, structs, Text, Data, nested structs and
// capability pointers; far pointers with a one-word landing pad) and a
// single-segment builder. M3 replaces the hand-written bindings with generated
// code on top of this runtime; the wire rules here do not change.
//
// Wire facts (https://capnproto.org/encoding.html), all little-endian:
//   segment table  u32 (segment count - 1), u32 size in words per segment,
//                  padded to a multiple of 8 bytes
//   struct pointer kind 0: i30 word offset from the word after the pointer,
//                  u16 data words, u16 pointer words
//   list pointer   kind 1: i30 offset, u3 element size, u29 element count
//   far pointer    kind 2: u1 landing-pad size, u29 word offset, u32 segment
//   capability     kind 3 with bits 2..31 zero; u32 cap-table index in the
//                  high word
//   Text           a byte list (element size 2) whose last byte is NUL

public enum CapnpError: Error, Sendable, Equatable {
    /// The bytes are not a well-formed message (bad segment table, a pointer
    /// out of bounds, a nesting too deep).
    case malformed(String)
    /// A pointer of another kind sits where the schema expects this one.
    case wrongPointerKind(expected: String)
    /// Valid Cap'n Proto that this subset does not read yet (double-far
    /// pointers, bit lists).
    case unsupported(String)
    /// Text that is not valid UTF-8.
    case invalidText
}

/// Element sizes of a list pointer.
public enum ElementSize: UInt8 {
    case void = 0, bit = 1, byte = 2, twoBytes = 3, fourBytes = 4, eightBytes = 5, pointer = 6, composite = 7
}

/// A pointer word, decoded.
public struct Pointer: Sendable {
    public let word: UInt64
    public var kind: UInt8 { UInt8(word & 0x3) }
    public var isNull: Bool { word == 0 }
    /// Signed 30-bit word offset (struct and list pointers).
    public var offset: Int { Int(Int32(bitPattern: UInt32(truncatingIfNeeded: word)) >> 2) }
    public var structDataWords: Int { Int((word >> 32) & 0xFFFF) }
    public var structPointerWords: Int { Int((word >> 48) & 0xFFFF) }
    public var listElementSize: UInt8 { UInt8((word >> 32) & 0x7) }
    public var listElementCount: Int { Int((word >> 35) & 0x1FFF_FFFF) }
    var farTwoWordPad: Bool { (word >> 2) & 1 == 1 }
    var farWordOffset: Int { Int((word >> 3) & 0x1FFF_FFFF) }
    var farSegment: Int { Int(word >> 32) }
    var capabilityIndex: UInt32 { UInt32(truncatingIfNeeded: word >> 32) }
    var isCapability: Bool { kind == 3 && (word & 0xFFFF_FFFC) == 0 }
}

/// A read-only standalone message: the bytes of a segment table plus its
/// segments, as `capnp_conn` hands them to Swift (plan D5).
public struct Message: Sendable {
    public let bytes: [UInt8]
    /// Byte ranges of the segments inside `bytes`.
    let segments: [Range<Int>]
    /// Pointer-chase depth bound (capnp-zig uses 64).
    static let maxDepth = 64

    /// Bytes produced by a trusted producer (the schema compiler's default
    /// values embedded in generated code): same parse, no error surface.
    /// Bytes from the wire must go through `init(bytes:)`.
    public init(trustedBytes: [UInt8]) throws {
        // Same checks; generated code wraps the one-time throw, so a
        // malformed default (a generator bug) fails loudly at first use.
        try self.init(bytes: trustedBytes)
    }

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        guard bytes.count >= 8 else { throw CapnpError.malformed("message shorter than a segment table") }
        let countMinusOne = Int(Message.u32(bytes, 0))
        guard countMinusOne < 512 else { throw CapnpError.malformed("more than 512 segments") }
        let count = countMinusOne + 1
        var tableBytes = 4 * (count + 1)
        if tableBytes % 8 != 0 { tableBytes += 4 }
        guard bytes.count >= tableBytes else { throw CapnpError.malformed("segment table truncated") }
        var segments: [Range<Int>] = []
        segments.reserveCapacity(count)
        var start = tableBytes
        for i in 0..<count {
            let words = Int(Message.u32(bytes, 4 + 4 * i))
            guard words <= (bytes.count - start) / 8 else { throw CapnpError.malformed("segment \(i) larger than the message") }
            let end = start + words * 8
            segments.append(start..<end)
            start = end
        }
        guard start == bytes.count else { throw CapnpError.malformed("trailing bytes after the last segment") }
        self.segments = segments
    }

    /// Internal: assemble from already-parsed pieces (failure paths only).
    init(segments: [Range<Int>], bytes: [UInt8]) {
        self.bytes = bytes
        self.segments = segments
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
        return v
    }

    /// The pointer word at byte `pos` of `segment`.
    func word(segment: Int, pos: Int) throws -> UInt64 {
        guard segment < segments.count else { throw CapnpError.malformed("segment id out of range") }
        let seg = segments[segment]
        guard pos >= 0, pos + 8 <= seg.count else { throw CapnpError.malformed("word out of its segment") }
        return Message.u64(bytes, seg.lowerBound + pos)
    }

    /// Follow a pointer at (`segment`, `pos`): resolve far and double-far
    /// pointers and return the final pointer with the segment and byte
    /// position its offset is relative to (the word after it).
    ///
    /// Double-far: the two-word landing pad holds [far pointer to the content
    /// location, the actual pointer]. The content position is the second
    /// far's target; the actual pointer's offset counts from the word after
    /// it (capnp-zig validateFarPointer: pad word 0 is far, pad word 1 is the
    /// tag, content_override = the inner far's target).
    func resolve(segment: Int, pos: Int, depth: Int) throws -> (ptr: Pointer, segment: Int, base: Int)? {
        guard depth > 0 else { throw CapnpError.malformed("pointer nesting too deep") }
        let p = Pointer(word: try word(segment: segment, pos: pos))
        if p.isNull { return nil }
        if p.kind == 2 {
            let padSeg = p.farSegment
            let padPos = p.farWordOffset * 8
            guard padPos >= 0 else { throw CapnpError.malformed("far pointer offset negative") }
            let seg = segments[padSeg]
            if p.farTwoWordPad {
                guard padPos + 16 <= seg.count else { throw CapnpError.malformed("double-far landing pad out of its segment") }
                let inner = Pointer(word: try word(segment: padSeg, pos: padPos))
                guard inner.kind == 2, !inner.farTwoWordPad else { throw CapnpError.malformed("double-far landing pad is not a single far") }
                let tag = Pointer(word: try word(segment: padSeg, pos: padPos + 8))
                if tag.isNull { return nil }
                if tag.kind == 2 { throw CapnpError.malformed("far pointer to a far pointer") }
                let contentSeg = inner.farSegment
                let contentPos = inner.farWordOffset * 8
                guard contentPos >= 0 else { throw CapnpError.malformed("far pointer offset negative") }
                // The content starts exactly at the inner far's target; the
                // tag's own offset is ignored in this position (capnp-zig
                // computeContentOffset with a content override). Canonical
                // tags carry offset 0 anyway. Keep the (ptr, base) contract:
                // base + offset*8 must land on contentPos.
                return (tag, contentSeg, contentPos - tag.offset * 8)
            }
            let landing = Pointer(word: try word(segment: padSeg, pos: padPos))
            if landing.kind == 2 { throw CapnpError.malformed("far pointer to a far pointer") }
            if landing.isNull { return nil }
            return (landing, padSeg, padPos + 8)
        }
        return (p, segment, pos + 8)
    }

    func structAt(segment: Int, pos: Int, depth: Int) throws -> StructReader {
        guard let r = try resolve(segment: segment, pos: pos, depth: depth) else {
            return StructReader.empty(in: self, depth: depth - 1)
        }
        guard r.ptr.kind == 0 else { throw CapnpError.wrongPointerKind(expected: "struct") }
        let start = r.base + r.ptr.offset * 8
        let dataBytes = r.ptr.structDataWords * 8
        let pointerBytes = r.ptr.structPointerWords * 8
        let seg = segments[r.segment]
        guard start >= 0, start + dataBytes + pointerBytes <= seg.count else { throw CapnpError.malformed("struct out of its segment") }
        return StructReader(message: self, segment: r.segment, dataStart: start, dataBytes: dataBytes, pointerStart: start + dataBytes, pointerCount: r.ptr.structPointerWords, depth: depth - 1)
    }

    /// A byte list (Text or Data) at (`segment`, `pos`). Nil when null.
    func byteListAt(segment: Int, pos: Int, depth: Int) throws -> ArraySlice<UInt8>? {
        guard let r = try resolve(segment: segment, pos: pos, depth: depth) else { return nil }
        guard r.ptr.kind == 1 else { throw CapnpError.wrongPointerKind(expected: "list") }
        guard r.ptr.listElementSize == ElementSize.byte.rawValue else { throw CapnpError.wrongPointerKind(expected: "byte list") }
        let start = r.base + r.ptr.offset * 8
        let count = r.ptr.listElementCount
        let seg = segments[r.segment]
        guard start >= 0, start + count <= seg.count else { throw CapnpError.malformed("list out of its segment") }
        return bytes[(seg.lowerBound + start)..<(seg.lowerBound + start + count)]
    }

    func capabilityAt(segment: Int, pos: Int, depth: Int) throws -> UInt32? {
        guard let r = try resolve(segment: segment, pos: pos, depth: depth) else { return nil }
        guard r.ptr.isCapability else { throw CapnpError.wrongPointerKind(expected: "capability") }
        return r.ptr.capabilityIndex
    }

    /// The root struct (an empty struct when the root pointer is null).
    public func rootStruct() throws -> StructReader {
        guard !segments.isEmpty, segments[0].count >= 8 else { throw CapnpError.malformed("no root pointer") }
        return try structAt(segment: 0, pos: 0, depth: Message.maxDepth)
    }

    /// The root as a capability pointer (the shape of a bootstrap RETURN's
    /// message): the cap-table index, or nil for a null pointer.
    public func rootCapabilityIndex() throws -> UInt32? {
        guard !segments.isEmpty, segments[0].count >= 8 else { throw CapnpError.malformed("no root pointer") }
        return try capabilityAt(segment: 0, pos: 0, depth: Message.maxDepth)
    }
}

/// A struct inside a `Message`. Every read is bounds-checked; a field outside
/// the struct's data section reads as its default (zero), a pointer outside
/// its pointer section reads as null. Wrong pointer kinds throw.
public struct StructReader: Sendable {
    let message: Message
    let segment: Int
    let dataStart: Int
    let dataBytes: Int
    let pointerStart: Int
    let pointerCount: Int
    let depth: Int

    static func empty(in message: Message, depth: Int) -> StructReader {
        StructReader(message: message, segment: 0, dataStart: 0, dataBytes: 0, pointerStart: 0, pointerCount: 0, depth: depth)
    }

    private func dataByte(_ i: Int) -> UInt8 {
        guard i >= 0, i < dataBytes else { return 0 }
        return message.bytes[message.segments[segment].lowerBound + dataStart + i]
    }

    public func readUInt8(at byteOffset: Int) -> UInt8 { dataByte(byteOffset) }

    public func readInt8(at byteOffset: Int) -> Int8 { Int8(bitPattern: dataByte(byteOffset)) }

    public func readUInt16(at byteOffset: Int) -> UInt16 {
        guard byteOffset + 2 <= dataBytes else { return 0 }
        return UInt16(dataByte(byteOffset)) | UInt16(dataByte(byteOffset + 1)) << 8
    }

    public func readInt16(at byteOffset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(at: byteOffset))
    }

    public func readUInt32(at byteOffset: Int) -> UInt32 {
        guard byteOffset + 4 <= dataBytes else { return 0 }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(dataByte(byteOffset + k)) << (8 * UInt32(k)) }
        return v
    }

    public func readInt32(at byteOffset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(at: byteOffset))
    }

    public func readUInt64(at byteOffset: Int) -> UInt64 {
        guard byteOffset + 8 <= dataBytes else { return 0 }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(dataByte(byteOffset + k)) << (8 * UInt64(k)) }
        return v
    }

    public func readInt64(at byteOffset: Int) -> Int64 {
        Int64(bitPattern: readUInt64(at: byteOffset))
    }

    public func readFloat32(at byteOffset: Int) -> Float32 {
        Float32(bitPattern: readUInt32(at: byteOffset))
    }

    public func readFloat64(at byteOffset: Int) -> Float64 {
        Float64(bitPattern: readUInt64(at: byteOffset))
    }

    /// Whether the struct's data section covers `bytes` at `byteOffset`
    /// (generated accessors substitute a field's schema default when it
    /// does not: schema evolution, an older message under a newer schema).
    public func covers(byteOffset: Int, _ bytes: Int) -> Bool {
        byteOffset >= 0 && byteOffset + bytes <= dataBytes
    }

    public func readBool(at bitOffset: Int) -> Bool {
        (dataByte(bitOffset / 8) >> UInt8(bitOffset % 8)) & 1 == 1
    }

    func pointerPos(_ index: Int) -> Int? {
        guard index >= 0, index < pointerCount else { return nil }
        return pointerStart + index * 8
    }

    public func isPointerNull(_ index: Int) -> Bool {
        guard let pos = pointerPos(index) else { return true }
        return (try? message.word(segment: segment, pos: pos)) ?? 0 == 0
    }

    /// Text field `index`; "" when null. Strict: the trailing NUL must be
    /// there and the bytes must be UTF-8.
    public func readText(_ index: Int) throws -> String {
        guard let pos = pointerPos(index), let raw = try message.byteListAt(segment: segment, pos: pos, depth: depth) else { return "" }
        guard let last = raw.last, last == 0 else { throw CapnpError.malformed("Text without its NUL terminator") }
        let body = raw.dropLast()
        guard let s = String(validating: body, as: UTF8.self) else { throw CapnpError.invalidText }
        return s
    }

    /// Data field `index`; empty when null.
    public func readData(_ index: Int) throws -> [UInt8] {
        guard let pos = pointerPos(index), let raw = try message.byteListAt(segment: segment, pos: pos, depth: depth) else { return [] }
        return Array(raw)
    }

    /// Struct field `index`; an empty struct when null.
    public func readStruct(_ index: Int) throws -> StructReader {
        guard let pos = pointerPos(index) else { return StructReader.empty(in: message, depth: depth) }
        return try message.structAt(segment: segment, pos: pos, depth: depth)
    }

    /// Capability field `index`: its index into the payload's cap table, or
    /// nil for a null capability.
    public func readCapabilityIndex(_ index: Int) throws -> UInt32? {
        guard let pos = pointerPos(index) else { return nil }
        return try message.capabilityAt(segment: segment, pos: pos, depth: depth)
    }
}

/// Builds a single-segment standalone message. Reference type: the struct
/// builders it hands out write into its storage.
public final class MessageBuilder {
    /// Segment bytes, always a multiple of 8. Word 0 is the root pointer.
    var segment: [UInt8] = [UInt8](repeating: 0, count: 8)
    private var rootSet = false

    public init() {}

    /// A message whose root is an empty struct (0 data words, 0 pointers):
    /// the params or results of a method with no fields.
    public static func emptyStruct() -> [UInt8] {
        let mb = MessageBuilder()
        _ = mb.initRoot(dataWords: 0, pointerWords: 0)
        return mb.toBytes()
    }

    /// Allocate `words` zeroed words; returns the first word's index.
    func allocate(words: Int) -> Int {
        let index = segment.count / 8
        segment.append(contentsOf: [UInt8](repeating: 0, count: words * 8))
        return index
    }

    func writeWord(_ wordIndex: Int, _ value: UInt64) {
        let base = wordIndex * 8
        for k in 0..<8 { segment[base + k] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(k))) }
    }

    func readWord(_ wordIndex: Int) -> UInt64 {
        Message.u64(segment, wordIndex * 8)
    }

    func writeByte(_ byteIndex: Int, _ value: UInt8) {
        segment[byteIndex] = value
    }

    func writeBytes(_ byteIndex: Int, _ bytes: some Collection<UInt8>) {
        var i = byteIndex
        for b in bytes {
            segment[i] = b
            i += 1
        }
    }

    /// Point the pointer at `pointerWord` at a struct of the given shape,
    /// allocated at the end of the segment.
    func allocateStruct(pointerWord: Int, dataWords: UInt16, pointerWords: UInt16) -> StructBuilder {
        let total = Int(dataWords) + Int(pointerWords)
        // A zero-size struct allocates nothing: its pointer carries offset -1
        // (it points at its own word), as the reference implementation does.
        let start = total == 0 ? pointerWord : allocate(words: total)
        let offset = Int32(start - (pointerWord + 1))
        let word = UInt64(UInt32(bitPattern: offset << 2)) | UInt64(dataWords) << 32 | UInt64(pointerWords) << 48
        writeWord(pointerWord, word)
        return StructBuilder(message: self, dataStart: start * 8, dataWords: Int(dataWords), pointerStartWord: start + Int(dataWords), pointerWords: Int(pointerWords))
    }

    /// Point the pointer at `pointerWord` at a new byte list.
    func allocateByteList(pointerWord: Int, bytes: some Collection<UInt8>) {
        let count = bytes.count
        let words = (count + 7) / 8
        let start = allocate(words: max(words, 1))
        writeBytes(start * 8, bytes)
        let offset = Int32(start - (pointerWord + 1))
        let word = UInt64(UInt32(bitPattern: offset << 2)) | 1 | UInt64(ElementSize.byte.rawValue) << 32 | UInt64(count) << 35
        writeWord(pointerWord, word)
    }

    /// The root struct. Call once.
    public func initRoot(dataWords: UInt16, pointerWords: UInt16) -> StructBuilder {
        precondition(!rootSet, "MessageBuilder.initRoot called twice")
        rootSet = true
        return allocateStruct(pointerWord: 0, dataWords: dataWords, pointerWords: pointerWords)
    }

    /// Make the root a capability pointer (cap-table index `index`).
    public func setRootCapability(index: UInt32) {
        precondition(!rootSet, "MessageBuilder root already set")
        rootSet = true
        writeWord(0, 3 | UInt64(index) << 32)
    }

    /// Segment table plus the segment: a standalone message.
    public func toBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(8 + segment.count)
        // One segment: count-1 = 0, then its size in words, no padding needed
        // (the two u32s fill one word).
        out.append(contentsOf: [0, 0, 0, 0])
        let words = UInt32(segment.count / 8)
        for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: words >> (8 * UInt32(k)))) }
        out.append(contentsOf: segment)
        return out
    }
}

/// Writes one struct's fields into a `MessageBuilder`. Writes outside the
/// struct's own data or pointer section are programming errors and trap.
public struct StructBuilder {
    unowned let message: MessageBuilder
    let dataStart: Int
    let dataWords: Int
    let pointerStartWord: Int
    let pointerWords: Int

    public func setUInt8(at byteOffset: Int, _ value: UInt8) {
        precondition(byteOffset + 1 <= dataWords * 8, "field outside the data section")
        message.writeByte(dataStart + byteOffset, value)
    }

    public func setUInt16(at byteOffset: Int, _ value: UInt16) {
        precondition(byteOffset + 2 <= dataWords * 8, "field outside the data section")
        for k in 0..<2 { message.writeByte(dataStart + byteOffset + k, UInt8(truncatingIfNeeded: value >> (8 * UInt16(k)))) }
    }

    public func setUInt32(at byteOffset: Int, _ value: UInt32) {
        precondition(byteOffset + 4 <= dataWords * 8, "field outside the data section")
        for k in 0..<4 { message.writeByte(dataStart + byteOffset + k, UInt8(truncatingIfNeeded: value >> (8 * UInt32(k)))) }
    }

    public func setUInt64(at byteOffset: Int, _ value: UInt64) {
        precondition(byteOffset + 8 <= dataWords * 8, "field outside the data section")
        for k in 0..<8 { message.writeByte(dataStart + byteOffset + k, UInt8(truncatingIfNeeded: value >> (8 * UInt64(k)))) }
    }

    public func setBool(at bitOffset: Int, _ value: Bool) {
        precondition(bitOffset / 8 < dataWords * 8, "field outside the data section")
        let index = dataStart + bitOffset / 8
        let mask = UInt8(1) << UInt8(bitOffset % 8)
        let old = message.readWord(index / 8) >> (8 * UInt64(index % 8))
        let byte = UInt8(truncatingIfNeeded: old)
        message.writeByte(index, value ? byte | mask : byte & ~mask)
    }

    func pointerWord(_ index: Int) -> Int {
        precondition(index >= 0 && index < pointerWords, "pointer outside the pointer section")
        return pointerStartWord + index
    }

    public func setText(_ index: Int, _ text: String) {
        var bytes = Array(text.utf8)
        bytes.append(0)
        message.allocateByteList(pointerWord: pointerWord(index), bytes: bytes)
    }

    public func setData(_ index: Int, _ data: [UInt8]) {
        message.allocateByteList(pointerWord: pointerWord(index), bytes: data)
    }

    /// A capability pointer naming `capIndex` in the payload's caps[] table.
    public func setCapability(_ index: Int, capIndex: UInt32) {
        message.writeWord(pointerWord(index), 3 | UInt64(capIndex) << 32)
    }

    public func initStruct(_ index: Int, dataWords: UInt16, pointerWords: UInt16) -> StructBuilder {
        message.allocateStruct(pointerWord: pointerWord(index), dataWords: dataWords, pointerWords: pointerWords)
    }
}
