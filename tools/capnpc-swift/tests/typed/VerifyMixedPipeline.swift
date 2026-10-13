@_spi(Generated) import Capnp
@_spi(Generated) import CapnpRPC
import PipelineProducer
import Foundation
import Dispatch

struct MixedPipelineFailure: Error { let name: String }
func mixedCheck(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { throw MixedPipelineFailure(name: name) }
    print("PASS: \(name)")
}

struct MixedEcho: PConsumer.TypedServer {
    func echo(params: PConsumer.Typed.EchoParams<CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws -> PConsumer.Typed.EchoResults<CapnpAnyPointer>.Value {
        let value = try params.value()
        return try .init { try $0.setValue(.init(copying: value)) }
    }
    func named(params: PForeign.Typed<CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws -> PForeign.Typed<CapnpAnyPointer>.Value { try .init(copying: params) }
}
struct MixedSink: PBridgeSink.TypedServer {
    func echo(params: PBridgeSink.Typed.EchoParams.Reader, on connection: isolated RPCConnection) async throws -> PBridgeSink.Typed.EchoResults.Value { try .init { $0.setValue("mixed:" + (try params.value())) } }
}
@main enum VerifyMixedPipeline {
    static func run() async throws {
        let (a,b) = LoopbackTransport.pair()
        let server = try await RPCConnection.connect(transport: b, bootstrap: PConsumer.Typed.Export(MixedEcho()))
        let connection = try await RPCConnection.connect(transport: a)
        let client = try PConsumer.Typed.Client(cap: await connection.bootstrap(), connection: connection)
        do {
            let callback = PBridgeSink.Typed.Client(server: MixedSink(), connection: connection)
            let call = try await client.sendEcho(as: PBridgeSink.Typed.self) { try $0.initValue().setValue(callback) }
            let reader = try await call.pipeline.value.value()
            guard let sink = try reader.value() else { throw RPCError.failed(reason: "mixed pipeline lost capability") }
            let reply = try await sink.echo { $0.setValue("fallback") }
            try mixedCheck((try reply.value()) == "mixed:fallback", "Capnp-only producers remain usable through awaited RPC projections")
            let named = try await client.sendNamed(as: PBridgeSink.Typed.self) { try $0.setValue(callback) }
            let namedReader = try await named.pipeline.value()
            guard let namedSink = try namedReader.value() else { throw MixedPipelineFailure(name: "named foreign result lost capability") }
            let namedReply = try await namedSink.echo { $0.setValue("named fallback") }
            try mixedCheck((try namedReply.value()) == "mixed:named fallback", "named foreign results remain readable from Capnp-only producers")
            #if PIPELINE_PRODUCER_RPC
            let projected = call.pipeline.value.typed().value()
            let typed = try await projected.echo { $0.setValue("typed") }
            try mixedCheck((try typed.value()) == "mixed:typed", "RPC producers expose typed foreign struct projections")
            let namedTyped = try await named.pipeline.typed().value().echo { $0.setValue("named typed") }
            try mixedCheck((try namedTyped.value()) == "mixed:named typed", "RPC producers expose typed named foreign result projections")
            #endif
        } catch { await connection.close(); _ = await server.waitClosed(); throw error }
        await connection.close(); _ = await server.waitClosed()
    }
    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { FileHandle.standardError.write(Data("MIXED_PIPELINE_FAIL: watchdog expired\n".utf8)); exit(1) }
        do { try await run() }
        catch { FileHandle.standardError.write(Data("MIXED_PIPELINE_FAIL: \(error)\n".utf8)); exit(1) }
    }
}
