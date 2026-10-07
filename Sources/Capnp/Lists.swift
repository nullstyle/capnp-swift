// Capnp list readers (plan §6, M3): fixed-size element lists, bit (Bool)
// lists, pointer-element lists (Text, Data, structs, nested lists) and
// inline-composite struct lists. All bounds-checked; a wrong pointer kind
// throws `CapnpError.wrongPointerKind`.
//
// Wire facts (capnproto.org/encoding.html):
//   list pointer kind 1: i30 word offset, u3 element size, u29 element count
//   element sizes: 0 void, 1 bit, 2 byte, 3 twoBytes, 4 fourBytes,
//                  5 eightBytes, 6 pointer, 7 inline composite
//   composite: the list pointer's offset names a tag word (a struct pointer
//   whose OFFSET field holds the element count, its sizes the element's
//   data/pointer words); the list count field holds the total content words
//   including the tag; elements start after the tag, stride = data + pointer
//   words (capnp-zig message.zig resolveInlineCompositeList).

extension Message {
    /// A decoded list pointer with its content location.
    public struct ResolvedList: Sendable {
        public let pointer: Pointer
        public let segment: Int
        /// Byte index of the first content byte within `segments[segment]`.
        public let contentStart: Int
    }

    /// Resolve the list pointer at (`segment`, `pos`); nil when null.
    func listAt(segment: Int, pos: Int, depth: Int) throws -> ResolvedList? {
        guard let r = try resolve(segment: segment, pos: pos, depth: depth) else { return nil }
        guard r.ptr.kind == 1 else { throw CapnpError.wrongPointerKind(expected: "list") }
        let start = r.base + r.ptr.offset * 8
        guard start >= 0 else { throw CapnpError.malformed("list offset negative") }
        return ResolvedList(pointer: r.ptr, segment: r.segment, contentStart: start)
    }

    /// Absolute byte index of `bytes` at `start` within `segment`, bounds-
    /// checked against the segment.
    func contentBase(segment: Int, start: Int, bytes: Int, what: String) throws -> Int {
        let seg = segments[segment]
        guard start + bytes <= seg.count else { throw CapnpError.malformed("\(what) out of its segment") }
        return seg.lowerBound + start
    }

    /// The (index, byte-range) of the segment containing absolute byte `p`.
    func segmentContaining(byte p: Int) -> (index: Int, range: Range<Int>)? {
        for (i, seg) in segments.enumerated() where seg.contains(p) {
            return (i, seg)
        }
        return nil
    }
}

/// A list whose elements are 1, 2, 4 or 8 fixed-size bytes (integers, raw-bit
/// enums, floats through their bit patterns). `Element` must be a fixed-width
/// integer whose width matches the list's element size.
public struct FixedSizeListReader<Element: FixedWidthInteger & Sendable>: Sendable {
    let message: Message
    /// Absolute byte index of element 0.
    let base: Int
    public let count: Int
    let byteStride: Int

    init(message: Message, list: Message.ResolvedList) throws {
        let size = list.pointer.listElementSize
        let stride: Int
        switch size {
        case ElementSize.byte.rawValue: stride = 1
        case ElementSize.twoBytes.rawValue: stride = 2
        case ElementSize.fourBytes.rawValue: stride = 4
        case ElementSize.eightBytes.rawValue: stride = 8
        default: throw CapnpError.wrongPointerKind(expected: "fixed-size list")
        }
        guard stride == MemoryLayout<Element>.stride else {
            throw CapnpError.wrongPointerKind(expected: "list of \(MemoryLayout<Element>.stride)-byte elements")
        }
        let count = list.pointer.listElementCount
        self.message = message
        self.base = try message.contentBase(segment: list.segment, start: list.contentStart, bytes: count * stride, what: "list")
        self.count = count
        self.byteStride = stride
    }

    public var isEmpty: Bool { count == 0 }
    public var indices: Range<Int> { 0..<count }

    public subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "list index out of range")
        let p = base + index * byteStride
        var value: Element = 0
        for k in 0..<byteStride {
            value |= Element(message.bytes[p + k]) &<< (8 * Element(k))
        }
        return value
    }

    public func elements() -> [Element] {
        var out: [Element] = []
        out.reserveCapacity(count)
        for i in indices { out.append(self[i]) }
        return out
    }
}

/// A list of Bools: element size 1 (bit), packed LSB-first from the content
/// start.
public struct BitListReader: Sendable {
    let message: Message
    /// Absolute byte index of bit 0.
    let base: Int
    public let count: Int

    init(message: Message, list: Message.ResolvedList) throws {
        guard list.pointer.listElementSize == ElementSize.bit.rawValue else {
            throw CapnpError.wrongPointerKind(expected: "bit list")
        }
        let count = list.pointer.listElementCount
        self.message = message
        self.base = try message.contentBase(segment: list.segment, start: list.contentStart, bytes: (count + 7) / 8, what: "bit list")
        self.count = count
    }

    public var isEmpty: Bool { count == 0 }
    public var indices: Range<Int> { 0..<count }

    public subscript(index: Int) -> Bool {
        precondition(index >= 0 && index < count, "list index out of range")
        let byte = message.bytes[base + index / 8]
        return (byte >> UInt8(index % 8)) & 1 == 1
    }

    public func elements() -> [Bool] {
        var out: [Bool] = []
        out.reserveCapacity(count)
        for i in indices { out.append(self[i]) }
        return out
    }
}

/// A list whose elements are pointers (element size 6): Text, Data, structs,
/// nested lists, capabilities. Elements resolve lazily.
public struct PointerListReader: Sendable {
    let message: Message
    let segment: Int
    /// Position of element 0's pointer word within the segment.
    let startPos: Int
    public let count: Int
    let depth: Int

    init(message: Message, list: Message.ResolvedList, depth: Int) throws {
        guard list.pointer.listElementSize == ElementSize.pointer.rawValue else {
            throw CapnpError.wrongPointerKind(expected: "pointer list")
        }
        let count = list.pointer.listElementCount
        self.message = message
        self.segment = list.segment
        self.startPos = list.contentStart
        self.count = count
        self.depth = depth
        _ = try message.contentBase(segment: list.segment, start: list.contentStart, bytes: count * 8, what: "pointer list")
    }

    public var indices: Range<Int> { 0..<count }

    private func elementPos(_ index: Int) -> Int {
        precondition(index >= 0 && index < count, "list index out of range")
        return startPos + index * 8
    }

    public func isNull(_ index: Int) -> Bool {
        (try? message.word(segment: segment, pos: elementPos(index))) ?? 0 == 0
    }

    public func structElement(_ index: Int) throws -> StructReader {
        try message.structAt(segment: segment, pos: elementPos(index), depth: depth)
    }

    /// The resolved element list, for list-of-lists. Nil when null.
    public func listElement(_ index: Int) throws -> Message.ResolvedList? {
        try message.listAt(segment: segment, pos: elementPos(index), depth: depth)
    }

    /// The element's capability-table index; nil when null or not a capability.
    public func capabilityIndex(_ index: Int) throws -> UInt32? {
        try message.capabilityAt(segment: segment, pos: elementPos(index), depth: depth)
    }

    /// Text element; "" when null. Strict (NUL + UTF-8) like a Text field.
    public func textElement(_ index: Int) throws -> String {
        guard let raw = try byteListElement(index) else { return "" }
        guard let last = raw.last, last == 0 else { throw CapnpError.malformed("Text without its NUL terminator") }
        guard let s = String(validating: raw.dropLast(), as: UTF8.self) else { throw CapnpError.invalidText }
        return s
    }

    /// Data element; empty when null.
    public func dataElement(_ index: Int) throws -> [UInt8] {
        guard let raw = try byteListElement(index) else { return [] }
        return Array(raw)
    }

    private func byteListElement(_ index: Int) throws -> ArraySlice<UInt8>? {
        guard let list = try message.listAt(segment: segment, pos: elementPos(index), depth: depth) else { return nil }
        guard list.pointer.listElementSize == ElementSize.byte.rawValue else {
            throw CapnpError.wrongPointerKind(expected: "byte list")
        }
        let n = list.pointer.listElementCount
        let start = try message.contentBase(segment: list.segment, start: list.contentStart, bytes: n, what: "byte list")
        return message.bytes[start..<(start + n)]
    }
}

/// An inline-composite struct list. Element shapes come from the tag word;
/// every element access is bounds-checked against the segment.
public struct StructListReader: Sendable {
    let message: Message
    let segment: Int
    /// Position of element 0's first byte (after the tag word), within the
    /// segment.
    let elementsStart: Int
    let elementCount: Int
    let dataWords: Int
    let pointerWords: Int
    let depth: Int

    init(message: Message, list: Message.ResolvedList, depth: Int) throws {
        guard list.pointer.listElementSize == ElementSize.composite.rawValue else {
            throw CapnpError.wrongPointerKind(expected: "inline-composite list")
        }
        let tagPos = list.contentStart
        let seg = message.segments[list.segment]
        guard tagPos + 8 <= seg.count else { throw CapnpError.malformed("composite tag out of its segment") }
        let tag = Pointer(word: Message.u64(message.bytes, seg.lowerBound + tagPos))
        guard tag.kind == 0 else { throw CapnpError.malformed("composite tag is not a struct pointer") }
        let count = tag.offset
        let dataWords = tag.structDataWords
        let pointerWords = tag.structPointerWords
        let strideBytes = (dataWords + pointerWords) * 8
        // The list count field holds the total content words including the
        // tag; writers may round up (capnp-zig Layout B allows slack), so the
        // element extent — not the word count — is the bounds check.
        _ = list.pointer.listElementCount
        self.message = message
        self.segment = list.segment
        self.elementsStart = tagPos + 8
        self.elementCount = count
        self.dataWords = dataWords
        self.pointerWords = pointerWords
        self.depth = depth - 1
        _ = try message.contentBase(segment: list.segment, start: tagPos + 8, bytes: count * strideBytes, what: "composite list")
    }

    public var count: Int { elementCount }
    public var indices: Range<Int> { 0..<elementCount }

    public subscript(index: Int) -> StructReader {
        precondition(index >= 0 && index < elementCount, "list index out of range")
        let start = elementsStart + index * (dataWords + pointerWords) * 8
        return StructReader(
            message: message,
            segment: segment,
            dataStart: start,
            dataBytes: dataWords * 8,
            pointerStart: start + dataWords * 8,
            pointerCount: pointerWords,
            depth: depth)
    }
}

extension StructReader {
    /// Fixed-size list field at pointer slot `index`.
    public func readFixedSizeList<Element: FixedWidthInteger & Sendable>(_ index: Int, as: Element.Type = Element.self) throws -> FixedSizeListReader<Element>? {
        guard let pos = pointerPos(index), let list = try message.listAt(segment: segment, pos: pos, depth: depth) else { return nil }
        return try FixedSizeListReader<Element>(message: message, list: list)
    }

    /// Bool list field at pointer slot `index`.
    public func readBoolList(_ index: Int) throws -> BitListReader? {
        guard let pos = pointerPos(index), let list = try message.listAt(segment: segment, pos: pos, depth: depth) else { return nil }
        return try BitListReader(message: message, list: list)
    }

    /// Pointer-element list field at pointer slot `index`.
    public func readPointerList(_ index: Int) throws -> PointerListReader? {
        guard let pos = pointerPos(index), let list = try message.listAt(segment: segment, pos: pos, depth: depth) else { return nil }
        return try PointerListReader(message: message, list: list, depth: depth)
    }

    /// Inline-composite struct list field at pointer slot `index`.
    public func readStructList(_ index: Int) throws -> StructListReader? {
        guard let pos = pointerPos(index), let list = try message.listAt(segment: segment, pos: pos, depth: depth) else { return nil }
        return try StructListReader(message: message, list: list, depth: depth)
    }
}

/// Writes a fixed-size element list (1, 2, 4 or 8 bytes per element).
public struct FixedSizeListBuilder<Element: FixedWidthInteger> {
    let message: MessageBuilder
    /// Byte index of element 0.
    let base: Int
    public let count: Int
    let byteStride: Int

    init(message: MessageBuilder, base: Int, count: Int, byteStride: Int) {
        self.message = message
        self.base = base
        self.count = count
        self.byteStride = byteStride
    }

    public subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count, "list index out of range")
            var value: Element = 0
            for k in 0..<byteStride {
                value |= Element(message.byte(at: base + index * byteStride + k)) &<< (8 * Element(k))
            }
            return value
        }
        nonmutating set {
            precondition(index >= 0 && index < count, "list index out of range")
            let p = base + index * byteStride
            for k in 0..<byteStride {
                message.writeByte(p + k, UInt8(truncatingIfNeeded: newValue >> (8 * Element(k))))
            }
        }
    }
}

/// Writes a Bool list (element size 1, bits LSB-first).
public struct BitListBuilder {
    let message: MessageBuilder
    /// Byte index of bit 0.
    let base: Int
    public let count: Int

    init(message: MessageBuilder, base: Int, count: Int) {
        self.message = message
        self.base = base
        self.count = count
    }

    public subscript(index: Int) -> Bool {
        get {
            precondition(index >= 0 && index < count, "list index out of range")
            let byte = message.byte(at: base + index / 8)
            return (byte >> UInt8(index % 8)) & 1 == 1
        }
        nonmutating set {
            precondition(index >= 0 && index < count, "list index out of range")
            let i = base + index / 8
            let mask = UInt8(1) << UInt8(index % 8)
            let old = message.byte(at: i)
            message.writeByte(i, newValue ? old | mask : old & ~mask)
        }
    }
}

/// Writes an inline-composite struct list: a tag word (element count in its
/// offset field, element sizes in its size fields) then the elements.
public struct StructListBuilder {
    let message: MessageBuilder
    let firstElementWord: Int
    public let count: Int
    let dataWords: Int
    let pointerWords: Int

    init(message: MessageBuilder, firstElementWord: Int, count: Int, dataWords: Int, pointerWords: Int) {
        self.message = message
        self.firstElementWord = firstElementWord
        self.count = count
        self.dataWords = dataWords
        self.pointerWords = pointerWords
    }

    public subscript(index: Int) -> StructBuilder {
        precondition(index >= 0 && index < count, "list index out of range")
        let word = firstElementWord + index * (dataWords + pointerWords)
        return StructBuilder(
            message: message,
            dataStart: word * 8,
            dataWords: dataWords,
            pointerStartWord: word + dataWords,
            pointerWords: pointerWords)
    }
}

extension MessageBuilder {
    /// The byte at `index` of the segment (list-builder access).
    func byte(at index: Int) -> UInt8 { segment[index] }

    /// Point the absolute pointer word `pointerWord` at a new struct (for
    /// pointer-list elements, whose pointer words live outside any one
    /// struct's pointer section).
    public func initStructAt(pointerWord: Int, dataWords: UInt16, pointerWords: UInt16) -> StructBuilder {
        allocateStruct(pointerWord: pointerWord, dataWords: dataWords, pointerWords: pointerWords)
    }

    /// Allocate a fixed-size element list at `pointerWord`. The pointer's
    /// element-size field must match the element width.
    func allocateFixedSizeList(pointerWord: Int, elementSize: UInt8, count: Int) -> Int {
        let bytes = count * fixedElementStride(elementSize)
        let start = allocate(words: max((bytes + 7) / 8, 1)) * 8
        let offset = Int32(start / 8 - (pointerWord + 1))
        let word = UInt64(UInt32(bitPattern: offset << 2)) | 1 | UInt64(elementSize) << 32 | UInt64(count) << 35
        writeWord(pointerWord, word)
        return start
    }

    /// Allocate a Bool (bit) list at `pointerWord`.
    func allocateBitList(pointerWord: Int, count: Int) -> Int {
        let bytes = (count + 7) / 8
        let start = allocate(words: max((bytes + 7) / 8, 1)) * 8
        let offset = Int32(start / 8 - (pointerWord + 1))
        let word = UInt64(UInt32(bitPattern: offset << 2)) | 1 | UInt64(ElementSize.bit.rawValue) << 32 | UInt64(count) << 35
        writeWord(pointerWord, word)
        return start
    }

    /// Allocate an inline-composite struct list at `pointerWord`. The list
    /// pointer's count field holds the total content words including the tag.
    func allocateStructList(pointerWord: Int, dataWords: UInt16, pointerWords: UInt16, count: Int) -> StructListBuilder {
        let stride = Int(dataWords) + Int(pointerWords)
        let tagWordIndex = allocate(words: 1 + stride * count)
        // The tag is a struct pointer: offset field = element count, sizes =
        // the element's own.
        let tag = UInt64(UInt32(bitPattern: Int32(count) << 2)) | UInt64(dataWords) << 32 | UInt64(pointerWords) << 48
        writeWord(tagWordIndex, tag)
        let offset = Int32(tagWordIndex - (pointerWord + 1))
        let word = UInt64(UInt32(bitPattern: offset << 2)) | 1 | UInt64(ElementSize.composite.rawValue) << 32 | UInt64(1 + stride * count) << 35
        writeWord(pointerWord, word)
        return StructListBuilder(message: self, firstElementWord: tagWordIndex + 1, count: count, dataWords: Int(dataWords), pointerWords: Int(pointerWords))
    }

    /// An element list of pointers (Text, Data, structs, nested lists).
    func allocatePointerList(pointerWord: Int, count: Int) -> Int {
        let startWord = allocate(words: max(count, 1))
        let offset = Int32(startWord - (pointerWord + 1))
        let word = UInt64(UInt32(bitPattern: offset << 2)) | 1 | UInt64(ElementSize.pointer.rawValue) << 32 | UInt64(count) << 35
        writeWord(pointerWord, word)
        return startWord * 8
    }

    func fixedElementStride(_ elementSize: UInt8) -> Int {
        switch elementSize {
        case ElementSize.byte.rawValue: return 1
        case ElementSize.twoBytes.rawValue: return 2
        case ElementSize.fourBytes.rawValue: return 4
        case ElementSize.eightBytes.rawValue: return 8
        default: preconditionFailure("not a fixed-size element")
        }
    }
}

extension StructBuilder {
    /// Text list field at pointer slot `index`.
    public func initTextList(_ index: Int, count: Int) -> PointerListBuilderSlice {
        let start = message.allocatePointerList(pointerWord: pointerWord(index), count: count)
        return PointerListBuilderSlice(message: message, startByte: start, count: count)
    }

    public func initFixedSizeList<Element: FixedWidthInteger>(_ index: Int, count: Int, as: Element.Type = Element.self) -> FixedSizeListBuilder<Element> {
        let size: UInt8
        switch MemoryLayout<Element>.stride {
        case 1: size = ElementSize.byte.rawValue
        case 2: size = ElementSize.twoBytes.rawValue
        case 4: size = ElementSize.fourBytes.rawValue
        case 8: size = ElementSize.eightBytes.rawValue
        default: preconditionFailure("unsupported element width")
        }
        let start = message.allocateFixedSizeList(pointerWord: pointerWord(index), elementSize: size, count: count)
        return FixedSizeListBuilder(message: message, base: start, count: count, byteStride: MemoryLayout<Element>.stride)
    }

    public func initBoolList(_ index: Int, count: Int) -> BitListBuilder {
        let start = message.allocateBitList(pointerWord: pointerWord(index), count: count)
        return BitListBuilder(message: message, base: start, count: count)
    }

    public func initStructList(_ index: Int, dataWords: UInt16, pointerWords: UInt16, count: Int) -> StructListBuilder {
        message.allocateStructList(pointerWord: pointerWord(index), dataWords: dataWords, pointerWords: pointerWords, count: count)
    }
}

/// Write access to a pointer-element list: element i's pointer word sits at
/// `startByte + i*8` (builders target those words with the ordinary
/// `allocate*` entry points through `pointerWordIndex(of:)`).
public struct PointerListBuilderSlice {
    let message: MessageBuilder
    let startByte: Int
    public let count: Int

    /// The word index of element `i`'s pointer (for `initStruct`-style
    /// builders that take a pointer word index).
    public func pointerWordIndex(of element: Int) -> Int {
        precondition(element >= 0 && element < count, "list index out of range")
        return (startByte + element * 8) / 8
    }
}

extension PointerListBuilderSlice {
    /// Text element `i`: a NUL-terminated byte list at its pointer word.
    public func setTextElement(_ element: Int, _ text: String) {
        var bytes = Array(text.utf8)
        bytes.append(0)
        message.allocateByteList(pointerWord: pointerWordIndex(of: element), bytes: bytes)
    }

    /// Data element `i`: a byte list at its pointer word.
    public func setDataElement(_ element: Int, _ data: [UInt8]) {
        message.allocateByteList(pointerWord: pointerWordIndex(of: element), bytes: data)
    }
}
