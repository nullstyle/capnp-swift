@_spi(Generated) import Capnp
import Testing

private struct PointerTestEnum: RawRepresentable, Sendable {
    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }
}

private enum PointerTestBox<T: CapnpPointerSchema>: CapnpStructSchema {
    static var dataWords: UInt16 { 1 }
    static var pointerWords: UInt16 { 1 }
    typealias Value = PointerReader
    struct Reader: Sendable {
        let pointer: PointerReader
        func value() throws -> T.Reader { try T.read(from: pointer.field(0)) }
        func number() throws -> UInt64 { try pointer.readStruct().readUInt64(at: 0) }
    }
    typealias Builder = StructBuilder
    static func initialize(at pointer: PointerBuilder) -> StructBuilder {
        pointer.initializeStruct(dataWords: dataWords, pointerWords: pointerWords)
    }
    static func read(from pointer: PointerReader) throws -> Reader { Reader(pointer: pointer) }
    static func write(_ value: PointerReader, to pointer: PointerBuilder) throws { try value.copy(to: pointer) }
}

@Suite("Capnp.PointerSchema")
struct PointerSchemaTests {
    private func value<S: CapnpPointerSchema>(_ value: S.Value, as schema: S.Type) throws -> PointerReader {
        let builder = PointerBuilder()
        try S.write(value, to: builder)
        return try builder.freeze()
    }

    private func words(_ values: [UInt64]) -> [UInt8] {
        values.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> (8 * UInt64($0))) } }
    }

    private func singleSegment(_ values: [UInt64]) -> [UInt8] {
        [0, 0, 0, 0] + (0..<4).map { UInt8(truncatingIfNeeded: values.count >> ($0 * 8)) } + words(values)
    }

    private func rejects(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch is CapnpError { return true } catch { return false }
    }

    @Test("pointer text codec matches independent wire literal and defaults")
    func textCodecAndDefaults() throws {
        let text = try value("h", as: CapnpText.self)
        let encoded = try text.serialized().bytes
        let independent: [UInt8] = [0, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 18, 0, 0, 0,
                                    104, 0, 0, 0, 0, 0, 0, 0]
        let null = try PointerBuilder().freeze()
        let wrong = PointerBuilder()
        _ = wrong.initializeStruct(dataWords: 1, pointerWords: 0)
        let invalidUTF8 = try value([UInt8(0xff), 0], as: CapnpData.self)
        let missingNUL = try value([UInt8(104)], as: CapnpData.self)
        let okay = try CapnpText.read(from: text) == "h" && encoded == independent
          && CapnpText.read(from: null) == "" && CapnpData.read(from: null).isEmpty
          && CapnpText.read(from: wrong.freeze()) == ""
          && rejects { _ = try CapnpText.read(from: invalidUTF8) }
          && rejects { _ = try CapnpText.read(from: missingNUL) }
        #expect(okay, "pointer text codec matches independent wire literal and defaults")
    }

    @Test("pointer list codecs preserve scalar bits and nested pointer layout")
    func listCodecs() throws {
        let integers = try value([Int16.min, -1, 0, Int16.max], as: CapnpList<Int16>.self)
        let bits = try value([true, false, true, false, false, false, false, true, true], as: CapnpList<Bool>.self)
        let floats = try value([Float(-0.0), Float.infinity, Float(bitPattern: 0x7fc01234)], as: CapnpList<Float>.self)
        let nested = try value([["a", ""], ["b"]], as: CapnpList<CapnpList<CapnpText>>.self)
        let voids = try value([(), (), ()], as: CapnpList<CapnpVoid>.self)
        let enums = try value([PointerTestEnum(rawValue: 0), PointerTestEnum(rawValue: 65535)],
                              as: CapnpList<CapnpEnum<PointerTestEnum>>.self)
        let copy = PointerBuilder()
        try nested.copy(to: copy)
        let decodedFloats = try CapnpList<Float>.read(from: floats).map(\.bitPattern)
        let okay = try CapnpList<Int16>.read(from: integers) == [Int16.min, -1, 0, Int16.max]
          && CapnpList<Bool>.read(from: bits) == [true, false, true, false, false, false, false, true, true]
          && decodedFloats == [0x80000000, 0x7f800000, 0x7fc01234]
          && CapnpList<CapnpList<CapnpText>>.read(from: copy.freeze()) == [["a", ""], ["b"]]
          && CapnpList<CapnpVoid>.read(from: voids).count == 3
          && CapnpList<CapnpEnum<PointerTestEnum>>.read(from: enums).map(\.rawValue) == [0, 65535]
        #expect(okay, "pointer list codecs preserve scalar bits and nested pointer layout")
    }

    @Test("pointer struct lists retain unknown words and typed nested fields")
    func structListUnknownFields() throws {
        let source = PointerBuilder()
        let raw = source.initializeStruct(dataWords: 2, pointerWords: 2)
        raw.setUInt64(at: 0, 11)
        raw.setUInt64(at: 8, 0x1122334455667788)
        try CapnpText.write("known", to: source.field(raw, index: 0))
        try CapnpData.write([9, 8, 7], to: source.field(raw, index: 1))
        let root = try value([source.freeze(), PointerBuilder().freeze()], as: CapnpList<PointerTestBox<CapnpText>>.self)
        let boxes = try CapnpList<PointerTestBox<CapnpText>>.read(from: root)
        let element = try #require(boxes.first)
        let copied = PointerBuilder()
        try element.pointer.copy(to: copied)
        let frozen = try copied.freeze()
        let okay = try element.value() == "known" && element.number() == 11
          && frozen.readStruct().readUInt64(at: 8) == 0x1122334455667788
          && frozen.field(1).readData() == [9, 8, 7]
          && root.readStructList().count == 2 && boxes[1].value() == "" && boxes[1].number() == 0
        #expect(okay, "pointer struct lists retain unknown words and typed nested fields")
    }

    @Test("pointer capability copying merges sources and deduplicates handles")
    func capabilityMerge() throws {
        let first = PointerCapability("first"), second = PointerCapability("second")
        let left = PointerBuilder()
        try left.setCapability(first)
        let right = PointerBuilder()
        try right.setCapability(second)
        let merged = PointerBuilder()
        let raw = merged.initializeStruct(dataWords: 0, pointerWords: 3)
        try left.freeze().copy(to: merged.field(raw, index: 0))
        try left.freeze().copy(to: merged.field(raw, index: 1))
        try right.freeze().copy(to: merged.field(raw, index: 2))
        let snapshot = try merged.freeze()
        let serialized = try snapshot.serialized()
        let standalone = try PointerReader(bytes: serialized.bytes, capabilities: serialized.capabilities)
        let dangling = try PointerReader(bytes: singleSegment([3 | UInt64(4) << 32]))
        let okay = try snapshot.capabilities.count == 2 && standalone.capabilities.count == 2
          && snapshot.field(0).capability() === first && snapshot.field(1).capability() === first
          && standalone.field(2).capability() === second
          && rejects { try dangling.copy(to: PointerBuilder()) }
        #expect(okay, "pointer capability copying merges sources and deduplicates handles")
    }

    @Test("pointer snapshots retain message storage independently of builders")
    func snapshotLifetime() throws {
        var retained: PointerReader
        do {
            let root = PointerBuilder()
            _ = root.initializeStruct(dataWords: 0, pointerWords: 1)
            let field = try root.field(0)
            try field.setText("before")
            retained = try field.freeze()
            try field.setText("after")
        }
        let projected = try retained.serialized()
        let independent = try PointerReader(bytes: projected.bytes)
        let okay = try retained.readText() == "before" && independent.readText() == "before"
        #expect(okay, "pointer snapshots retain message storage independently of builders")
    }

    @Test("pointer copying rejects allocation and traversal budget exhaustion")
    func copyBudget() throws {
        let source = try value([UInt16(1), 2, 3, 4, 5], as: CapnpList<UInt16>.self)
        let zeroStructs = try PointerReader(bytes: singleSegment([1 | UInt64(7) << 32,
                                                                 UInt64(1000) << 2]))
        let okay = rejects { try source.copy(to: PointerBuilder(), limits: .init(words: 1)) }
          && rejects { try zeroStructs.copy(to: PointerBuilder(), limits: .init(words: 10)) }
        #expect(okay, "pointer copying rejects allocation and traversal budget exhaustion")
    }

    @Test("pointer copying rejects malformed struct and composite extents")
    func malformedExtents() throws {
        let oversized = try PointerReader(bytes: singleSegment([UInt64(1) << 48]))
        let badComposite = try PointerReader(bytes: singleSegment([1 | UInt64(7) << 32 | UInt64(1) << 35,
                                                                  UInt64(2) << 2 | UInt64(1) << 32, 0]))
        let okay = rejects { try oversized.copy(to: PointerBuilder()) }
          && rejects { try badComposite.copy(to: PointerBuilder()) }
          && rejects { _ = try badComposite.readStructList() }
        #expect(okay, "pointer copying rejects malformed struct and composite extents")
    }

    @Test("pointer copying rejects cycles at the configured depth")
    func depthLimit() throws {
        // Root struct has one pointer; that pointer points to its own struct.
        let cyclic = try PointerReader(bytes: singleSegment([UInt64(1) << 48,
                                                             UInt64(UInt32(bitPattern: -1 << 2)) | UInt64(1) << 48]))
        let okay = rejects { try cyclic.copy(to: PointerBuilder(), limits: .init(words: 1000, depth: 4)) }
        #expect(okay, "pointer copying rejects cycles at the configured depth")
    }

    @Test("pointer composite-list copying matches reader depth boundaries")
    func compositeDepthBoundary() throws {
        func nested(_ count: Int) throws -> PointerReader {
            let root = PointerBuilder()
            _ = root.initializeStruct(dataWords: 0, pointerWords: 1)
            var field = try root.field(0)
            for _ in 0..<count {
                let element = try field.initializeStructList(1, dataWords: 0, pointerWords: 1)[0]
                field = try element.field(0)
            }
            try field.setText("leaf")
            return try root.freeze()
        }

        func leaf(_ value: PointerReader, lists: Int) throws -> String {
            var field = try value.field(0)
            for _ in 0..<lists {
                guard let element = try field.readStructList().first else {
                    throw CapnpError.malformed("missing nested list element")
                }
                field = try element.field(0)
            }
            return try field.readText()
        }

        func legacyLeaf(_ value: PointerReader, lists: Int) throws -> String {
            var raw = try value.readStruct()
            for _ in 0..<lists {
                guard let list = try raw.readStructList(0), let element = list.indices.first else {
                    throw CapnpError.malformed("missing nested list element")
                }
                raw = list[element]
            }
            return try raw.readText(0)
        }

        func copiedLeaf(_ value: PointerReader, lists: Int, depth: Int = 64) -> Bool {
            do {
                let destination = PointerBuilder()
                try value.copy(to: destination, limits: .init(depth: depth))
                return try leaf(destination.freeze(), lists: lists) == "leaf"
            } catch { return false }
        }

        // One root struct, 62 list pointers and the Text pointer use all 64
        // pointer steps. An inline list element does not spend another step.
        let accepted = try nested(62), rejected = try nested(63), small = try nested(4)
        let okay = try leaf(accepted, lists: 62) == "leaf"
          && legacyLeaf(accepted, lists: 62) == "leaf"
          && copiedLeaf(accepted, lists: 62)
          && rejects { _ = try leaf(rejected, lists: 63) }
          && rejects { _ = try legacyLeaf(rejected, lists: 63) }
          && rejects { try rejected.copy(to: PointerBuilder()) }
          && copiedLeaf(small, lists: 4, depth: 6)
          && rejects { try small.copy(to: PointerBuilder(), limits: .init(depth: 5)) }
        #expect(okay, "pointer composite-list copying matches reader depth boundaries")
    }

    @Test("retained terminal inline scalar values copy at zero remaining depth")
    func retainedInlineScalarDepth() throws {
        func retainedLeaf(pointerWords: UInt16) throws -> PointerReader {
            let root = PointerBuilder()
            _ = root.initializeStruct(dataWords: 0, pointerWords: 1)
            var field = try root.field(0)
            for _ in 0..<62 {
                field = try field.initializeStructList(1, dataWords: 0, pointerWords: 1)[0].field(0)
            }
            let terminal = try field.initializeStructList(1, dataWords: 1, pointerWords: pointerWords)[0]
            terminal.initializeStruct(dataWords: 1, pointerWords: pointerWords).setUInt64(at: 0, 42)
            if pointerWords != 0 { try terminal.field(0).setText("child") }
            let whole = try root.freeze()
            if pointerWords == 0 { try whole.copy(to: PointerBuilder()) }
            var list = try whole.field(0)
            for _ in 0..<62 { list = try list.readStructList()[0].field(0) }
            return try list.readStructList()[0]
        }

        // Only this leaf retains its source storage after the helper returns.
        // The root and 63 list pointers spent all 64 pointer steps already.
        let scalar = try retainedLeaf(pointerWords: 0), child = try retainedLeaf(pointerWords: 1)
        func copiedScalar() -> Bool {
            do {
                let destination = PointerBuilder()
                try scalar.copy(to: destination)
                return try destination.freeze().readStruct().readUInt64(at: 0) == 42
            } catch { return false }
        }
        let okay = try scalar.readStruct().readUInt64(at: 0) == 42 && copiedScalar()
          && rejects { try child.copy(to: PointerBuilder()) }
          && rejects { _ = try child.field(0).readText() }
          && rejects { try scalar.copy(to: PointerBuilder(), limits: .init(depth: 0)) }
        #expect(okay, "retained terminal inline scalar values copy at zero remaining depth")
    }

    @Test("pointer copying resolves independent far and double far fixtures")
    func farPointers() throws {
        let single: [UInt8] = [1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0]
          + words([2 | UInt64(1) << 32, UInt64(1) << 32, 13])
        let double: [UInt8] = [2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0]
          + words([6 | UInt64(1) << 32, 2 | UInt64(2) << 32, UInt64(1) << 32, 17])
        let a = PointerBuilder(), b = PointerBuilder()
        try PointerReader(bytes: single).copy(to: a)
        try PointerReader(bytes: double).copy(to: b)
        let okay = try a.freeze().readStruct().readUInt64(at: 0) == 13
          && b.freeze().readStruct().readUInt64(at: 0) == 17
        #expect(okay, "pointer copying resolves independent far and double far fixtures")
    }
}
