@_spi(Generated) import Capnp
import CapnpRPC
import Foundation

private func require(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    do { let valid = try condition(); precondition(valid, "EMPTY_COMPOSITE_FAIL: \(name)") }
    catch { fatalError("EMPTY_COMPOSITE_FAIL: \(name): \(error)") }
    print("PASS: \(name)")
}

private struct EmptyEcho: ExportHandler {
    func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
        let reader = EmptyContainer.Reader(try Message(bytes: call.params).rootStruct())
        require(try reader.items()?.count == 0 && reader.zeros()?.count == 0, "released core inbound preserves both empty composite layouts")
        return CallResponse(message: call.params)
    }
}

@main struct VerifyEmptyComposite {
    static func main() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("empty_composite.cpp.bin")
        let cpp = Array(try Data(contentsOf: fixture))
        let cppReader = EmptyContainer.Reader(try Message(bytes: cpp).rootStruct())
        require(try cppReader.items()?.count == 0 && cppReader.zeros()?.count == 0, "independent C++ bytes encode nonnull empty composite lists")

        let legacy = MessageBuilder()
        let legacyBuilder = EmptyContainer.Builder(legacy.initRoot(dataWords: 0, pointerWords: 2))
        _ = legacyBuilder.initItems(0)
        _ = legacyBuilder.initZeros(0)
        let legacyReader = EmptyContainer.Reader(try Message(bytes: legacy.toBytes()).rootStruct())
        require(try legacyReader.items()?.count == 0 && legacyReader.zeros()?.count == 0, "legacy empty composite initializers override schema defaults")
        require(legacy.toBytes() == cpp, "Swift empty composite encoding matches independent C++ bytes")

        let typed = try EmptyContainer.Typed.Value { builder in
            try builder.setItems([])
            try builder.setZeros([])
        }
        require(try EmptyContainer.Typed.read(from: typed.pointer).items().isEmpty && EmptyContainer.Typed.read(from: typed.pointer).zeros().isEmpty, "typed empty composite setters override schema defaults")
        let initialized = try EmptyContainer.Typed.Value { builder in
            _ = builder.initItems(0)
            _ = builder.initZeros(0)
        }
        require(try EmptyContainer.Typed.read(from: initialized.pointer).items().isEmpty && EmptyContainer.Typed.read(from: initialized.pointer).zeros().isEmpty, "typed empty composite initializers override schema defaults")
        let source = try EmptyContainer.Typed.read(from: Message(bytes: cpp).rootPointer())
        let copied = try EmptyContainer.Typed.Value(copying: source)
        require(try EmptyContainer.Typed.read(from: copied.pointer).items().isEmpty && EmptyContainer.Typed.read(from: copied.pointer).zeros().isEmpty, "owned pointer copying preserves nonnull empty composites")

        let encoded = try typed.pointer.serialized()
        try Data(legacy.toBytes()).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        let (a, b) = LoopbackTransport.pair()
        let server = try await RPCConnection.connect(transport: b, bootstrap: EmptyEcho())
        let client = try await RPCConnection.connect(transport: a)
        let capability = try await client.bootstrap()
        for params in [cpp, legacy.toBytes(), encoded.bytes] {
            let response = try await client.call(capability, interface: 0xe8a44ab80848d92a, method: 0, params: params)
            let reader = EmptyContainer.Reader(try Message(bytes: response.message).rootStruct())
            require(try reader.items()?.count == 0 && reader.zeros()?.count == 0, "released core return preserves both empty composite layouts")
        }
        await client.close()
        await server.close()
    }
}
