// M3 reader fuzz (plan §8): mutate the committed fixture bytes and walk the
// generated readers over every accessor. The wire layer bounds-checks; the
// plan's rule is that malformed input reads defaults or throws — it never
// traps. Deterministic (a fixed seed), so a failure replays exactly.

import Capnp
import CapnpTestSchemas
import Foundation
import Testing

private func fixtureBytes(_ path: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("capnp_testdata/testdata/\(path)")
    return try Data(contentsOf: url).map { $0 }
}

/// A tiny deterministic PRNG (SplitMix64).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Walk every generated accessor of a TestAllTypes reader (and a bounded
/// recursion through struct fields). No return value: the point is that
/// nothing traps.
private func walk(_ r: TestAllTypes.Reader, depth: Int) throws {
    _ = r.boolField
    _ = r.int8Field
    _ = r.int16Field
    _ = r.int32Field
    _ = r.int64Field
    _ = r.uInt8Field
    _ = r.uInt16Field
    _ = r.uInt32Field
    _ = r.uInt64Field
    _ = r.float32Field
    _ = r.float64Field
    _ = r.enumField
    _ = r.enumField.isKnown
    _ = try? r.textField()
    _ = try? r.dataField()
    if let bools = try? r.boolList() { for i in bools.indices { _ = bools[i] } }
    if let i8 = try? r.int8List() { for i in i8.indices { _ = i8[i] } }
    if let i16 = try? r.int16List() { for i in i16.indices { _ = i16[i] } }
    if let i32 = try? r.int32List() { for i in i32.indices { _ = i32[i] } }
    if let i64 = try? r.int64List() { for i in i64.indices { _ = i64[i] } }
    if let u8 = try? r.uInt8List() { for i in u8.indices { _ = u8[i] } }
    if let u16 = try? r.uInt16List() { for i in u16.indices { _ = u16[i] } }
    if let u32 = try? r.uInt32List() { for i in u32.indices { _ = u32[i] } }
    if let u64 = try? r.uInt64List() { for i in u64.indices { _ = u64[i] } }
    if let f32 = try? r.float32List() { for i in f32.indices { _ = f32[i] } }
    if let f64 = try? r.float64List() { for i in f64.indices { _ = f64[i] } }
    if let texts = try? r.textList() { for i in texts.indices { _ = try? texts.textElement(i) } }
    if let datas = try? r.dataList() { for i in datas.indices { _ = try? datas.dataElement(i) } }
    _ = try? r.enumListElements()
    if let structs = try? r.structList() {
        for i in structs.indices.prefix(64) { try walk(structs[i], depth: depth) }
    }
    if depth > 0 {
        try walk(r.structField, depth: depth - 1)
    }
}

@Suite("ReaderFuzz", .serialized)
struct ReaderFuzzTests {
    @Test("mutated fixture bytes never trap the generated readers", arguments: [0x5eed, 0x1234_5678])
    func mutationWalk(seed: UInt64) throws {
        let seeds = try [
            fixtureBytes("binary"),
            fixtureBytes("segmented"),
            Packed.unpack(try fixtureBytes("packed")),
            Packed.unpack(try fixtureBytes("segmented-packed")),
        ]
        var rng = SplitMix64(seed: seed)
        var parsed = 0
        var rejected = 0
        for i in 0..<2_000 {
            var bytes = seeds[i % seeds.count]
            let mutations = 1 + Int(rng.next() % 4)
            for _ in 0..<mutations {
                let pos = Int(rng.next() % UInt64(bytes.count))
                bytes[pos] = UInt8(truncatingIfNeeded: rng.next())
            }
            if let message = try? Message(bytes: bytes), let root = try? message.rootStruct() {

                if i == 5 && seed == 24301 {
                    FileHandle.standardError.write(Data("CASE \(bytes.map { String($0, radix: 16) }.joined(separator: ","))\n".utf8))
                }
                try walk(TestAllTypes.Reader(root), depth: 3)
                parsed += 1
            } else {
                rejected += 1
            }
        }
        // Both branches must have been exercised (a mutation loop that only
        // produces rejections has no teeth).
        #expect(parsed > 100 && rejected > 100, "parsed=\(parsed) rejected=\(rejected)")
    }
}

@Suite("ReadBench")
struct ReadBench {
    /// The M3 read-speed record (plan §6 option Y): per-u32-read cost over
    /// the binary fixture, in nanoseconds. Not a pass/fail gate; the number
    /// goes into the plan's M3 status. Run: swift test --filter ReadBench.
    @Test("per-u32 read cost over the binary fixture")
    func perReadCost() throws {
        let bytes = try fixtureBytes("binary")
        let message = try Message(bytes: bytes)
        let root = try TestAllTypes.Reader(message.rootStruct())

        func measure(_ reads: Int) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink: UInt32 = 0
            for _ in 0..<reads {
                sink &+= root.uInt32Field
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
            _ = sink
            return elapsed / Double(reads)
        }
        _ = measure(10_000) // warm up
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 { best = min(best, measure(1_000_000)) }
        print(String(format: "read-bench: %.2f ns per u32 field read (best of 5 x 1e6)", best))
    }
}
