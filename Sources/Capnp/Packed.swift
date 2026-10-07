// Packed encoding (capnproto.org/encoding.html#packing), decoder only.
//
// Each output word starts with a tag byte:
//   0x00: the next byte N means "1 + N zero words"
//   0xFF: one literal word follows, then a byte N and N more literal words
//   other: bit i set means "the next literal byte fills byte i of a zeroed
//          word"
// Mirrors capnp-zig's unpackPackedLimited (message.zig): a truncated stream
// is `malformed`, never a partial word.

extension CapnpError {
    static func packed(_ detail: String) -> CapnpError { .malformed("packed: \(detail)") }
}

public enum Packed {
    /// Decode packed bytes to the unpacked message bytes. The output length
    /// is bounded: `maxBytes` (default 512 MiB) rejects amplification.
    public static func unpack(_ packed: [UInt8], maxBytes: Int = 512 * 1024 * 1024) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(packed.count * 2)
        var i = 0
        while i < packed.count {
            let tag = packed[i]
            i += 1
            if tag == 0x00 {
                guard i < packed.count else { throw CapnpError.packed("zero-run missing its count") }
                let extra = Int(packed[i])
                i += 1
                let words = 1 + extra
                try appendZeroWords(words, to: &out, maxBytes: maxBytes)
            } else if tag == 0xFF {
                guard i + 8 <= packed.count else { throw CapnpError.packed("literal word truncated") }
                try appendChecked(ArraySlice(packed[i..<(i + 8)]), to: &out, maxBytes: maxBytes)
                i += 8
                guard i < packed.count else { throw CapnpError.packed("literal run missing its count") }
                let extra = Int(packed[i])
                i += 1
                if extra > 0 {
                    let bytes = extra * 8
                    guard i + bytes <= packed.count else { throw CapnpError.packed("literal run truncated") }
                    try appendChecked(ArraySlice(packed[i..<(i + bytes)]), to: &out, maxBytes: maxBytes)
                    i += bytes
                }
            } else {
                var word = [UInt8](repeating: 0, count: 8)
                var used = 0
                for bit in 0..<8 where tag & (1 << UInt8(bit)) != 0 {
                    guard i < packed.count else { throw CapnpError.packed("partial-word tag truncated") }
                    word[bit] = packed[i]
                    i += 1
                    used += 1
                }
                _ = used
                try appendChecked(ArraySlice(word[0..<8]), to: &out, maxBytes: maxBytes)
            }
        }
        return out
    }

    private static func appendZeroWords(_ words: Int, to out: inout [UInt8], maxBytes: Int) throws {
        let bytes = words * 8
        guard out.count + bytes <= maxBytes else { throw CapnpError.packed("output exceeds the limit") }
        out.append(contentsOf: [UInt8](repeating: 0, count: bytes))
    }

    private static func appendChecked(_ bytes: ArraySlice<UInt8>, to out: inout [UInt8], maxBytes: Int) throws {
        guard out.count + bytes.count <= maxBytes else { throw CapnpError.packed("output exceeds the limit") }
        out.append(contentsOf: bytes)
    }

    /// A `Message` from packed bytes (unpacks, then parses the segment table).
    public static func message(_ packed: [UInt8]) throws -> Message {
        try Message(bytes: unpack(packed))
    }
}
