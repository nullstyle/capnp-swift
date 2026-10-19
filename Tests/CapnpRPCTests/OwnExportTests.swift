// One of our own capabilities comes back to us (`CapTableEntry.exported`)
// and the remote then releases its reference. The export id leaves the
// connection's table at EXPORT_DROPPED, so a later lookup by id found
// nothing. These tests pin the handler that was captured when the RETURN or
// the call arrived (M9 G1).
//
//   Keeper.make() -> (echo :Echo)          an Echo export that adds 300
//   Keeper.useLater(echo :Echo) -> (n)     waits until the caller released
//                                          echo, then calls it locally
//   Bouncer.bounce(cap :Echo) -> (cap)     returns the capability it got

import Capnp
@testable import CapnpRPC
import Testing

/// An Echo that adds its tag, so a test can tell two handlers apart.
struct TaggedEcho: Echo.Server {
    let tag: UInt64
    func echo(_ n: UInt64) async throws -> UInt64 { n + tag }
}

/// Call an Echo handler in this process (a capability of ours came back).
func localEcho(_ handler: any ExportHandler, _ n: UInt64, on connection: isolated RPCConnection) async throws -> UInt64 {
    let mb = MessageBuilder()
    mb.initRoot(dataWords: 1, pointerWords: 0).setUInt64(at: 0, n)
    let call = InboundCall(interfaceID: Echo.interfaceID, methodID: 0, params: mb.toBytes(), caps: [], connection: connection)
    return try Message(bytes: try await handler.handle(call, on: connection).message).rootStruct().readUInt64(at: 0)
}

func capParams() -> [UInt8] {
    let mb = MessageBuilder()
    mb.initRoot(dataWords: 0, pointerWords: 1).setCapability(0, capIndex: 0)
    return mb.toBytes()
}

enum Keeper {
    static let interfaceID: UInt64 = 0x6b33_0000_0000_0001

    /// How `useLater` finds the handler of the Echo that came back.
    enum Lookup: Sendable {
        /// `RPCConnection.localHandler(forExport:)`, as a generated (legacy)
        /// server does: it gets only the cap table, not the InboundCall.
        case connection
        /// `InboundCall.localHandler(forExport:)`.
        case call
    }

    struct Export: ExportHandler {
        let lookup: Lookup

        func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
            guard call.interfaceID == Keeper.interfaceID else { throw RPCError.unimplemented(reason: "Keeper") }
            switch call.methodID {
            case 0:
                let mb = MessageBuilder()
                mb.initRoot(dataWords: 0, pointerWords: 1).setCapability(0, capIndex: 0)
                return CallResponse(message: mb.toBytes(), caps: [.export(Echo.Export(server: TaggedEcho(tag: 300)))])
            case 1:
                let params = try Message(bytes: call.params).rootStruct()
                guard let idx = try params.readCapabilityIndex(0), case .exported(let id) = call.caps[Int(idx)] else {
                    throw RPCError.failed(reason: "useLater: not our own export")
                }
                // Wait for the caller's Release: EXPORT_DROPPED removes the id.
                let deadline = ContinuousClock.now + .seconds(5)
                while connection.pointerHasLiveExport(id) {
                    guard ContinuousClock.now < deadline else { throw RPCError.failed(reason: "useLater: the export was never released") }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let found: (any ExportHandler)?
                switch lookup {
                case .connection: found = connection.localHandler(forExport: id)
                case .call: found = call.localHandler(forExport: id)
                }
                guard let handler = found else { throw RPCError.failed(reason: "useLater: no handler after the release") }
                let n = try await localEcho(handler, 7, on: connection)
                let mb = MessageBuilder()
                mb.initRoot(dataWords: 1, pointerWords: 0).setUInt64(at: 0, n)
                return CallResponse(message: mb.toBytes())
            default:
                throw RPCError.unimplemented(reason: "Keeper")
            }
        }
    }
}

enum Bouncer {
    static let interfaceID: UInt64 = 0xb0b0_0000_0000_0001

    struct Export: ExportHandler {
        func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
            guard call.interfaceID == Bouncer.interfaceID, call.methodID == 0 else { throw RPCError.unimplemented(reason: "Bouncer") }
            let params = try Message(bytes: call.params).rootStruct()
            guard let idx = try params.readCapabilityIndex(0), case .imported(let ref) = call.caps[Int(idx)] else {
                throw RPCError.failed(reason: "bounce: no imported capability")
            }
            return CallResponse(message: capParams(), caps: [.imported(ref)])
        }
    }
}

@Suite("Own exports")
struct OwnExportTests {
    /// Send useLater with the Keeper's own Echo, then let the client's import
    /// go: nothing but the call holds it, so the client releases it.
    private func sendUseLater(_ client: RPCConnection, _ keeper: CapRef) async throws -> RemotePromise {
        let made = try await client.call(.cap(keeper), interface: Keeper.interfaceID, method: 0, params: MessageBuilder.emptyStruct())
        guard case .imported(let echo) = made.caps[0] else { throw RPCError.failed(reason: "make: no Echo") }
        return try await client.send(.cap(keeper), interface: Keeper.interfaceID, method: 1, params: capParams(), caps: [.imported(echo)])
    }

    @Test("a handler can call its own export from the params after the caller released it",
          arguments: [Keeper.Lookup.connection, .call])
    func ownExportInParams(_ lookup: Keeper.Lookup) async throws {
        let (client, server, keeper) = try await connectedPair(bootstrap: Keeper.Export(lookup: lookup))
        let promise = try await sendUseLater(client, keeper)
        let result = try await withTimeout(.seconds(10)) { try await promise.result() }
        #expect(try Message(bytes: result.message).rootStruct().readUInt64(at: 0) == 307)
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("a result keeps its own exports callable after the remote released them")
    func ownExportInResults() async throws {
        let (client, server, bouncer) = try await connectedPair(bootstrap: Bouncer.Export())
        var ids: [UInt32] = []
        var results: [CallResult] = []
        for tag in [UInt64(100), 200] {
            let result = try await client.call(.cap(bouncer), interface: Bouncer.interfaceID, method: 0,
                                               params: capParams(), caps: [.export(Echo.Export(server: TaggedEcho(tag: tag)))])
            guard case .exported(let id) = result.caps[0] else {
                Issue.record("bounce did not return our own export: \(result.caps)")
                return
            }
            // The Bouncer's import goes when its call ends: wait for the drop.
            let deadline = ContinuousClock.now + .seconds(5)
            while await client.pointerHasLiveExport(id) {
                guard ContinuousClock.now < deadline else {
                    Issue.record("export \(id) was never released")
                    return
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await client.localHandler(forExport: id) == nil)
            ids.append(id)
            results.append(result)
        }
        for (result, (id, expected)) in zip(results, zip(ids, [UInt64(101), 201])) {
            guard let handler = result.localHandler(forExport: id) else {
                Issue.record("result lost its own export \(id)")
                continue
            }
            #expect(try await localEcho(handler, 1, on: client) == expected)
        }
        await client.close()
        _ = await server.waitClosed()
    }
}
