@_spi(Generated) import Capnp
@_spi(Generated) @testable import CapnpRPC
import Testing
import Synchronization

private let pointerTestInterface: UInt64 = 0xdf88_2201_7773_6021

private func pointerText(_ text: String) -> [UInt8] {
    let message = MessageBuilder()
    message.initRoot(dataWords: 0, pointerWords: 1).setText(0, text)
    return message.toBytes()
}

private func pointerToken(_ cap: RPCPointerCapability) throws -> PointerCapability {
    let builder = PointerBuilder()
    try cap.write(to: builder)
    return try #require(builder.capabilities.first)
}

private func pointerParams(_ caps: [RPCPointerCapability] = []) throws -> PointerReader {
    let message = MessageBuilder()
    let root = message.initRoot(dataWords: 0, pointerWords: UInt16(caps.count + 1))
    root.setText(0, "params")
    for index in caps.indices { root.setCapability(index + 1, capIndex: UInt32(index)) }
    return try PointerReader(bytes: message.toBytes(), capabilities: caps.map(pointerToken))
}

private struct PointerTextHandler: ExportHandler {
    let text: String
    func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
        guard call.interfaceID == pointerTestInterface, call.methodID == 0 else {
            throw RPCError.unimplemented(reason: "unknown pointer method")
        }
        return CallResponse(message: pointerText(text))
    }
}

private struct PointerFactoryHandler: ExportHandler {
    func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
        guard call.interfaceID == pointerTestInterface else {
            throw RPCError.unimplemented(reason: "unknown pointer interface")
        }
        switch call.methodID {
        case 0:
            let params = try connection.pointerPayload(call: call)
            return CallResponse(message: call.params, caps: try connection.pointerSlots(params.capabilities))
        case 1:
            let message = MessageBuilder()
            message.initRoot(dataWords: 0, pointerWords: 2).setCapability(1, capIndex: 0)
            return CallResponse(message: message.toBytes(), caps: [.export(PointerTextHandler(text: "remote"))])
        default:
            throw RPCError.unimplemented(reason: "unknown pointer method")
        }
    }
}

private struct PointerPair {
    let client: RPCConnection
    let server: RPCConnection
    let bootstrap: RPCPointerCapability

    init() async throws {
        var options = RPCConnection.Options()
        options.callTimeout = .seconds(5)
        let (a, b) = LoopbackTransport.pair()
        server = try await RPCConnection.connect(transport: b, bootstrap: PointerFactoryHandler(), options: options)
        client = try await RPCConnection.connect(transport: a, options: options)
        bootstrap = try RPCPointerCapability(cap: try await client.bootstrap(), connection: client)
    }

    func close() async {
        await client.close()
        _ = await server.waitClosed()
    }

    func imported() async throws -> RPCPointerCapability {
        let result = try await bootstrap.call(interface: pointerTestInterface, method: 1, params: pointerParams())
        return try RPCPointerCapability(result.field(1))
    }
}

@Suite("Pointer capability adapters")
struct PointerCapabilityTests {
    @Test("imported projection retains capability after its result reader is gone")
    func importedLifetime() async throws {
        let pair = try await PointerPair()
        do {
            let imported = try await pair.imported()
            let reply = try await imported.call(interface: pointerTestInterface, method: 0, params: pointerParams())
            #expect(try reply.readStruct().readText(0) == "remote")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    @Test("a local capability returned through loopback remains callable")
    func returnedLocal() async throws {
        let pair = try await PointerPair()
        do {
            let callback = RPCPointerCapability(server: PointerTextHandler(text: "callback"), connection: pair.client)
            func returned() async throws -> RPCPointerCapability {
                let result = try await pair.bootstrap.call(interface: pointerTestInterface, method: 0, params: pointerParams([callback]))
                return try RPCPointerCapability(result.field(1))
            }
            for _ in 0..<32 {
                let local = try await returned()
                let reply = try await local.call(interface: pointerTestInterface, method: 0, params: pointerParams())
                #expect(try reply.readStruct().readText(0) == "callback")
                #expect(await pair.client.pointerLocalAliasCount == 0)
            }
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    @Test("returned capability snapshots survive wire-export release")
    func returnedSnapshotLifetime() async throws {
        let pair = try await PointerPair()
        do {
            func released() async throws -> RPCPointerCapability {
                let params = try pointerParams([RPCPointerCapability(server: PointerTextHandler(text: "snapshot"), connection: pair.client)])
                let payload = try params.serialized()
                let raw = try await pair.client.call(try await pair.client.bootstrap(), interface: pointerTestInterface, method: 0,
                                                     params: payload.bytes, caps: pair.client.pointerSlots(payload.capabilities))
                let capIndex = try Message(bytes: raw.message).rootStruct().readCapabilityIndex(1)
                let index = try #require(capIndex)
                let entry = try #require(raw.caps.indices.contains(Int(index)) ? raw.caps[Int(index)] : nil)
                guard case .exported(let id) = entry else {
                    throw RPCError.failed(reason: "returned pointer did not come home")
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while await pair.client.localHandler(forExport: id) != nil {
                    guard ContinuousClock.now < deadline else { throw RPCError.failed(reason: "wire export was not released") }
                    try await Task.sleep(for: .milliseconds(1))
                }
                let reader = try await pair.client.pointerPayload(result: raw)
                let copy = PointerBuilder()
                try reader.field(1).copy(to: copy)
                return try RPCPointerCapability(copy.freeze())
            }
            let retained = try await released()
            let response = try await retained.call(interface: pointerTestInterface, method: 0, params: pointerParams())
            #expect(try response.readStruct().readText(0) == "snapshot")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    @Test("copying mixed imported and local pointer sources remaps and deduplicates slots")
    func mixedCopies() async throws {
        let pair = try await PointerPair()
        do {
            let imported = try await pair.imported()
            let local = RPCPointerCapability(server: PointerTextHandler(text: "local"), connection: pair.client)
            let first = try pointerParams([imported]), second = try pointerParams([local])
            let message = MessageBuilder()
            let root = message.initRoot(dataWords: 0, pointerWords: 3)
            let builder = PointerBuilder(message: message)
            try first.field(1).copy(to: builder.field(root, index: 0))
            try second.field(1).copy(to: builder.field(root, index: 1))
            try first.field(1).copy(to: builder.field(root, index: 2))
            let combined = try builder.freeze()
            #expect(combined.capabilities.count == 2)
            #expect(try combined.readStruct().readCapabilityIndex(0) == 0)
            #expect(try combined.readStruct().readCapabilityIndex(1) == 1)
            #expect(try combined.readStruct().readCapabilityIndex(2) == 0)
            let remoteReply = try await RPCPointerCapability(combined.field(0)).call(interface: pointerTestInterface, method: 0, params: pointerParams())
            let localReply = try await RPCPointerCapability(combined.field(1)).call(interface: pointerTestInterface, method: 0, params: pointerParams())
            #expect(try remoteReply.readStruct().readText(0) == "remote")
            #expect(try localReply.readStruct().readText(0) == "local")
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    @Test("foreign connection pointer tokens fail before local dispatch")
    func foreignTokens() async throws {
        let first = try await PointerPair(), second = try await PointerPair()
        do {
            let imported = try await first.imported()
            let payload = try pointerParams([imported])
            #expect(throws: RPCError.foreignCapability) { try second.client.pointerSlots(payload.capabilities) }
            let local = RPCPointerCapability(server: PointerFactoryHandler(), connection: second.client)
            await #expect(throws: RPCError.foreignCapability) {
                _ = try await local.call(interface: pointerTestInterface, method: 0, params: payload)
            }
            #expect(await second.client.pointerLocalAliasCount == 0)
        } catch { await first.close(); await second.close(); throw error }
        await first.close()
        await second.close()
    }

    @Test("received local-handler snapshots keep their connection ownership")
    func foreignSnapshots() async throws {
        let first = try await PointerPair(), second = try await PointerPair()
        do {
            let params = try pointerParams([RPCPointerCapability(server: PointerTextHandler(text: "owned"), connection: first.client)])
            let payload = try params.serialized()
            let result = try await first.client.call(try await first.client.bootstrap(), interface: pointerTestInterface, method: 0,
                                                     params: payload.bytes, caps: first.client.pointerSlots(payload.capabilities))
            await #expect(throws: RPCError.foreignCapability) {
                _ = try await second.client.pointerPayload(result: result)
            }
            let call = InboundCall(interfaceID: pointerTestInterface, methodID: 0, params: pointerText("call"), caps: [], connection: first.client)
            await #expect(throws: RPCError.foreignCapability) {
                _ = try await second.client.pointerPayload(call: call)
            }
        } catch { await first.close(); await second.close(); throw error }
        await first.close()
        await second.close()
    }

    @Test("local argument aliases are scoped and returned handlers outlive them")
    func scopedLocalAliases() async throws {
        let pair = try await PointerPair()
        do {
            let local = RPCPointerCapability(server: PointerFactoryHandler(), connection: pair.client)
            let argument = RPCPointerCapability(server: PointerTextHandler(text: "retained"), connection: pair.client)
            for _ in 0..<32 {
                let result = try await local.call(interface: pointerTestInterface, method: 0, params: pointerParams([argument]))
                let retained = try RPCPointerCapability(result.field(1))
                #expect(await pair.client.pointerLocalAliasCount == 0)
                let reply = try await retained.call(interface: pointerTestInterface, method: 0, params: pointerParams())
                #expect(try reply.readStruct().readText(0) == "retained")
            }
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    @Test("retained local arguments keep their handler when scoped alias IDs are reused")
    func retainedAliasIdentity() async throws {
        final class Capture: ExportHandler, Sendable {
            private let retained = Mutex<PointerReader?>(nil)
            var pointer: PointerReader? { retained.withLock { $0 } }
            func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
                let pointer = try connection.pointerPayload(call: call).field(1)
                retained.withLock { $0 = pointer }
                return CallResponse(message: pointerText("captured"))
            }
        }
        struct SelectSecond: ExportHandler {
            func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
                let params = try connection.pointerPayload(call: call)
                let selected = try RPCPointerCapability(params.field(2))
                let result = try await selected.call(interface: pointerTestInterface, method: 0, params: pointerParams())
                let payload = try result.serialized()
                return CallResponse(message: payload.bytes, caps: try connection.pointerSlots(payload.capabilities))
            }
        }
        let pair = try await PointerPair()
        do {
            let capture = Capture()
            let first = RPCPointerCapability(server: PointerTextHandler(text: "A"), connection: pair.client)
            let captureTarget = RPCPointerCapability(server: capture, connection: pair.client)
            _ = try await captureTarget.call(interface: pointerTestInterface, method: 0, params: pointerParams([first]))
            let retained = try RPCPointerCapability(#require(capture.pointer))
            let second = RPCPointerCapability(server: PointerTextHandler(text: "B"), connection: pair.client)
            let select = RPCPointerCapability(server: SelectSecond(), connection: pair.client)
            let result = try await select.call(interface: pointerTestInterface, method: 0, params: pointerParams([second, retained]))
            let actual = try result.readStruct().readText(0)
            #expect(actual == "A")
            #expect(await pair.client.pointerLocalAliasCount == 0)
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    @Test("local argument aliases clean up after errors and cancellation")
    func localAliasCleanup() async throws {
        struct Fails: ExportHandler {
            func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
                throw RPCError.failed(reason: "local error")
            }
        }
        struct Suspends: ExportHandler {
            let entered: AsyncStream<Void>.Continuation
            func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
                entered.yield(())
                try await Task.sleep(for: .seconds(60))
                return CallResponse(message: pointerText("late"))
            }
        }
        let pair = try await PointerPair()
        do {
            let argument = RPCPointerCapability(server: PointerTextHandler(text: "argument"), connection: pair.client)
            let payload = try pointerParams([argument])
            let fails = RPCPointerCapability(server: Fails(), connection: pair.client)
            await #expect(throws: RPCError.failed(reason: "local error")) {
                _ = try await fails.call(interface: pointerTestInterface, method: 0, params: payload)
            }
            #expect(await pair.client.pointerLocalAliasCount == 0)
            let (stream, entered) = AsyncStream<Void>.makeStream()
            let suspends = RPCPointerCapability(server: Suspends(entered: entered), connection: pair.client)
            let task = Task { try await suspends.call(interface: pointerTestInterface, method: 0, params: payload) }
            for await _ in stream { break }
            #expect(await pair.client.pointerLocalAliasCount == 1)
            task.cancel()
            await #expect(throws: RPCError.canceled) { _ = try await task.value }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while await pair.client.pointerLocalAliasCount != 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await pair.client.pointerLocalAliasCount == 0)
        } catch { await pair.close(); throw error }
        await pair.close()
    }

    @Test("null unknown and missing local pointer capabilities fail explicitly")
    func invalidCapabilities() async throws {
        let pair = try await PointerPair()
        do {
            #expect(throws: RPCError.unimplemented(reason: "null pointer capability")) {
                _ = try RPCPointerCapability(PointerBuilder().freeze())
            }
            let builder = PointerBuilder()
            try builder.setCapability(PointerCapability("unrecognized"))
            #expect(throws: RPCError.malformed("unknown pointer capability adapter")) {
                _ = try RPCPointerCapability(builder.freeze())
            }
            await #expect(throws: RPCError.unimplemented(reason: "unknown local pointer capability")) {
                _ = try await pair.client.pointerPayload(bytes: pointerText("x"), caps: [.exported(UInt32.max)])
            }
        } catch { await pair.close(); throw error }
        await pair.close()
    }
}
