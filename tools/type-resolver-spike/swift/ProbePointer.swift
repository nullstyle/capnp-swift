// Experimental pointer copying compiled ONLY into the method-generics probe's
// temporary Capnp module. This file is not a shipping runtime interface.
public struct ProbePointer: Sendable {
    fileprivate let message: Message
    fileprivate let segment: Int
    fileprivate let position: Int?
    fileprivate let depth: Int

    public struct Limits: Sendable {
        public var words: Int
        public var depth: Int
        public init(words: Int = 1_048_576, depth: Int = 64) { self.words = words; self.depth = depth }
    }

    /// Copy the reachable value, preserving wire layout and mapping every
    /// capability index into the destination payload's table. Type arguments
    /// are erased: a byte list is copied without guessing Text versus Data.
    public func copy(into destination: StructBuilder, index: Int, limits: Limits = .init(),
                     capability: (UInt32) throws -> UInt32) throws {
        try withoutActuallyEscaping(capability) { mapping in
            var copy = Copy(source: message, destination: destination.message, remaining: limits.words, capability: mapping)
            let target = destination.pointerWord(index)
            guard let position else { destination.message.writeWord(target, 0); return }
            try copy.pointer(segment: segment, position: position, target: target, depth: min(depth, limits.depth))
        }
    }

    private struct Copy {
        let source: Message
        let destination: MessageBuilder
        var remaining: Int
        let capability: (UInt32) throws -> UInt32

        mutating func charge(_ words: Int) throws {
            guard words >= 0, words <= remaining else { throw CapnpError.malformed("probe pointer copy budget exceeded") }
            remaining -= words
        }

        func bytes(segment: Int, start: Int, count: Int) throws -> ArraySlice<UInt8> {
            guard segment >= 0, segment < source.segments.count, start >= 0, count >= 0,
                  start <= source.segments[segment].count, count <= source.segments[segment].count - start else {
                throw CapnpError.malformed("probe pointer content out of its segment")
            }
            let base = source.segments[segment].lowerBound + start
            return source.bytes[base..<(base + count)]
        }

        mutating func pointer(segment: Int, position: Int, target: Int, depth: Int) throws {
            guard target >= 0, target < destination.segment.count / 8 else {
                throw CapnpError.malformed("probe pointer destination out of its segment")
            }
            try charge(1)
            guard let resolved = try source.resolve(segment: segment, pos: position, depth: depth) else {
                destination.writeWord(target, 0)
                return
            }
            let p = resolved.ptr
            let start = resolved.base + p.offset * 8
            switch p.kind {
            case 0:
                let dw = p.structDataWords, pw = p.structPointerWords
                let content = try bytes(segment: resolved.segment, start: start, count: (dw + pw) * 8)
                try charge(dw + pw)
                let builder = destination.allocateStruct(pointerWord: target, dataWords: UInt16(dw), pointerWords: UInt16(pw))
                destination.writeBytes(builder.dataStart, content.prefix(dw * 8))
                for i in 0..<pw {
                    try pointer(segment: resolved.segment, position: start + (dw + i) * 8,
                                target: builder.pointerStartWord + i, depth: depth - 1)
                }
            case 1:
                let count = p.listElementCount, size = p.listElementSize
                if size == ElementSize.composite.rawValue {
                    _ = try bytes(segment: resolved.segment, start: start, count: (count + 1) * 8)
                    let tag = Pointer(word: try source.word(segment: resolved.segment, pos: start))
                    guard tag.kind == 0, tag.offset >= 0 else { throw CapnpError.malformed("probe composite tag invalid") }
                    let elements = tag.offset, dw = tag.structDataWords, pw = tag.structPointerWords
                    let words = (dw + pw) * elements
                    guard words <= count else { throw CapnpError.malformed("probe composite extent exceeds word count") }
                    // Charge elements too: zero-size structs must not create an
                    // unbounded traversal even though they allocate no words.
                    try charge(words + elements + 1)
                    let list = destination.allocateStructList(pointerWord: target, dataWords: UInt16(dw), pointerWords: UInt16(pw), count: elements)
                    for e in 0..<elements {
                        let element = list[e]
                        let sourceStart = start + 8 + e * (dw + pw) * 8
                        destination.writeBytes(element.dataStart, try bytes(segment: resolved.segment, start: sourceStart, count: dw * 8))
                        for i in 0..<pw {
                            try pointer(segment: resolved.segment, position: sourceStart + (dw + i) * 8,
                                        target: element.pointerStartWord + i, depth: depth - 1)
                        }
                    }
                } else if size == ElementSize.pointer.rawValue {
                    _ = try bytes(segment: resolved.segment, start: start, count: count * 8)
                    try charge(count)
                    // The allocator returns a byte offset; recursive copies
                    // target pointer-word indexes.
                    let first = destination.allocatePointerList(pointerWord: target, count: count) / 8
                    for i in 0..<count {
                        try pointer(segment: resolved.segment, position: start + i * 8, target: first + i, depth: depth - 1)
                    }
                } else {
                    let length: Int
                    switch size {
                    case 0: length = 0
                    case 1: length = (count + 7) / 8
                    case 2: length = count
                    case 3: length = count * 2
                    case 4: length = count * 4
                    case 5: length = count * 8
                    default: throw CapnpError.malformed("probe list size invalid")
                    }
                    let content = try bytes(segment: resolved.segment, start: start, count: length)
                    let words = max(1, (length + 7) / 8)
                    try charge(words)
                    let first = destination.allocate(words: words)
                    destination.writeBytes(first * 8, content)
                    let offset = Int32(first - target - 1)
                    destination.writeWord(target, UInt64(UInt32(bitPattern: offset << 2)) | 1 | UInt64(size) << 32 | UInt64(count) << 35)
                }
            case 3:
                guard p.isCapability else { throw CapnpError.malformed("probe capability pointer invalid") }
                let mapped = try capability(p.capabilityIndex)
                destination.writeWord(target, 3 | UInt64(mapped) << 32)
            default:
                throw CapnpError.malformed("probe pointer kind invalid")
            }
        }
    }
}

extension StructReader {
    public func probePointer(_ index: Int) -> ProbePointer {
        ProbePointer(message: message, segment: segment, position: pointerPos(index), depth: depth)
    }
}
