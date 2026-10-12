import Capnp
import CapnpRPC
import Dispatch
import Foundation

private typealias Child = SpecializedRoot.ChildCapability
private typealias Parent = Child.Super0
private typealias Named = SpecializedRoot.NamedCapability
private typealias Batch = SpecializedRoot.BatchCapability
private typealias Swap = SpecializedRoot.SwapCapability
private struct Failure: Error, CustomStringConvertible { let description: String }

// One erased implementation handles every call-site type argument. No type
// argument is guessed from bytes or sent in a private RPC envelope.
private struct EchoServer: Child.Server {
    func echo(params: Parent.EchoParams.Reader, on connection: RPCConnection) async throws -> Parent.EchoResults.Value {
        let scope: String = try params.scope() // Outer stays concretely Text.
        let value = params.value()
        return try .init { try $0.setValue(value); $0.setScope("ack:" + scope) }
    }
}
private struct NamedServer: Named.Server {
    func echo(params: Named.EchoParams.Reader, on connection: RPCConnection) async throws -> Named.EchoResults.Value {
        let value = params.value()
        return try .init { try $0.setValue(value) }
    }
}
private struct SwapServer: Swap.Server {
    func swap(params: Swap.SwapParams.Reader, on connection: RPCConnection) async throws -> Swap.SwapResults.Value {
        let first = params.first(), second = params.second()
        return try .init { try $0.setFirst(second); try $0.setSecond(first) }
    }
}

private struct BatchServer: Batch.Server {
    func gather(params: Batch.GatherParams.Reader, on connection: RPCConnection) async throws -> Batch.GatherResults.Value {
        guard let values = try params.values() else { return try .init() }
        return try .init { builder in
            let output = builder.initValues(values.count)
            for i in values.indices { try output[i].setValue(values[i].value()) }
        }
    }
}

@main
struct VerifyMethodSpecializations {
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure(description: name) }
        print("PASS: \(name)")
    }
    static func connected(_ handler: any ExportHandler) async throws -> (RPCConnection, RPCConnection, CapRef) {
        let (a, b) = LoopbackTransport.pair()
        var options = RPCConnection.Options()
        options.callTimeout = .seconds(5)
        options.tickInterval = .milliseconds(20)
        let server = try await RPCConnection.connect(transport: a, bootstrap: handler, options: options)
        let client = try await RPCConnection.connect(transport: b, options: options)
        do { return (server, client, try await client.bootstrap()) }
        catch { await client.close(); await server.close(); throw error }
    }
    static func close(_ server: RPCConnection, _ client: RPCConnection) async {
        await client.close(); await server.close()
        _ = await client.waitClosed(); _ = await server.waitClosed()
    }
    static func inherited() async throws {
        let (server, connection, cap) = try await connected(Child.Export(EchoServer()))
        let client = Child.Client(cap: cap, connection: connection).super0
        do {
            let text = try await client.echoAsText { $0.setScope("text"); $0.setValue("héllo") }
            let data = try await client.echoAsData { $0.setScope("data"); $0.setValue([0, 1, 255]) }
            try check((try text.value()) == "héllo" && (try data.value()) == [0, 1, 255], "one erased server handles Text and Data on the same method")
            try check((try text.scope()) == "ack:text" && (try data.scope()) == "ack:data", "method bindings preserve the outer interface parameter and payload layout")
            let empty = try await client.echoAsText { $0.setScope("empty") }
            try check((try empty.value()).isEmpty && (try empty.scope()) == "ack:empty", "erased method values preserve null defaults")
            let numbers = try await client.echoAsNumbers {
                $0.setScope("numbers")
                let list = $0.initValue(3); list[0] = 7; list[1] = 65535; list[2] = 9
            }
            let list = try numbers.value()
            try check(list?.count == 3 && list?[0] == 7 && list?[1] == 65535 && list?[2] == 9, "method argument binds an integer list")
            let boxed = try await client.echoAsBox { $0.setScope("box"); $0.initValue().setValue("boxed") }
            try check((try boxed.value().value()) == "boxed", "method argument binds a nested generic struct")
            let boxes = try await client.echoAsBoxes {
                $0.setScope("boxes"); let list = $0.initValue(2)
                list[0].setValue("first"); list[1].setValue("second")
            }
            let entries = try boxes.value()
            try check(entries?.count == 2 && (try entries?[0].value()) == "first" && (try entries?[1].value()) == "second", "method argument binds a struct list")
        } catch { await close(server, connection); throw error }
        await close(server, connection)
    }
    static func named() async throws {
        let (server, connection, cap) = try await connected(Named.Export(NamedServer()))
        let client = Named.Client(cap: cap, connection: connection)
        do {
            let text = try await client.echoAsText { $0.setValue("named") }
            let data = try await client.echoAsData { $0.setValue([9, 0, 8]) }
            let nested = try await client.echoAsNested { $0.initValue().setValue("inside") }
            try check((try text.value()) == "named" && (try data.value()) == [9, 0, 8] && (try nested.value().value()) == "inside", "named payload brands bind implicit method references")
        } catch { await close(server, connection); throw error }
        await close(server, connection)
    }
    static func swap() async throws {
        let (server, connection, cap) = try await connected(Swap.Export(SwapServer()))
        let client = Swap.Client(cap: cap, connection: connection)
        do {
            let a = try await client.swapAsTextData { $0.setFirst("first"); $0.setSecond([4, 5]) }
            let b = try await client.swapAsDataText { $0.setFirst([6, 7]); $0.setSecond("second") }
            try check((try a.first()) == [4, 5] && (try a.second()) == "first" && (try b.first()) == "second" && (try b.second()) == [6, 7], "two method arguments remain distinct across reversed results")
        } catch { await close(server, connection); throw error }
        await close(server, connection)
    }

    static func batch() async throws {
        let (server, connection, cap) = try await connected(Batch.Export(BatchServer()))
        let client = Batch.Client(cap: cap, connection: connection)
        do {
            let text = try await client.gatherAsText { let list = $0.initValues(2); list[0].setValue("one"); list[1].setValue("two") }
            let data = try await client.gatherAsData { let list = $0.initValues(2); list[0].setValue([1, 0]); list[1].setValue([2, 255]) }
            let boxed = try await client.gatherAsBox { let list = $0.initValues(2); list[0].initValue().setValue("box0"); list[1].initValue().setValue("box1") }
            let texts = try text.values(), datas = try data.values(), boxes = try boxed.values()
            try check(texts?.count == 2 && (try texts?[0].value()) == "one" && (try texts?[1].value()) == "two" && datas?.count == 2 && (try datas?[0].value()) == [1, 0] && (try datas?[1].value()) == [2, 255] && boxes?.count == 2 && (try boxes?[0].value().value()) == "box0" && (try boxes?[1].value().value()) == "box1", "list elements bind method parameters for Text Data and structs")
        } catch { await close(server, connection); throw error }
        await close(server, connection)
    }

    // Negative pointer-copy gates avoid a network validator masking the
    // prototype's own checks. They cross the same interface as server glue.
    static func copyChecks() throws {
        let source = MessageBuilder(), destination = MessageBuilder()
        let root = source.initRoot(dataWords: 0, pointerWords: 1)
        root.setText(0, "bounded")
        let pointer = try Message(bytes: source.toBytes()).rootStruct().probePointer(0)
        let target = destination.initRoot(dataWords: 0, pointerWords: 1)
        var budgetRejected = false
        do { try pointer.copy(into: target, index: 0, limits: .init(words: 0)) { $0 } }
        catch CapnpError.malformed(let reason) { budgetRejected = reason == "probe pointer copy budget exceeded" }
        try check(budgetRejected, "erased pointer copying enforces its allocation budget")
        var malformed = source.toBytes()
        // Field 0 points well beyond its segment.
        let invalid: UInt64 = (1000 << 2) | 1 | (2 << 32) | (3 << 35)
        for i in 0..<8 { malformed[16 + i] = UInt8(truncatingIfNeeded: invalid >> (i * 8)) }
        var malformedRejected = false
        do { try Message(bytes: malformed).rootStruct().probePointer(0).copy(into: target, index: 0) { $0 } }
        catch CapnpError.malformed(let reason) { malformedRejected = reason == "probe pointer content out of its segment" }
        try check(malformedRejected, "erased pointer copying rejects malformed extents")

        var cyclic = source.toBytes()
        let cycle: UInt64 = 0x0001_0000_ffff_fffc
        for i in 0..<8 { cyclic[16 + i] = UInt8(truncatingIfNeeded: cycle >> (i * 8)) }
        var depthRejected = false
        do { try Message(bytes: cyclic).rootStruct().probePointer(0).copy(into: target, index: 0, limits: .init(depth: 4)) { $0 } }
        catch CapnpError.malformed(let reason) { depthRejected = reason == "pointer nesting too deep" }
        try check(depthRejected, "erased pointer copying bounds cyclic traversal")

        // A capability nested inside a struct must be rewritten once, using
        // the destination table's index. This also covers a data section.
        let capSource = MessageBuilder(), capDestination = MessageBuilder()
        let input = capSource.initRoot(dataWords: 0, pointerWords: 1).initStruct(0, dataWords: 1, pointerWords: 1)
        input.setUInt64(at: 0, 42); input.setCapability(0, capIndex: 7)
        let capTarget = capDestination.initRoot(dataWords: 0, pointerWords: 1)
        var mapped: [UInt32] = []
        try Message(bytes: capSource.toBytes()).rootStruct().probePointer(0).copy(into: capTarget, index: 0) { index in mapped.append(index); return 2 }
        let copied = try Message(bytes: capDestination.toBytes()).rootStruct().readStruct(0)
        try check(mapped == [7] && (try copied.readCapabilityIndex(0)) == 2 && copied.readUInt64(at: 0) == 42, "erased pointer copying remaps nested capabilities and preserves data")

        // A pointer list stores two independent Text pointers. The allocator
        // returns their byte location; copying addresses them as word indexes.
        let listSource = MessageBuilder(), listDestination = MessageBuilder()
        let texts = listSource.initRoot(dataWords: 0, pointerWords: 1).initTextList(0, count: 2)
        texts.setTextElement(0, "first"); texts.setTextElement(1, "second")
        let listTarget = listDestination.initRoot(dataWords: 0, pointerWords: 1)
        var pointerListCopied = false
        do {
            try Message(bytes: listSource.toBytes()).rootStruct().probePointer(0).copy(into: listTarget, index: 0) { $0 }
            if let output = try Message(bytes: listDestination.toBytes()).rootStruct().readPointerList(0) {
                pointerListCopied = try output.count == 2 && output.textElement(0) == "first" && output.textElement(1) == "second"
            }
        } catch CapnpError.malformed(let reason) {
            guard reason == "probe pointer destination out of its segment" else { throw CapnpError.malformed(reason) }
        }
        try check(pointerListCopied, "erased pointer copying preserves pointer-list element offsets")

        // Independent single-/double-far layout: root in segment 0, a
        // two-word pad in segment 1, Text content in segment 2.
        let words: [UInt64] = [
            0x0000_0002_0000_0002, 0x0000_0001_0000_0002,
            0x0001_0000_0000_0000, 0x0000_0001_0000_0006,
            0x0000_0002_0000_0002, 0x0000_0022_0000_0001, 0x0000_0000_0072_6166,
        ]
        let farBytes: [UInt8] = words.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
        let farOut = MessageBuilder(), farTarget = farOut.initRoot(dataWords: 0, pointerWords: 1)
        try Message(bytes: farBytes).rootStruct().probePointer(0).copy(into: farTarget, index: 0) { $0 }
        try check((try Message(bytes: farOut.toBytes()).rootStruct().readText(0)) == "far", "erased pointer copying follows double-far pointers")
    }
    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("FAIL: method specialization watchdog expired\n".utf8)); exit(1)
        }
        do { try copyChecks(); try await inherited(); try await named(); try await swap(); try await batch() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
