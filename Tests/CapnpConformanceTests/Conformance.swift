// The M3 conformance gate (plan §8): the C++-written TestAllTypes fixtures,
// in all four encodings, read through capnpc-swift-generated code, compared
// field by field against the compiler's pretty.json.
//
// Out-of-range enum and discriminant reads never trap (plan §6): checked on
// synthetic bytes at the end.

import Capnp
import CapnpTestSchemas
import Foundation
import Testing

private func fixture(_ path: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("capnp_testdata/testdata/\(path)")
    return try Data(contentsOf: url).map { $0 }
}

private func prettyJSON() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("capnp_testdata/testdata/pretty.json")
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

private func int64(_ v: Any) -> Int64 {
    if let n = v as? Int64 { return n }
    if let n = v as? Int { return Int64(n) }
    if let s = v as? String { return Int64(s)! }
    fatalError("bad int \(v)")
}

private func uint64(_ v: Any) -> UInt64 {
    if let n = v as? UInt64 { return n }
    if let n = v as? Int { return UInt64(n) }
    if let s = v as? String { return UInt64(s)! }
    fatalError("bad uint \(v)")
}

/// pretty.json renders enums as their names.
private func enumRaw(_ v: Any) -> UInt64 {
    if let n = v as? Int { return UInt64(n) }
    if let s = v as? String {
        switch s {
        case "foo": return 0
        case "bar": return 1
        case "baz": return 2
        case "qux": return 3
        case "quux": return 4
        case "corge": return 5
        case "grault": return 6
        case "garply": return 7
        default: fatalError("unknown enum name \(s)")
        }
    }
    fatalError("bad enum \(v)")
}

private func double(_ v: Any) -> Double {
    if let n = v as? Double { return n }
    if let s = v as? String {
        switch s {
        case "Infinity": return .infinity
        case "-Infinity": return -.infinity
        case "NaN": return .nan
        default: return Double(s)!
        }
    }
    fatalError("bad double \(v)")
}

private func floatEq(_ a: Float, _ b: Double) -> Bool {
    if a.isNaN { return b.isNaN }
    return Double(a) == b
}

private func doubleEq(_ a: Double, _ b: Double) -> Bool {
    if a.isNaN { return b.isNaN }
    return a == b
}

/// Field-by-field comparison of a TestAllTypes reader against its JSON dump.
/// Every JSON key must be understood; unknown keys fail the test.
private func compare(_ reader: TestAllTypes.Reader, _ json: [String: Any], _ where_: String, _ problems: inout [String]) {
    for (key, value) in json {
        var ok = true
        switch key {
        case "voidField", "interfaceField":
            continue
        case "boolField": ok = reader.boolField == (value as! Bool)
        case "int8Field": ok = reader.int8Field == Int8(int64(value))
        case "int16Field": ok = reader.int16Field == Int16(int64(value))
        case "int32Field": ok = reader.int32Field == Int32(int64(value))
        case "int64Field": ok = reader.int64Field == int64(value)
        case "uInt8Field": ok = reader.uInt8Field == UInt8(uint64(value))
        case "uInt16Field": ok = reader.uInt16Field == UInt16(uint64(value))
        case "uInt32Field": ok = reader.uInt32Field == UInt32(uint64(value))
        case "uInt64Field": ok = reader.uInt64Field == uint64(value)
        case "float32Field": ok = floatEq(reader.float32Field, double(value))
        case "float64Field": ok = doubleEq(reader.float64Field, double(value))
        case "enumField": ok = reader.enumField.rawValue == enumRaw(value)
        case "textField": ok = (try? reader.textField()) == (value as! String)
        case "dataField": ok = (try? reader.dataField()) == (value as! [Int]).map(UInt8.init)
        case "structField":
            compare(reader.structField, value as! [String: Any], where_ + ".structField", &problems)
            continue
        case "anyPointerField":
            continue
        case "voidList":
            continue
        case "boolList": ok = ((try? reader.boolList())?.elements() ?? []) == (value as! [Any]).map { $0 as! Bool }
        case "int8List": ok = ((try? reader.int8List())?.elements() ?? []) == (value as! [Any]).map { Int8(int64($0)) }
        case "int16List": ok = ((try? reader.int16List())?.elements() ?? []) == (value as! [Any]).map { Int16(int64($0)) }
        case "int32List": ok = ((try? reader.int32List())?.elements() ?? []) == (value as! [Any]).map { Int32(int64($0)) }
        case "int64List": ok = ((try? reader.int64List())?.elements() ?? []) == (value as! [Any]).map { int64($0) }
        case "uInt8List": ok = ((try? reader.uInt8List())?.elements() ?? []) == (value as! [Any]).map { UInt8(uint64($0)) }
        case "uInt16List": ok = ((try? reader.uInt16List())?.elements() ?? []) == (value as! [Any]).map { UInt16(uint64($0)) }
        case "uInt32List": ok = ((try? reader.uInt32List())?.elements() ?? []) == (value as! [Any]).map { UInt32(uint64($0)) }
        case "uInt64List": ok = ((try? reader.uInt64List())?.elements() ?? []) == (value as! [Any]).map { uint64($0) }
        case "float32List":
            let got = (try? reader.float32List())?.elements() ?? []
            let want = (value as! [Any]).map { double($0) }
            ok = got.count == want.count && zip(got, want).allSatisfy { floatEq($0.0, $0.1) }
        case "float64List":
            let got = (try? reader.float64List())?.elements() ?? []
            let want = (value as! [Any]).map { double($0) }
            ok = got.count == want.count && zip(got, want).allSatisfy { doubleEq($0.0, $0.1) }
        case "textList":
            let got = (try? reader.textList()) ?? nil
            let want = value as! [String]
            var texts: [String] = []
            if let got, let list = try? got.count { _ = list }
            if let got {
                for i in got.indices { texts.append((try? got.textElement(i)) ?? "") }
            }
            ok = texts == want
        case "dataList":
            let want = (value as! [[Any]]).map { $0.map { UInt8(uint64($0)) } }
            var datas: [[UInt8]] = []
            if let got = try? reader.dataList() {
                for i in got.indices { datas.append((try? got.dataElement(i)) ?? []) }
            }
            ok = datas == want
        case "enumList": ok = ((try? reader.enumListElements()) ?? []) == (value as! [Any]).map { TestEnum(rawValue: UInt16(enumRaw($0))) }
        case "structList":
            let want = value as! [[String: Any]]
            if let got = try? reader.structList() {
                if got.count != want.count {
                    problems.append("\(where_).structList count \(got.count) != \(want.count)")
                    continue
                }
                for (i, element) in want.enumerated() {
                    compare(got[i], element, "\(where_).structList[\(i)]", &problems)
                }
            } else {
                problems.append("\(where_).structList missing")
            }
            continue
        case "interfaceList":
            continue
        default:
            problems.append("\(where_): unknown JSON key \(key)")
            continue
        }
        if !ok {
            problems.append("\(where_).\(key): reader mismatch (json \(value))")
        }
    }
}

@Suite("Conformance")
struct ConformanceTests {
    @Test("the four C++ fixture encodings match pretty.json through generated readers")
    func fixtures() async throws {
        let json = try prettyJSON()
        for name in ["binary", "segmented", "packed", "segmented-packed"] {
            let raw = try fixture(name)
            let unpacked: [UInt8] = name.contains("packed") ? try Packed.unpack(raw) : raw
            let message = try Message(bytes: unpacked)
            let root = try TestAllTypes.Reader(message.rootStruct())
            var problems: [String] = []
            compare(root, json, name, &problems)
            #expect(problems.isEmpty, "\(name): \(problems.joined(separator: "; ").prefix(300))")
        }
    }

    @Test("out-of-range enum and discriminant values never trap")
    func outOfRangeNeverTraps() throws {
        // A TestAllTypes-sized struct of 0xFF bytes: every enum reads an
        // unknown raw value, every pointer is garbage-but-bounded.
        var bytes: [UInt8] = [0, 0, 0, 0, 5, 0, 0, 0] // 1 segment, 5 words
        bytes.append(contentsOf: [UInt8](repeating: 0xFF, count: 5 * 8))
        // Root pointer: offset 0, 4 data words, 0 pointers -> all 0xFF bytes
        // is a valid struct pointer (kind bits 0b11 = capability!) — rebuild:
        bytes.replaceSubrange(8..<16, with: [0, 0, 0, 0, 4, 0, 0, 0])
        let message = try Message(bytes: bytes)
        let root: TestAllTypes.Reader
        do {
            root = try TestAllTypes.Reader(message.rootStruct())
        } catch {
            Issue.record("rootStruct threw: \(error); bytes=\(bytes.map { String($0, radix: 16) })")
            return
        }
        let raw = root.enumField.rawValue
        #expect(root.enumField.isKnown == (raw < 3))
        _ = root.enumField
        // A discriminant beyond the union cases reads as
        // .unknownDiscriminant, never traps. TestUnion.union0's discriminant
        // sits at byte 0 of the struct.
        var ubytes: [UInt8] = [0, 0, 0, 0, 6, 0, 0, 0] // 1 segment, 6 words
        ubytes.append(contentsOf: [UInt8](repeating: 0, count: 6 * 8))
        ubytes.replaceSubrange(8..<16, with: [0, 0, 0, 0, 5, 0, 0, 0]) // root struct: offset 0, 5 data words
        // The struct's first byte is the segment's second word (array byte 16).
        ubytes[16] = 0xFF
        ubytes[17] = 0xFF
        let union0 = TestUnion.Reader(try Message(bytes: ubytes).rootStruct()).union0
        if case .unknownDiscriminant(let raw) = union0.which {
            #expect(raw == 0xFFFF)
        } else {
            Issue.record("expected .unknownDiscriminant, got \(union0.which)")
        }
    }
}
