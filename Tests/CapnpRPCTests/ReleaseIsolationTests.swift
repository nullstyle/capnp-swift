// A handler that awaits a nonisolated async function that throws: the
// shape of every generated server, whose `handle` awaits a server method.
// In a Release build of 0.1.3 the error resumed the inbound call's task off
// the connection's queue (it left TaskLocal.withValue), so `complete` ran
// off the actor and its next isolation check trapped (SIGTRAP). A Debug
// build hides it: run these tests in Release with `just release-test`.

import Capnp
@testable import CapnpRPC
import Testing

private func emptyStruct() -> [UInt8] {
    let mb = MessageBuilder()
    _ = mb.initRoot(dataWords: 0, pointerWords: 0)
    return mb.toBytes()
}

protocol ThrowingServer: Sendable {
    func fail() async throws -> UInt64
}

struct AlwaysThrows: ThrowingServer {
    func fail() async throws -> UInt64 { throw RPCError.failed(reason: "deliberate") }
}

/// As a generated server: the server is an existential.
struct ExistentialExport: ExportHandler {
    let server: any ThrowingServer
    func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
        _ = try await server.fail()
        return CallResponse(message: emptyStruct())
    }
}

struct ConcreteExport: ExportHandler {
    let server: AlwaysThrows
    func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
        _ = try await server.fail()
        return CallResponse(message: emptyStruct())
    }
}

nonisolated func throwingFunction() async throws -> UInt64 { throw RPCError.failed(reason: "deliberate") }

struct FunctionExport: ExportHandler {
    func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
        _ = try await throwingFunction()
        return CallResponse(message: emptyStruct())
    }
}

@Suite("Release isolation")
struct ReleaseIsolationTests {
    @Test("a generated-style handler whose server method throws answers with its exception")
    func existentialServer() async throws { try await run(ExistentialExport(server: AlwaysThrows())) }

    @Test("the same with a concrete server type")
    func concreteServer() async throws { try await run(ConcreteExport(server: AlwaysThrows())) }

    @Test("the same with a nonisolated function")
    func nonisolatedFunction() async throws { try await run(FunctionExport()) }

    private func run(_ export: any ExportHandler) async throws {
        let (client, server, cap) = try await connectedPair(bootstrap: export)
        for _ in 0..<20 {
            await #expect(throws: RPCError.self) {
                _ = try await client.call(.cap(cap), interface: 1, method: 0, params: emptyStruct())
            }
        }
        #expect(await server.closeCause == nil)
        await client.close()
        _ = await server.waitClosed()
    }
}
