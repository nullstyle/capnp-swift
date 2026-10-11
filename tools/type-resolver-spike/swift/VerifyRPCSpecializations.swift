import Capnp
import CapnpRPC
import Dispatch
import Foundation

private typealias Diamond = SpecializedRoot.TextDiamondCapability
private typealias TextBase = Diamond.Super0.Super0
private typealias DataBase = SpecializedRoot.DataBaseCapability
private typealias Joined = SpecializedRoot.CollisionCapability
private typealias Named = SpecializedRoot.NamedCapability
private typealias Lexical = SpecializedRoot.LexicalCapability
private typealias Factory = SpecializedRoot.FactoryCapability
private typealias Sink = Factory.RelayParams.CallbackCapability

private struct Failure: Error, CustomStringConvertible { let description: String }

// One Base(Text) method satisfies both arms of the branded diamond.
private struct DiamondServer: Diamond.Server {
    func echo(params: TextBase.EchoParams.Reader, on connection: RPCConnection) async throws -> TextBase.EchoResults.Value {
        let input = try params.value()
        return .init { $0.setValue("base:" + input) }
    }
    func left(params: Diamond.Super0.LeftParams.Reader, on connection: RPCConnection) async throws -> Diamond.Super0.LeftResults.Value {
        let input = try params.value()
        return .init { $0.setValue("left:" + input) }
    }
    func right(params: Diamond.Super1.RightParams.Reader, on connection: RPCConnection) async throws -> Diamond.Super1.RightResults.Value {
        let input = try params.value()
        return .init { $0.setValue("right:" + input) }
    }
    func local(params: Diamond.LocalParams.Reader, on connection: RPCConnection) async throws -> Diamond.LocalResults.Value {
        let input = try params.value()
        return .init { $0.setValue("local:" + input) }
    }
}

private struct DataServer: DataBase.Server {
    func echo(params: DataBase.EchoParams.Reader, on connection: RPCConnection) async throws -> DataBase.EchoResults.Value {
        let input: [UInt8] = try params.value()
        return .init { $0.setValue(input.reversed()) }
    }
}

// Identical method names from unrelated interfaces remain separate overloads.
private struct JoinedServer: Joined.Server {
    func echo(params: Joined.Super0.EchoParams.Reader, on connection: RPCConnection) async throws -> Joined.Super0.EchoResults.Value {
        let input = try params.value()
        return .init { $0.setValue("first:" + input) }
    }
    func echo(params: Joined.Super1.EchoParams.Reader, on connection: RPCConnection) async throws -> Joined.Super1.EchoResults.Value {
        let input = try params.value()
        return .init { $0.setValue("second:" + input) }
    }
}

private struct NamedServer: Named.Server {
    func echo(params: Named.EchoParams.Reader, on connection: RPCConnection) async throws -> Named.EchoResults.Value {
        let input: String = try params.value()
        return .init { $0.setValue("named:" + input) }
    }
}

private struct LexicalServer: Lexical.Server {
    func echo(params: Lexical.EchoParams.Reader, on connection: RPCConnection) async throws -> Lexical.EchoResults.Value {
        let input: String = try params.value()
        return .init { $0.setValue("outer:" + input) }
    }
}

private struct SinkServer: Sink.Server {
    let prefix: String
    func push(params: Sink.PushParams.Reader, on connection: RPCConnection) async throws -> Sink.PushResults.Value {
        let input = try params.value()
        return .init { $0.setValue(prefix + input) }
    }
}

private struct FactoryServer: Factory.Server {
    func relay(params: Factory.RelayParams.Reader, on connection: RPCConnection) async throws -> Factory.RelayResults.Value {
        guard let callback = try params.callback(on: connection) else { throw Failure(description: "missing callback") }
        let input = try params.value()
        let result = try await callback.push { $0.setValue(input) }
        let output = try result.value()
        return .init { $0.setValue(output) }
    }
    func make(params: Factory.MakeParams.Reader, on connection: RPCConnection) async throws -> Factory.MakeResults.Value {
        .init { $0.setSink(SinkServer(prefix: "returned:")) }
    }
    func nested(params: Factory.NestedParams.Reader, on connection: RPCConnection) async throws -> Factory.NestedResults.Value {
        .init {
            $0.initBoxed().setValue(SinkServer(prefix: "boxed:"))
            $0.setDirect(SinkServer(prefix: "direct:"))
            let many = $0.initMany(2)
            many[0].setValue(SinkServer(prefix: "list0:"))
            many[1].setValue(SinkServer(prefix: "list1:"))
        }
    }
}

@main
struct VerifyRPCSpecializations {
    static func check(_ condition: Bool, _ name: String) throws {
        if !condition { throw Failure(description: name) }
        print("PASS: \(name)")
    }

    static func connected(_ export: any ExportHandler) async throws -> (RPCConnection, RPCConnection, CapRef) {
        let (a, b) = LoopbackTransport.pair()
        var options = RPCConnection.Options()
        options.callTimeout = .seconds(5)
        options.tickInterval = .milliseconds(20)
        let server = try await RPCConnection.connect(transport: a, bootstrap: export, options: options)
        let client = try await RPCConnection.connect(transport: b, options: options)
        do { return (server, client, try await client.bootstrap()) }
        catch { await client.close(); await server.close(); throw error }
    }

    static func disconnected(_ server: RPCConnection, _ client: RPCConnection) async {
        await client.close()
        await server.close()
        _ = await client.waitClosed()
        _ = await server.waitClosed()
    }

    static func diamond() async throws {
        let (server, connection, cap) = try await connected(Diamond.Export(DiamondServer()))
        let client = Diamond.Client(cap: cap, connection: connection)
        do {
            let local = try await client.local { $0.setValue("L") }
            let left = try await client.super0.left { $0.setValue("A") }
            let right = try await client.super1.right { $0.setValue("B") }
            let baseLeft = try await client.super0.super0.echo { $0.setValue("C") }
            let baseRight = try await client.super1.super0.echo { $0.setValue("D") }
            try check((try local.value()) == "local:L" && (try left.value()) == "left:A" && (try right.value()) == "right:B" && (try baseLeft.value()) == "base:C" && (try baseRight.value()) == "base:D", "branded diamond dispatch and shared ancestor")
            for (interface, method, name) in [(Diamond.interfaceID, UInt16(99), "unknown method dispatch"), (UInt64(1), UInt16(0), "unknown interface dispatch")] {
                var rejected = false
                do { _ = try await connection.call(.cap(cap), interface: interface, method: method, params: MessageBuilder.emptyStruct()) }
                catch RPCError.unimplemented { rejected = true }
                try check(rejected, name)
            }
        } catch { await disconnected(server, connection); throw error }
        await disconnected(server, connection)
    }

    static func data() async throws {
        let (server, connection, cap) = try await connected(DataBase.Export(DataServer()))
        do {
            let result = try await DataBase.Client(cap: cap, connection: connection).echo { $0.setValue([0, 1, 255]) }
            let output: [UInt8] = try result.value()
            try check(output == [255, 1, 0] && DataBase.interfaceID == TextBase.interfaceID, "Text and Data applications keep distinct RPC payload types")
        } catch { await disconnected(server, connection); throw error }
        await disconnected(server, connection)
    }

    static func collision() async throws {
        let (server, connection, cap) = try await connected(Joined.Export(JoinedServer()))
        let client = Joined.Client(cap: cap, connection: connection)
        do {
            let first = try await client.super0.echo { $0.setValue("x") }
            let second = try await client.super1.echo { $0.setValue("x") }
            try check((try first.value()) == "first:x" && (try second.value()) == "second:x", "inherited method names dispatch by interface ID")
        } catch { await disconnected(server, connection); throw error }
        await disconnected(server, connection)
    }

    static func named() async throws {
        let (server, connection, cap) = try await connected(Named.Export(NamedServer()))
        do {
            let result = try await Named.Client(cap: cap, connection: connection).echo { $0.setValue("box") }
            try check((try result.value()) == "named:box", "named generic RPC payloads")
        } catch { await disconnected(server, connection); throw error }
        await disconnected(server, connection)
    }

    static func lexical() async throws {
        let (server, connection, cap) = try await connected(Lexical.Export(LexicalServer()))
        do {
            let result = try await Lexical.Client(cap: cap, connection: connection).echo { $0.setValue("scope") }
            try check((try result.value()) == "outer:scope", "nested interface substitutes its enclosing generic scope")
        } catch { await disconnected(server, connection); throw error }
        await disconnected(server, connection)
    }

    // Return only the typed capability. The temporary result reader and its
    // table have left scope before the next call; the client must retain it.
    private static func returned(_ factory: Factory.Client) async throws -> Sink.Client {
        guard let sink = try await factory.make().sink(on: factory.connection) else { throw Failure(description: "missing returned sink") }
        return sink
    }

    static func capabilities() async throws {
        let (server, connection, cap) = try await connected(Factory.Export(FactoryServer()))
        let factory = Factory.Client(cap: cap, connection: connection)
        do {
            let callbackResult = try await factory.relay { $0.setValue("hello"); $0.setCallback(SinkServer(prefix: "callback:")) }
            try check((try callbackResult.value()) == "callback:hello", "concrete generic callback roundtrip")
            let sink = try await returned(factory)
            let made = try await sink.push { $0.setValue("alive") }
            try check((try made.value()) == "returned:alive", "returned capability survives its result reader")
            let nested = try await factory.nested()
            guard let boxed = try nested.boxed().value(on: connection), let direct = try nested.direct(on: connection) else { throw Failure(description: "missing nested capability") }
            let boxResult = try await boxed.push { $0.setValue("one") }
            let directResult = try await direct.push { $0.setValue("two") }
            try check((try boxResult.value()) == "boxed:one" && (try directResult.value()) == "direct:two", "nested builders and readers share one capability table")
            guard let many = try nested.many(), many.count == 2,
                  let first = try many[0].value(on: connection),
                  let second = try many[1].value(on: connection) else { throw Failure(description: "missing list capabilities") }
            let firstResult = try await first.push { $0.setValue("a") }
            let secondResult = try await second.push { $0.setValue("b") }
            try check((try firstResult.value()) == "list0:a" && (try secondResult.value()) == "list1:b", "struct-list elements preserve the payload capability table")
            // A second connection exposes the runtime's foreign-capability
            // check through the typed client setter.
            let (otherServer, otherConnection, otherCap) = try await connected(Factory.Export(FactoryServer()))
            var foreignRejected = false
            do {
                _ = try await Factory.Client(cap: otherCap, connection: otherConnection).relay { $0.setValue("foreign"); $0.setCallback(sink) }
            } catch RPCError.foreignCapability { foreignRejected = true }
            await disconnected(otherServer, otherConnection)
            try check(foreignRejected, "typed capability setter preserves connection ownership")
        } catch { await disconnected(server, connection); throw error }
        await disconnected(server, connection)
    }

    static func main() async {
        // Independent watchdog also bounds bootstrap/close if the runtime
        // regresses before the per-call timeout starts.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("FAIL: RPC specialization watchdog expired\n".utf8))
            exit(1)
        }
        do {
            try await diamond()
            try await data()
            try await collision()
            try await named()
            try await lexical()
            try await capabilities()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
