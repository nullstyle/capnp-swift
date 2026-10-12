/// A schema type legal in a Cap'n Proto pointer slot. Scalar types deliberately
/// do not conform; they may be elements of `CapnpList` instead.
public protocol CapnpPointerSchema: CapnpListElementSchema {
    static func read(from pointer: PointerReader) throws -> Reader
    static func write(_ value: Value, to pointer: PointerBuilder) throws
}

public protocol CapnpStructSchema: CapnpPointerSchema {
    associatedtype Builder
    static var dataWords: UInt16 { get }
    static var pointerWords: UInt16 { get }
    static func initialize(at pointer: PointerBuilder) -> Builder
}

/// An immutable RPC-owned handle. Serialization retains and remaps these
/// tokens without interpreting their payload or importing the RPC module.
@_spi(Generated) public final class PointerCapability: Sendable {
    public let payload: any Sendable
    public init(_ payload: any Sendable) { self.payload = payload }
}

private final class PointerCapabilityBag {
    var tokens: [PointerCapability] = []
    var indexes: [ObjectIdentifier: UInt32] = [:]

    func append(_ token: PointerCapability) throws -> UInt32 {
        let key = ObjectIdentifier(token)
        if let index = indexes[key] { return index }
        guard let index = UInt32(exactly: tokens.count) else {
            throw CapnpError.malformed("pointer capability table too large")
        }
        indexes[key] = index
        tokens.append(token)
        return index
    }
}

/// An immutable pointer value retaining its message and capability handles.
/// Descendant values and inline-composite elements retain the same storage.
public struct PointerReader: Sendable {
    fileprivate let message: Message
    fileprivate let segment: Int
    fileprivate let position: Int?
    fileprivate let structure: StructReader?
    fileprivate let depth: Int
    fileprivate let tokens: [PointerCapability]

    public struct CopyLimits: Sendable {
        public var words: Int
        public var depth: Int
        public init(words: Int = 1_048_576, depth: Int = 64) {
            self.words = words; self.depth = depth
        }
    }

    public init(bytes: [UInt8]) throws {
        try self.init(message: Message(bytes: bytes), tokens: [])
    }

    @_spi(Generated) public init(bytes: [UInt8], capabilities: [PointerCapability]) throws {
        try self.init(message: Message(bytes: bytes), tokens: capabilities)
    }

    fileprivate init(message: Message, tokens: [PointerCapability]) throws {
        guard !message.segments.isEmpty, message.segments[0].count >= 8 else {
            throw CapnpError.malformed("no root pointer")
        }
        self.init(message: message, segment: 0, position: 0, structure: nil,
                  depth: Message.maxDepth, tokens: tokens)
    }

    fileprivate init(message: Message, segment: Int, position: Int?, structure: StructReader?,
                     depth: Int, tokens: [PointerCapability]) {
        self.message = message; self.segment = segment; self.position = position
        self.structure = structure; self.depth = depth; self.tokens = tokens
    }

    public func read<S: CapnpPointerSchema>(as schema: S.Type) throws -> S.Reader {
        try S.read(from: self)
    }

    public func readStruct() throws -> StructReader {
        if let structure { return structure }
        guard let position else { return .empty(in: message, depth: depth) }
        do { return try message.structAt(segment: segment, pos: position, depth: depth) }
        catch let error as CapnpError {
            if case .wrongPointerKind = error { return .empty(in: message, depth: depth) }
            throw error
        }
    }

    /// Generated glue: `raw` must be a descendant of this reader's message.
    @_spi(Generated) public func field(_ raw: StructReader, index: Int) -> PointerReader {
        PointerReader(message: raw.message, segment: raw.segment, position: raw.pointerPos(index),
                      structure: nil, depth: raw.depth, tokens: tokens)
    }

    public func field(_ index: Int) throws -> PointerReader { field(try readStruct(), index: index) }

    /// Generated glue: `raw` must be a descendant of this reader's message.
    @_spi(Generated) public func element(_ raw: StructReader) -> PointerReader {
        PointerReader(message: raw.message, segment: raw.segment, position: nil,
                      structure: raw, depth: raw.depth, tokens: tokens)
    }

    public func readText() throws -> String {
        guard let bytes = try byteList() else { return "" }
        guard bytes.last == 0 else { throw CapnpError.malformed("Text without its NUL terminator") }
        guard let result = String(validating: bytes.dropLast(), as: UTF8.self) else {
            throw CapnpError.invalidText
        }
        return result
    }

    public func readData() throws -> [UInt8] { Array(try byteList() ?? []) }

    private func byteList() throws -> ArraySlice<UInt8>? {
        guard structure == nil, let position else { return nil }
        do { return try message.byteListAt(segment: segment, pos: position, depth: depth) }
        catch let error as CapnpError {
            if case .wrongPointerKind = error { return nil }
            throw error
        }
    }

    private func list() throws -> Message.ResolvedList? {
        guard structure == nil, let position else { return nil }
        do {
            guard let list = try message.listAt(segment: segment, pos: position, depth: depth) else { return nil }
            guard list.contentStart >= 0 else { throw CapnpError.malformed("list offset negative") }
            return list
        } catch let error as CapnpError {
            if case .wrongPointerKind = error { return nil }
            throw error
        }
    }

    public func readIntegerList<E: FixedWidthInteger & Sendable>(as type: E.Type) throws -> [E] {
        guard let list = try list() else { return [] }
        do { return try FixedSizeListReader<E>(message: message, list: list).elements() }
        catch let error as CapnpError { if case .wrongPointerKind = error { return [] }; throw error }
    }

    public func readBoolList() throws -> [Bool] {
        guard let list = try list() else { return [] }
        do { return try BitListReader(message: message, list: list).elements() }
        catch let error as CapnpError { if case .wrongPointerKind = error { return [] }; throw error }
    }

    public func readVoidListCount() throws -> Int {
        guard let list = try list(), list.pointer.listElementSize == ElementSize.void.rawValue else { return 0 }
        guard list.pointer.listElementCount <= 1_048_576 else { throw CapnpError.malformed("void list element budget exceeded") }
        return list.pointer.listElementCount
    }

    public func readPointerList() throws -> [PointerReader] {
        guard let list = try list(), list.pointer.listElementSize == ElementSize.pointer.rawValue else { return [] }
        let raw = try PointerListReader(message: message, list: list, depth: depth - 1)
        guard raw.count <= 1_048_576 else { throw CapnpError.malformed("pointer list element budget exceeded") }
        return raw.indices.map {
            PointerReader(message: message, segment: raw.segment, position: raw.startPos + $0 * 8,
                          structure: nil, depth: raw.depth, tokens: tokens)
        }
    }

    public func readStructList() throws -> [PointerReader] {
        guard let list = try list(), list.pointer.listElementSize == ElementSize.composite.rawValue else { return [] }
        let raw = try StructListReader(message: message, list: list, depth: depth)
        guard raw.count <= 1_048_576 else { throw CapnpError.malformed("struct list element budget exceeded") }
        let words = (raw.dataWords + raw.pointerWords) * raw.count
        guard words <= list.pointer.listElementCount else { throw CapnpError.malformed("composite extent exceeds word count") }
        _ = try message.contentBase(segment: list.segment, start: list.contentStart,
                                    bytes: (list.pointer.listElementCount + 1) * 8, what: "composite list")
        return raw.indices.map { element(raw[$0]) }
    }

    @_spi(Generated) public var capabilities: [PointerCapability] { tokens }

    @_spi(Generated) public func capability() throws -> PointerCapability? {
        guard structure == nil, let position,
              let index = try message.capabilityAt(segment: segment, pos: position, depth: depth) else { return nil }
        guard Int(index) < tokens.count else { throw CapnpError.malformed("capability index outside pointer table") }
        return tokens[Int(index)]
    }

    /// Copies the reachable value, including unknown struct fields. A failed
    /// copy leaves the builder unfinished; discard it before producing a value.
    public func copy(to destination: PointerBuilder, limits: CopyLimits = .init()) throws {
        guard limits.words >= 0, limits.depth > 0 else { throw CapnpError.malformed("invalid pointer copy limits") }
        var copy = PointerCopy(source: message, tokens: tokens, destination: destination,
                               remaining: limits.words)
        if let structure {
            try copy.structure(structure, destination: destination, depth: min(depth, limits.depth))
        } else if let position {
            try copy.pointer(segment: segment, position: position, destination: destination,
                             depth: min(depth, limits.depth))
        } else {
            if let raw = destination.structure { try copy.charge(raw.dataWords + raw.pointerWords) }
            try destination.setNull()
        }
    }

    @_spi(Generated) public func serialized(limits: CopyLimits = .init()) throws
      -> (bytes: [UInt8], capabilities: [PointerCapability]) {
        let destination = PointerBuilder()
        try copy(to: destination, limits: limits)
        return (destination.message.toBytes(), destination.bag.tokens)
    }
}

/// A mutable pointer location retaining its allocation storage and one shared
/// token collector. Builders are intentionally not Sendable.
public struct PointerBuilder {
    fileprivate let message: MessageBuilder
    fileprivate let word: Int?
    fileprivate let structure: StructBuilder?
    fileprivate let bag: PointerCapabilityBag

    public init() { self.init(message: MessageBuilder()) }

    /// `message` must be fresh: this location is its root pointer.
    public init(message: MessageBuilder) {
        self.message = message; word = 0; structure = nil; bag = PointerCapabilityBag()
    }

    fileprivate init(message: MessageBuilder, word: Int?, structure: StructBuilder?, bag: PointerCapabilityBag) {
        self.message = message; self.word = word; self.structure = structure; self.bag = bag
    }

    public func write<S: CapnpPointerSchema>(_ value: S.Value, as schema: S.Type) throws {
        try S.write(value, to: self)
    }

    public func initializeStruct(dataWords: UInt16, pointerWords: UInt16) -> StructBuilder {
        if let structure {
            precondition(Int(dataWords) <= structure.dataWords && Int(pointerWords) <= structure.pointerWords,
                         "schema exceeds inline struct element")
            return structure
        }
        precondition(word != nil, "no pointer destination")
        return message.allocateStruct(pointerWord: word ?? 0, dataWords: dataWords, pointerWords: pointerWords)
    }

    @_spi(Generated) public func field(_ raw: StructBuilder, index: Int) -> PointerBuilder {
        precondition(raw.message === message, "builder belongs to another message")
        return PointerBuilder(message: message, word: raw.pointerWord(index), structure: nil, bag: bag)
    }

    @_spi(Generated) public func element(_ raw: StructBuilder) -> PointerBuilder {
        precondition(raw.message === message, "builder belongs to another message")
        return PointerBuilder(message: message, word: nil, structure: raw, bag: bag)
    }

    /// A field of the struct currently stored at this location. The child
    /// retains the allocation owner and the same capability collector.
    public func field(_ index: Int) throws -> PointerBuilder {
        if let structure {
            guard index >= 0, index < structure.pointerWords else {
                throw CapnpError.malformed("pointer field outside the struct")
            }
            return field(structure, index: index)
        }
        guard let word else { throw CapnpError.wrongPointerKind(expected: "struct destination") }
        let pointer = Pointer(word: message.readWord(word))
        guard pointer.kind == 0, !pointer.isNull else {
            throw CapnpError.wrongPointerKind(expected: "initialized struct destination")
        }
        let start = word + 1 + pointer.offset
        guard start >= 0, start <= message.segment.count / 8,
              pointer.structDataWords + pointer.structPointerWords <= message.segment.count / 8 - start,
              index >= 0, index < pointer.structPointerWords else {
            throw CapnpError.malformed("pointer field outside the struct")
        }
        let raw = StructBuilder(message: message, dataStart: start * 8,
                                dataWords: pointer.structDataWords,
                                pointerStartWord: start + pointer.structDataWords,
                                pointerWords: pointer.structPointerWords)
        return field(raw, index: index)
    }

    public func freeze() throws -> PointerReader {
        let snapshot = try Message(bytes: message.toBytes())
        if let structure {
            let raw = StructReader(message: snapshot, segment: 0, dataStart: structure.dataStart,
                                   dataBytes: structure.dataWords * 8, pointerStart: structure.pointerStartWord * 8,
                                   pointerCount: structure.pointerWords, depth: Message.maxDepth)
            return PointerReader(message: snapshot, segment: 0, position: nil, structure: raw,
                                 depth: Message.maxDepth, tokens: bag.tokens)
        }
        return PointerReader(message: snapshot, segment: 0, position: word.map { $0 * 8 }, structure: nil,
                             depth: Message.maxDepth, tokens: bag.tokens)
    }

    public func setNull() throws {
        if let structure {
            for i in 0..<structure.dataWords { message.writeWord(structure.dataStart / 8 + i, 0) }
            for i in 0..<structure.pointerWords { message.writeWord(structure.pointerStartWord + i, 0) }
            return
        }
        guard let word else { throw CapnpError.wrongPointerKind(expected: "pointer destination") }
        message.writeWord(word, 0)
    }

    public func setText(_ value: String) throws {
        try setData(Array(value.utf8) + [0])
    }

    public func setData(_ value: [UInt8]) throws {
        guard let word else { throw CapnpError.wrongPointerKind(expected: "pointer destination") }
        guard value.count < 1 << 29 else { throw CapnpError.malformed("byte list too large") }
        message.allocateByteList(pointerWord: word, bytes: value)
    }

    public func setIntegerList<E: FixedWidthInteger>(_ values: [E]) throws {
        let width = MemoryLayout<E>.stride
        let size: UInt8
        switch width { case 1: size = 2; case 2: size = 3; case 4: size = 4; case 8: size = 5
        default: throw CapnpError.malformed("unsupported integer list width") }
        guard let word, values.count < 1 << 29 else { throw CapnpError.malformed("invalid integer list destination or count") }
        let start = message.allocateFixedSizeList(pointerWord: word, elementSize: size, count: values.count)
        for (index, value) in values.enumerated() {
            for byte in 0..<width {
                message.writeByte(start + index * width + byte, UInt8(truncatingIfNeeded: value >> (byte * 8)))
            }
        }
    }

    public func setBoolList(_ values: [Bool]) throws {
        guard let word, values.count < 1 << 29 else { throw CapnpError.malformed("invalid bool list destination or count") }
        let start = message.allocateBitList(pointerWord: word, count: values.count)
        for (index, value) in values.enumerated() where value {
            let position = start + index / 8
            let previous = UInt8(truncatingIfNeeded: message.readWord(position / 8) >> (8 * UInt64(position % 8)))
            message.writeByte(position, previous | 1 << UInt8(index % 8))
        }
    }

    public func setVoidList(count: Int) throws {
        guard let word, count >= 0, count <= 1_048_576 else { throw CapnpError.malformed("invalid void list count") }
        // Zero-sized elements need no backing content; the offset -1 keeps
        // the zero-byte extent inside even a root-only message.
        message.writeWord(word, UInt64(UInt32(bitPattern: -1 << 2)) | 1 | UInt64(count) << 35)
    }

    public func initializePointerList(_ count: Int) throws -> [PointerBuilder] {
        guard let word, count >= 0, count <= 1_048_576 else { throw CapnpError.malformed("invalid pointer list count") }
        let first = message.allocatePointerList(pointerWord: word, count: count) / 8
        return (0..<count).map { PointerBuilder(message: message, word: first + $0, structure: nil, bag: bag) }
    }

    public func initializeStructList(_ count: Int, dataWords: UInt16, pointerWords: UInt16) throws -> [PointerBuilder] {
        guard let word, count >= 0, count <= 1_048_576,
              count * (Int(dataWords) + Int(pointerWords)) < 1 << 29 else {
            throw CapnpError.malformed("invalid struct list count")
        }
        let raw = message.allocateStructList(pointerWord: word, dataWords: dataWords, pointerWords: pointerWords, count: count)
        return (0..<count).map { element(raw[$0]) }
    }

    @_spi(Generated) public var capabilities: [PointerCapability] { bag.tokens }

    @_spi(Generated) public func setCapability(_ token: PointerCapability?) throws {
        guard let word else { throw CapnpError.wrongPointerKind(expected: "capability destination") }
        guard let token else { message.writeWord(word, 0); return }
        message.writeWord(word, 3 | UInt64(try bag.append(token)) << 32)
    }
}

private struct PointerCopy {
    let source: Message
    let tokens: [PointerCapability]
    let destination: PointerBuilder
    var remaining: Int

    mutating func charge(_ words: Int) throws {
        guard words >= 0, words <= remaining else { throw CapnpError.malformed("pointer copy budget exceeded") }
        remaining -= words
    }

    func bytes(segment: Int, start: Int, count: Int) throws -> ArraySlice<UInt8> {
        guard segment >= 0, segment < source.segments.count, start >= 0, count >= 0,
              start <= source.segments[segment].count, count <= source.segments[segment].count - start else {
            throw CapnpError.malformed("pointer content out of its segment")
        }
        let base = source.segments[segment].lowerBound + start
        return source.bytes[base..<(base + count)]
    }

    mutating func structure(_ raw: StructReader, destination: PointerBuilder, depth: Int) throws {
        // An already-resolved inline struct needs no further pointer step to
        // copy its scalar bytes. Its child pointer chases remain depth-checked.
        guard depth >= 0 else { throw CapnpError.malformed("pointer nesting too deep") }
        let dw = raw.dataBytes / 8, pw = raw.pointerCount
        let data = try bytes(segment: raw.segment, start: raw.dataStart, count: raw.dataBytes)
        _ = try bytes(segment: raw.segment, start: raw.pointerStart, count: pw * 8)
        try charge(dw + pw + 1)
        if let existing = destination.structure {
            guard dw <= existing.dataWords, pw <= existing.pointerWords else {
                throw CapnpError.malformed("copied struct exceeds inline element")
            }
        }
        let target = destination.initializeStruct(dataWords: UInt16(dw), pointerWords: UInt16(pw))
        if let existing = destination.structure {
            try charge(existing.dataWords - dw + existing.pointerWords - pw)
            try destination.setNull()
        }
        destination.message.writeBytes(target.dataStart, data)
        for i in 0..<pw {
            try pointer(segment: raw.segment, position: raw.pointerStart + i * 8,
                        destination: destination.field(target, index: i), depth: depth - 1)
        }
    }

    mutating func pointer(segment: Int, position: Int, destination: PointerBuilder, depth: Int) throws {
        try charge(1)
        guard let resolved = try source.resolve(segment: segment, pos: position, depth: depth) else {
            if let raw = destination.structure { try charge(raw.dataWords + raw.pointerWords) }
            try destination.setNull(); return
        }
        let p = resolved.ptr
        let start = resolved.base + p.offset * 8
        switch p.kind {
        case 0:
            let dw = p.structDataWords, pw = p.structPointerWords
            _ = try bytes(segment: resolved.segment, start: start, count: (dw + pw) * 8)
            let raw = StructReader(message: source, segment: resolved.segment, dataStart: start,
                                   dataBytes: dw * 8, pointerStart: start + dw * 8,
                                   pointerCount: pw, depth: depth)
            try structure(raw, destination: destination, depth: depth)
        case 1:
            guard let target = destination.word else { throw CapnpError.wrongPointerKind(expected: "list destination") }
            let count = p.listElementCount, size = p.listElementSize
            if size == ElementSize.composite.rawValue {
                _ = try bytes(segment: resolved.segment, start: start, count: (count + 1) * 8)
                let tag = Pointer(word: try source.word(segment: resolved.segment, pos: start))
                guard tag.kind == 0, tag.offset >= 0 else { throw CapnpError.malformed("composite tag invalid") }
                let elements = tag.offset, dw = tag.structDataWords, pw = tag.structPointerWords
                let words = (dw + pw) * elements
                guard words <= count else { throw CapnpError.malformed("composite extent exceeds word count") }
                try charge(words + elements + 1)
                let list = destination.message.allocateStructList(pointerWord: target, dataWords: UInt16(dw),
                                                                   pointerWords: UInt16(pw), count: elements)
                for e in 0..<elements {
                    let sourceStart = start + 8 + e * (dw + pw) * 8
                    let raw = StructReader(message: source, segment: resolved.segment, dataStart: sourceStart,
                                           dataBytes: dw * 8, pointerStart: sourceStart + dw * 8,
                                           pointerCount: pw, depth: depth - 1)
                    // Inline elements have no pointer edge of their own.
                    // Their child pointers spend the list's depth step below.
                    try structure(raw, destination: destination.element(list[e]), depth: depth)
                }
            } else if size == ElementSize.pointer.rawValue {
                _ = try bytes(segment: resolved.segment, start: start, count: count * 8)
                try charge(count)
                let first = destination.message.allocatePointerList(pointerWord: target, count: count) / 8
                for i in 0..<count {
                    let element = PointerBuilder(message: destination.message, word: first + i, structure: nil, bag: destination.bag)
                    try pointer(segment: resolved.segment, position: start + i * 8, destination: element, depth: depth - 1)
                }
            } else {
                let length: Int
                switch size { case 0: length = 0; case 1: length = (count + 7) / 8
                case 2: length = count; case 3: length = count * 2; case 4: length = count * 4
                case 5: length = count * 8; default: throw CapnpError.malformed("list element size invalid") }
                let content = try bytes(segment: resolved.segment, start: start, count: length)
                let words = max(1, (length + 7) / 8)
                try charge(words)
                let first = destination.message.allocate(words: words)
                destination.message.writeBytes(first * 8, content)
                let offset = Int32(first - target - 1)
                destination.message.writeWord(target, UInt64(UInt32(bitPattern: offset << 2)) | 1 | UInt64(size) << 32 | UInt64(count) << 35)
            }
        case 3:
            guard p.isCapability else { throw CapnpError.malformed("capability pointer invalid") }
            guard Int(p.capabilityIndex) < tokens.count else { throw CapnpError.malformed("capability index outside pointer table") }
            try destination.setCapability(tokens[Int(p.capabilityIndex)])
        default: throw CapnpError.malformed("pointer kind invalid")
        }
    }
}

public enum CapnpText: CapnpPointerSchema {
    public typealias Reader = String
    public typealias Value = String
    public static func read(from pointer: PointerReader) throws -> String { try pointer.readText() }
    public static func write(_ value: String, to pointer: PointerBuilder) throws { try pointer.setText(value) }
}

public enum CapnpData: CapnpPointerSchema {
    public typealias Reader = [UInt8]
    public typealias Value = [UInt8]
    public static func read(from pointer: PointerReader) throws -> [UInt8] { try pointer.readData() }
    public static func write(_ value: [UInt8], to pointer: PointerBuilder) throws { try pointer.setData(value) }
}

public enum CapnpAnyPointer: CapnpPointerSchema {
    public typealias Reader = PointerReader
    public typealias Value = PointerReader
    public static func read(from pointer: PointerReader) throws -> PointerReader { pointer }
    public static func write(_ value: PointerReader, to pointer: PointerBuilder) throws { try value.copy(to: pointer) }
}

/// List element witnesses are separate from pointer witnesses, so UInt16 is
/// legal in List(UInt16) but cannot be a Box(UInt16) schema argument.
public protocol CapnpListElementSchema: Sendable {
    associatedtype Reader: Sendable
    associatedtype Value: Sendable
    static func readList(from pointer: PointerReader) throws -> [Reader]
    static func writeList(_ values: [Value], to pointer: PointerBuilder) throws
}

public enum CapnpList<Element: CapnpListElementSchema>: CapnpPointerSchema {
    public typealias Reader = [Element.Reader]
    public typealias Value = [Element.Value]
    public static func read(from pointer: PointerReader) throws -> Reader { try Element.readList(from: pointer) }
    public static func write(_ value: Value, to pointer: PointerBuilder) throws { try Element.writeList(value, to: pointer) }
}

public enum CapnpVoid: CapnpListElementSchema {
    public typealias Reader = Void
    public typealias Value = Void
    public static func readList(from pointer: PointerReader) throws -> [Void] {
        Array(repeating: (), count: try pointer.readVoidListCount())
    }
    public static func writeList(_ values: [Void], to pointer: PointerBuilder) throws {
        try pointer.setVoidList(count: values.count)
    }
}

/// An enum list element keeps the schema enum's value type. Generated enums
/// have a nonfailing raw-value initializer, preserving unknown discriminants.
public enum CapnpEnum<E: RawRepresentable & Sendable>: CapnpListElementSchema where E.RawValue == UInt16 {
    public typealias Reader = E
    public typealias Value = E
    public static func readList(from pointer: PointerReader) throws -> [E] {
        try pointer.readIntegerList(as: UInt16.self).map {
            guard let value = E(rawValue: $0) else { throw CapnpError.malformed("enum cannot represent its wire value") }
            return value
        }
    }
    public static func writeList(_ values: [E], to pointer: PointerBuilder) throws {
        try pointer.setIntegerList(values.map(\.rawValue))
    }
}

extension CapnpPointerSchema {
    public static func readList(from pointer: PointerReader) throws -> [Reader] {
        try pointer.readPointerList().map { try read(from: $0) }
    }
    public static func writeList(_ values: [Value], to pointer: PointerBuilder) throws {
        let elements = try pointer.initializePointerList(values.count)
        for (element, value) in zip(elements, values) { try write(value, to: element) }
    }
}

extension CapnpStructSchema {
    public static func readList(from pointer: PointerReader) throws -> [Reader] {
        try pointer.readStructList().map { try read(from: $0) }
    }
    public static func writeList(_ values: [Value], to pointer: PointerBuilder) throws {
        // Include unknown fields from newer producers in the composite layout.
        var sources: [PointerReader] = []
        var dw = dataWords, pw = pointerWords
        for value in values {
            let temporary = PointerBuilder()
            try write(value, to: temporary)
            let source = try temporary.freeze(), raw = try source.readStruct()
            dw = max(dw, UInt16(raw.dataBytes / 8)); pw = max(pw, UInt16(raw.pointerCount))
            sources.append(source)
        }
        let elements = try pointer.initializeStructList(values.count, dataWords: dw, pointerWords: pw)
        for (element, source) in zip(elements, sources) { try source.copy(to: element) }
    }
}

extension CapnpListElementSchema where Self: FixedWidthInteger & Sendable, Reader == Self, Value == Self {
    public static func readList(from pointer: PointerReader) throws -> [Self] { try pointer.readIntegerList(as: Self.self) }
    public static func writeList(_ values: [Self], to pointer: PointerBuilder) throws { try pointer.setIntegerList(values) }
}

extension UInt8: CapnpListElementSchema { public typealias Reader = UInt8; public typealias Value = UInt8 }
extension UInt16: CapnpListElementSchema { public typealias Reader = UInt16; public typealias Value = UInt16 }
extension UInt32: CapnpListElementSchema { public typealias Reader = UInt32; public typealias Value = UInt32 }
extension UInt64: CapnpListElementSchema { public typealias Reader = UInt64; public typealias Value = UInt64 }
extension Int8: CapnpListElementSchema { public typealias Reader = Int8; public typealias Value = Int8 }
extension Int16: CapnpListElementSchema { public typealias Reader = Int16; public typealias Value = Int16 }
extension Int32: CapnpListElementSchema { public typealias Reader = Int32; public typealias Value = Int32 }
extension Int64: CapnpListElementSchema { public typealias Reader = Int64; public typealias Value = Int64 }

extension Bool: CapnpListElementSchema {
    public typealias Reader = Bool; public typealias Value = Bool
    public static func readList(from pointer: PointerReader) throws -> [Bool] { try pointer.readBoolList() }
    public static func writeList(_ values: [Bool], to pointer: PointerBuilder) throws { try pointer.setBoolList(values) }
}

extension Float: CapnpListElementSchema {
    public typealias Reader = Float; public typealias Value = Float
    public static func readList(from pointer: PointerReader) throws -> [Float] {
        try pointer.readIntegerList(as: UInt32.self).map { Float(bitPattern: $0) }
    }
    public static func writeList(_ values: [Float], to pointer: PointerBuilder) throws {
        try pointer.setIntegerList(values.map(\.bitPattern))
    }
}

extension Double: CapnpListElementSchema {
    public typealias Reader = Double; public typealias Value = Double
    public static func readList(from pointer: PointerReader) throws -> [Double] {
        try pointer.readIntegerList(as: UInt64.self).map { Double(bitPattern: $0) }
    }
    public static func writeList(_ values: [Double], to pointer: PointerBuilder) throws {
        try pointer.setIntegerList(values.map(\.bitPattern))
    }
}

extension Message {
    public func rootPointer() throws -> PointerReader { try PointerReader(message: self, tokens: []) }
    @_spi(Generated) public func rootPointer(capabilities: [PointerCapability]) throws -> PointerReader {
        try PointerReader(message: self, tokens: capabilities)
    }
}

extension MessageBuilder {
    public func rootPointer() -> PointerBuilder { PointerBuilder(message: self) }
}
