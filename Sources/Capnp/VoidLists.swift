/// A list with no element payload. Only its count is stored on the wire.
public struct VoidListReader: Sendable {
    public let count: Int

    init(message: Message, list: Message.ResolvedList) throws {
        guard list.pointer.listElementSize == ElementSize.void.rawValue else {
            throw CapnpError.wrongPointerKind(expected: "void list")
        }
        _ = try message.contentBase(segment: list.segment, start: list.contentStart, bytes: 0, what: "void list")
        count = list.pointer.listElementCount
    }

    public var isEmpty: Bool { count == 0 }
    public var indices: Range<Int> { 0..<count }
    public subscript(index: Int) -> Void {
        precondition(indices.contains(index), "list index out of range")
    }
}

/// Building a Void list writes its count once; elements have no data to set.
public struct VoidListBuilder {
    public let count: Int
    public var isEmpty: Bool { count == 0 }
    public var indices: Range<Int> { 0..<count }
    public subscript(index: Int) -> Void {
        get { precondition(indices.contains(index), "list index out of range") }
        nonmutating set { precondition(indices.contains(index), "list index out of range") }
    }
}

extension StructReader {
    public func readVoidList(_ index: Int) throws -> VoidListReader? {
        guard let pos = pointerPos(index), let list = try message.listAt(segment: segment, pos: pos, depth: depth) else { return nil }
        return try VoidListReader(message: message, list: list)
    }

    public func readVoidListOrDefault(_ index: Int) throws -> VoidListReader? {
        do { return try readVoidList(index) }
        catch let error as CapnpError {
            if case .wrongPointerKind = error { return nil }
            throw error
        }
    }
}

extension StructBuilder {
    public func initVoidList(_ index: Int, count: Int) -> VoidListBuilder {
        precondition(count >= 0 && count < 1 << 29, "invalid void list count")
        // Offset -1 places the zero-byte content extent at this pointer word.
        message.writeWord(pointerWord(index), UInt64(UInt32(bitPattern: -1 << 2)) | 1 | UInt64(count) << 35)
        return VoidListBuilder(count: count)
    }
}
