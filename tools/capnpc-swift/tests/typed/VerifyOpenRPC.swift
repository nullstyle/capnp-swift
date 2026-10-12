@_spi(Generated) import Capnp
@_spi(Generated) import CapnpRPC
import TypedExternal
import Dispatch
import Foundation
import Synchronization

typealias TextParent = Parent.Typed<CapnpText>

struct OpenEcho: Child.TypedServer {
    func echo(params: TextParent.EchoParams<CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws -> TextParent.EchoResults<CapnpAnyPointer>.Value {
        let value = try params.value(), scope = try params.scope()
        return try .init { builder in
            try builder.setValue(value)
            try builder.setScope("ack:\(scope)")
        }
    }
}

struct OpenNamed: Named.TypedServer {
    func echo(params: Box.Typed<CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws -> Box.Typed<CapnpAnyPointer>.Value {
        try .init { try $0.setValue(params.value()) }
    }
}

struct OpenSwap: Swap.TypedServer {
    func swap(params: Swap.Typed.SwapParams<CapnpAnyPointer, CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws -> Swap.Typed.SwapResults<CapnpAnyPointer, CapnpAnyPointer>.Value {
        try .init { try $0.setFirst(params.second()); try $0.setSecond(params.first()) }
    }
}

struct OpenBatch: Batch.TypedServer {
    func gather(params: Batch.Typed.GatherParams<CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws -> Batch.Typed.GatherResults<CapnpAnyPointer>.Value {
        let values = try params.values()
        return try .init { builder in
            let output = builder.initValues(values.count)
            for index in values.indices { try output[index].setValue(values[index].value()) }
        }
    }
}

struct OpenDiamond: IDiamond.TypedServer {
    typealias IDiamond_T_a6558b359c8301f0_0 = CapnpText
    func echo(params: IBase.Typed<CapnpText>.EchoParams.Reader, on connection: isolated RPCConnection) async throws -> IBase.Typed<CapnpText>.EchoResults.Value { try .init { try $0.setValue(params.value()) } }
    func left(params: ILeft.Typed<CapnpText>.LeftParams.Reader, on connection: isolated RPCConnection) async throws -> ILeft.Typed<CapnpText>.LeftResults.Value { try .init { try $0.setValue(params.value()) } }
    func right(params: IRight.Typed<CapnpText>.RightParams.Reader, on connection: isolated RPCConnection) async throws -> IRight.Typed<CapnpText>.RightResults.Value { try .init { try $0.setValue(params.value()) } }
    func local(params: IDiamond.Typed<CapnpText>.LocalParams.Reader, on connection: isolated RPCConnection) async throws -> IDiamond.Typed<CapnpText>.LocalResults.Value { try .init { try $0.setValue(params.value()) } }
}

struct OpenJoined: IJoined.TypedServer {
    typealias IJoined_T_83c36a18023773ee_0 = CapnpText
    func echo(params: IBase.Typed<CapnpText>.EchoParams.Reader, on connection: isolated RPCConnection) async throws -> IBase.Typed<CapnpText>.EchoResults.Value { try .init { try $0.setValue("base:" + params.value()) } }
    func echo(params: IOther.Typed<CapnpText>.EchoParams.Reader, on connection: isolated RPCConnection) async throws -> IOther.Typed<CapnpText>.EchoResults.Value { try .init { try $0.setValue("other:" + params.value()) } }
}

struct OpenLexical: IOuter.IOuter_Inner.TypedServer {
    typealias IOuter_T_e8c6aecd25e3b3d9_0 = CapnpText
    func echo(params: IOuter.Typed<CapnpText>.Inner.EchoParams.Reader, on connection: isolated RPCConnection) async throws -> IOuter.Typed<CapnpText>.Inner.EchoResults.Value { try .init { try $0.setValue(params.value()) } }
}

struct OpenSink: ISink.TypedServer {
    typealias ISink_T_8511b2a1e9faa1ac_0 = CapnpText
    let prefix: String
    func push(params: ISink.Typed<CapnpText>.PushParams.Reader, on connection: isolated RPCConnection) async throws -> ISink.Typed<CapnpText>.PushResults.Value { try .init { try $0.setValue(prefix + params.value()) } }
}

struct OpenFactory: IFactory.TypedServer {
    typealias IFactory_T_a9a678f8dabae716_0 = CapnpText
    func relay(params: IFactory.Typed<CapnpText>.RelayParams.Reader, on connection: isolated RPCConnection) async throws -> IFactory.Typed<CapnpText>.RelayResults.Value {
        guard let callback = try params.callback() else { throw OpenRPCFailure(name: "callback was null") }
        let reply = try await callback.push { try $0.setValue(params.value()) }
        return try .init { try $0.setValue(reply.value()) }
    }
    func make(params: IFactory.Typed<CapnpText>.MakeParams.Reader, on connection: isolated RPCConnection) async throws -> IFactory.Typed<CapnpText>.MakeResults.Value {
        let sink = ISink.Typed<CapnpText>.Client(server: OpenSink(prefix: "made:"), connection: connection)
        return try .init { try $0.setSink(sink) }
    }
    func nested(params: IFactory.Typed<CapnpText>.NestedParams.Reader, on connection: isolated RPCConnection) async throws -> IFactory.Typed<CapnpText>.NestedResults.Value {
        let sink = ISink.Typed<CapnpText>.Client(server: OpenSink(prefix: "nested:"), connection: connection)
        return try .init { builder in
            try builder.initBoxed().setValue(sink)
            try builder.setDirect(sink)
            let list = builder.initMany(2)
            for index in 0..<2 { try list[index].setValue(sink) }
        }
    }
}

struct OpenReserved: IReserved.TypedServer {
    func ping(params: Connection.Typed.PingParams.Reader, on connection: isolated RPCConnection) async throws -> Connection.Typed.PingResults.Value { try .init { $0.setValue("connection view") } }
    func pong(params: Capability.Typed.PongParams.Reader, on connection: isolated RPCConnection) async throws -> Capability.Typed.PongResults.Value { try .init { $0.setValue("capability view") } }
    func unused(params: IUnboundPayload.Typed.Reader, on connection: isolated RPCConnection) async throws -> IUnboundPayload.Typed.Value {
        try .init { builder in builder.setFixedText(try params.fixedText()); builder.setFixedData(try params.fixedData()) }
    }
}

struct OpenRPCFailure: Error { let name: String }
func openCheck(_ result: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try result() else { throw OpenRPCFailure(name: name) }
    print("PASS: \(name)")
}

struct OpenPair {
    let server: RPCConnection
    let client: RPCConnection
    let cap: CapRef
    init(_ handler: any ExportHandler) async throws {
        var options = RPCConnection.Options()
        options.callTimeout = .seconds(12)
        let (a, b) = LoopbackTransport.pair()
        server = try await RPCConnection.connect(transport: b, bootstrap: handler, options: options)
        client = try await RPCConnection.connect(transport: a, options: options)
        cap = try await client.bootstrap()
    }
    func close() async { await client.close(); _ = await server.waitClosed() }
}

@main enum VerifyOpenRPC {
    static func inherited() async throws {
        let pair = try await OpenPair(Child.Typed.Export(OpenEcho()))
        do {
            let client = try Child.Typed.Client(cap: pair.cap, connection: pair.client).parent
            let text = try await client.echo(scope: "text", value: "hello")
            let data = try await client.echo(scope: "data", value: [9, 0, 255])
            try openCheck((try text.value()) == "hello" && (try data.value()) == [9, 0, 255], "one inherited capability accepts open Text and Data arguments")
            try openCheck((try text.scope()) == "ack:text" && (try data.scope()) == "ack:data", "outer bindings survive method argument changes and payload layout")
            let defaults = try await client.echo(as: CapnpText.self)
            try openCheck((try defaults.value()) == "" && (try defaults.scope()) == "ack:", "open generic pointer defaults remain typed")
            let numbers = try await client.echo(as: CapnpList<UInt16>.self) { try $0.setValue([2, 511, 65_535]) }
            try openCheck((try numbers.value()) == [2, 511, 65_535], "open method arguments include primitive lists")
            let box = try await client.echo(as: Box.Typed<CapnpText>.self) { try $0.initValue().setValue("nested") }
            try openCheck((try box.value().value()) == "nested", "open method arguments include generic structs")
            let boxes = try await client.echo(as: CapnpList<Box.Typed<CapnpText>>.self) {
                try $0.setValue([.init { try $0.setValue("one") }, .init { try $0.setValue("two") }])
            }
            let values = try boxes.value()
            try openCheck(values.count == 2 && (try values[0].value()) == "one" && (try values[1].value()) == "two", "open method arguments include inline composite struct lists")
            let external = try await client.echo(as: TypedExternal.Outer.Typed<CapnpData>.Inner<CapnpText>.self) {
                let value = $0.initValue()
                try value.setOuter([4, 0, 5]); try value.setInner("external")
            }
            let foreign = try external.value()
            try openCheck((try foreign.outer()) == [4, 0, 5] && (try foreign.inner()) == "external", "callers supply unseen nested codecs from another module")
            func returnedCapability() async throws -> Child.Typed.Client {
                let callback = Child.Typed.Client(server: OpenEcho(), connection: pair.client)
                let returned = try await client.echo(as: Child.Typed.self) { try $0.setValue(callback) }
                guard let cap = try returned.value() else { throw OpenRPCFailure(name: "returned typed capability was null") }
                return cap
            }
            let retained = try await returnedCapability()
            let response = try await retained.parent.echo(as: CapnpText.self) { try $0.setScope("callback"); try $0.setValue("alive") }
            try openCheck((try response.value()) == "alive" && (try response.scope()) == "ack:callback", "typed returned local capabilities outlive their result readers")
            let unset = try await client.echo(as: Child.Typed.self)
            let explicit = try await client.echo(as: Child.Typed.self) { try $0.setValue(nil) }
            try openCheck((try unset.value()) == nil && (try explicit.value()) == nil, "nullable capability arguments preserve unset and explicit nil values")
            let list = try await client.echo(as: CapnpList<Child.Typed>.self) { try $0.setValue([retained, nil, retained]) }
            let caps = try list.value()
            guard let first = caps.first ?? nil, let last = caps.last ?? nil else { throw OpenRPCFailure(name: "nullable list lost capabilities") }
            let firstReply = try await first.parent.echo(scope: "first", value: "one")
            let lastReply = try await last.parent.echo(scope: "last", value: "three")
            try openCheck(caps.count == 3 && caps[1] == nil && (try firstReply.value()) == "one" && (try lastReply.value()) == "three", "generic capability lists preserve nil elements and callable handles")
            let hole = MessageBuilder(); hole.setRootCapability(index: 0)
            let holeReader = try await pair.client.pointerPayload(bytes: hole.toBytes(), caps: [.none])
            try openCheck((try Child.Typed.read(from: holeReader)) == nil, "nullable interface codecs read capability table holes as nil")
            var unknownInterface = false, unknownMethod = false
            do { _ = try await client.capability.call(interface: 1, method: 0, params: try TextParent.EchoParams<CapnpText>.Value().pointer) }
            catch RPCError.unimplemented { unknownInterface = true }
            do { _ = try await client.capability.call(interface: TextParent.interfaceID, method: UInt16.max, params: try TextParent.EchoParams<CapnpText>.Value().pointer) }
            catch RPCError.unimplemented { unknownMethod = true }
            try openCheck(unknownInterface && unknownMethod, "typed exports reject unknown wire interfaces and ordinals")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    static func named() async throws {
        let pair = try await OpenPair(Named.Typed.Export(OpenNamed()))
        do {
            let client = try Named.Typed.Client(cap: pair.cap, connection: pair.client)
            let text = try await client.echo(value: "named")
            let data = try await client.echo(value: [7, 0, 8])
            let nested = try await client.echo(as: Box.Typed<CapnpText>.self) { try $0.initValue().setValue("deep") }
            try openCheck((try text.value()) == "named" && (try data.value()) == [7, 0, 8] && (try nested.value().value()) == "deep", "named payload brands bind arbitrary method arguments")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    static func swap() async throws {
        let pair = try await OpenPair(Swap.Typed.Export(OpenSwap()))
        do {
            let client = try Swap.Typed.Client(cap: pair.cap, connection: pair.client)
            let first = try await client.swap(as: CapnpText.self, as1: CapnpData.self) { try $0.setFirst("first"); try $0.setSecond([1, 2]) }
            let second = try await client.swap(as: CapnpData.self, as1: CapnpText.self) { try $0.setFirst([3, 4]); try $0.setSecond("second") }
            try openCheck((try first.first()) == [1, 2] && (try first.second()) == "first" && (try second.first()) == "second" && (try second.second()) == [3, 4], "multiple open method arguments preserve reversed result bindings")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    static func batch() async throws {
        let pair = try await OpenPair(Batch.Typed.Export(OpenBatch()))
        do {
            let client = try Batch.Typed.Client(cap: pair.cap, connection: pair.client)
            let text = try await client.gather(as: CapnpText.self) { let list = $0.initValues(2); try list[0].setValue("one"); try list[1].setValue("two") }
            let data = try await client.gather(as: CapnpData.self) { let list = $0.initValues(2); try list[0].setValue([1, 0]); try list[1].setValue([2, 0]) }
            let texts = try text.values(), datas = try data.values()
            try openCheck(texts.count == 2 && (try texts[0].value()) == "one" && (try texts[1].value()) == "two" && datas.count == 2 && (try datas[0].value()) == [1, 0] && (try datas[1].value()) == [2, 0], "declared Box lists preserve unknown generic element values")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    static func ancestry() async throws {
        let pair = try await OpenPair(IDiamond.Typed<CapnpText>.Export(OpenDiamond()))
        do {
            let client = try IDiamond.Typed<CapnpText>.Client(cap: pair.cap, connection: pair.client)
            let left = try await client.iLeft.iBase.echo { try $0.setValue("left") }
            let right = try await client.iRight.iBase.echo { try $0.setValue("right") }
            let own = try await client.local { try $0.setValue("local") }
            try openCheck((try left.value()) == "left" && (try right.value()) == "right" && (try own.value()) == "local", "equal branded diamonds share ancestor dispatch and witnesses")
        } catch { await pair.close(); throw error }
        await pair.close()
        let joined = try await OpenPair(IJoined.Typed<CapnpText>.Export(OpenJoined()))
        do {
            let client = try IJoined.Typed<CapnpText>.Client(cap: joined.cap, connection: joined.client)
            let first = try await client.iBase.echo { try $0.setValue("value") }
            let second = try await client.iOther.echo { try $0.setValue("value") }
            try openCheck((try first.value()) == "base:value" && (try second.value()) == "other:value", "same-name ancestor methods retain distinct wire identities")
        } catch { await joined.close(); throw error }
        await joined.close()
        let lexical = try await OpenPair(IOuter.Typed<CapnpText>.Inner.Export(OpenLexical()))
        do {
            let client = try IOuter.Typed<CapnpText>.Inner.Client(cap: lexical.cap, connection: lexical.client)
            let result = try await client.echo { try $0.setValue("outer") }
            try openCheck((try result.value()) == "outer", "nested interface payloads retain outer lexical bindings")
        } catch { await lexical.close(); throw error }
        await lexical.close()
    }

    static func capabilities() async throws {
        let pair = try await OpenPair(IFactory.Typed<CapnpText>.Export(OpenFactory()))
        do {
            let client = try IFactory.Typed<CapnpText>.Client(cap: pair.cap, connection: pair.client)
            let callback = ISink.Typed<CapnpText>.Client(server: OpenSink(prefix: "callback:"), connection: pair.client)
            let relayed = try await client.relay { try $0.setValue("called"); try $0.setCallback(callback) }
            try openCheck((try relayed.value()) == "callback:called", "typed generic callbacks invoke over the receiving connection")
            func make() async throws -> ISink.Typed<CapnpText>.Client {
                let result = try await client.make()
                guard let sink = try result.sink() else { throw OpenRPCFailure(name: "made capability was null") }
                return sink
            }
            let retained = try await make()
            let reply = try await retained.push { try $0.setValue("alive") }
            try openCheck((try reply.value()) == "made:alive", "typed imported result capabilities survive reader release")
            let nested = try await client.nested()
            guard let boxed = try nested.boxed().value(), let direct = try nested.direct() else { throw OpenRPCFailure(name: "nested capability was null") }
            let values = try nested.many()
            let first = try await boxed.push { try $0.setValue("box") }
            let second = try await direct.push { try $0.setValue("direct") }
            guard let list0 = try values[0].value(), let list1 = try values[1].value() else { throw OpenRPCFailure(name: "list capability was null") }
            let third = try await list0.push { try $0.setValue("list0") }, fourth = try await list1.push { try $0.setValue("list1") }
            try openCheck(values.count == 2 && (try first.value()) == "nested:box" && (try second.value()) == "nested:direct" && (try third.value()) == "nested:list0" && (try fourth.value()) == "nested:list1", "nested structs and struct lists share typed capability ownership")
            let foreignPair = try await OpenPair(Child.Typed.Export(OpenEcho()))
            let foreign = ISink.Typed<CapnpText>.Client(server: OpenSink(prefix: "foreign:"), connection: foreignPair.client)
            var rejected = false
            do { _ = try await client.relay { try $0.setValue("foreign"); try $0.setCallback(foreign) } }
            catch RPCError.foreignCapability { rejected = true }
            await foreignPair.close()
            try openCheck(rejected, "typed capability arguments reject foreign connection ownership")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    static func ordering() async throws {
        final class OrderSink: ISink.TypedServer, Sendable {
            typealias ISink_T_8511b2a1e9faa1ac_0 = CapnpText
            let values = Mutex<[String]>([])
            func push(params: ISink.Typed<CapnpText>.PushParams.Reader, on connection: isolated RPCConnection) async throws -> ISink.Typed<CapnpText>.PushResults.Value {
                let value = try params.value()
                values.withLock { $0.append(value) }
                try await Task.sleep(for: .milliseconds(10))
                return try .init { try $0.setValue(value) }
            }
        }
        let sink = OrderSink(), pair = try await OpenPair(ISink.Typed<CapnpText>.Export(sink))
        do {
            func bytes(_ value: String) throws -> [UInt8] {
                let params = try ISink.Typed<CapnpText>.PushParams.Value { try $0.setValue(value) }
                let message = MessageBuilder()
                try params.pointer.copy(to: PointerBuilder(message: message))
                return message.toBytes()
            }
            let first = try await pair.client.send(.cap(pair.cap), interface: ISink.Typed<CapnpText>.interfaceID, method: 0, params: bytes("one"))
            let second = try await pair.client.send(.cap(pair.cap), interface: ISink.Typed<CapnpText>.interfaceID, method: 0, params: bytes("two"))
            _ = try await first.result(); _ = try await second.result()
            try openCheck(sink.values.withLock { $0 } == ["one", "two"], "typed server witnesses preserve connection entry ordering")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    static func actorCaller() async throws {
        @MainActor final class UIState {
            var text = "main actor"
            func echo(_ client: TextParent.Client) async throws -> String {
                let result = try await client.echo(as: CapnpText.self) { builder in
                    MainActor.assertIsolated()
                    try builder.setValue(self.text)
                }
                return try result.value()
            }
        }
        let pair = try await OpenPair(Child.Typed.Export(OpenEcho()))
        do {
            let client = try Child.Typed.Client(cap: pair.cap, connection: pair.client).parent
            let ui = UIState()
            let value = try await ui.echo(client)
            try openCheck(value == "main actor", "typed request builders run on the caller actor")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    static func reservedViews() async throws {
        let pair = try await OpenPair(IReserved.Typed.Export(OpenReserved()))
        do {
            let client = try IReserved.Typed.Client(cap: pair.cap, connection: pair.client)
            let ping = try await client.connection2.ping()
            let pong = try await client.capability2.pong()
            try openCheck(client.connection === pair.client && client.capability.connection === pair.client && (try ping.value()) == "connection view" && (try pong.value()) == "capability view", "ancestor views preserve generated connection and capability members")
            let text = try await client.unused(as: CapnpText.self) { $0.setFixedText("unbound"); $0.setFixedData([7, 0, 9]) }
            let data = try await client.unused(as: CapnpData.self) { $0.setFixedText("unbound"); $0.setFixedData([7, 0, 9]) }
            try openCheck((try text.fixedText()) == "unbound" && (try data.fixedData()) == [7, 0, 9], "unused method arguments keep explicit generic calls without ambiguous conveniences")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { FileHandle.standardError.write(Data("OPEN_RPC_FAIL: watchdog expired\n".utf8)); exit(1) }
        do { try await inherited(); try await named(); try await swap(); try await batch(); try await ancestry(); try await capabilities(); try await ordering(); try await actorCaller(); try await reservedViews() }
        catch { FileHandle.standardError.write(Data("OPEN_RPC_FAIL: \(error)\n".utf8)); exit(1) }
    }
}
