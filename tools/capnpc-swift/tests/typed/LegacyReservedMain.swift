import Capnp
import CapnpRPC

private struct ReservedServer: Reserved.Server {
    func ping(params: Target.PingParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Target.PingResults {
        .init { $0.setValue("target ancestor") }
    }
    func pong(params: Connection.PongParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Connection.PongResults {
        .init { $0.setValue("connection ancestor") }
    }
}

@main
private struct VerifyLegacyReserved {
    static func main() async throws {
        let (a, b) = LoopbackTransport.pair()
        let server = try await RPCConnection.connect(transport: b, bootstrap: Reserved.Export(ReservedServer()))
        let connection = try await RPCConnection.connect(transport: a)
        let client = Reserved.Client(cap: try await connection.bootstrap(), connection: connection)
        let target = try await client.target2.ping()
        let inheritedConnection = try await client.connection2.pong()
        guard try target.value() == "target ancestor", try inheritedConnection.value() == "connection ancestor",
              client.connection === connection else {
            fatalError("LEGACY_RPC_FAIL: ancestor views preserve target and connection")
        }
        await connection.close()
        await server.close()
        print("PASS: legacy ancestor views preserve target and connection")
    }
}
