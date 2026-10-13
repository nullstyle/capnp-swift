import Testing
import WorkbenchKit

@Suite("Workbench network", .serialized)
struct NetworkTests {
    @Test("real TCP and TLS exercise typed calls callbacks streams cancellation and lifecycle", arguments: WorkbenchMode.allCases)
    func network(mode: WorkbenchMode) async throws {
        let host = try await WorkbenchHost.start(tcpPort: 0, tlsPort: 0)
        defer { host.stop() }
        let endpoint = WorkbenchEndpoint(host: "127.0.0.1", port: mode == .tcp ? host.tcpPort : host.tlsPort, mode: mode)
        let peer = try await endpoint.connect()
        do {
            let client = try await WorkbenchClient.open(peer: peer)
            _ = try await client.runChecks()
            await client.close()
            _ = try await WorkbenchVerification.lifecycle(endpoint: endpoint)
        } catch { await peer.connection.close(); throw error }
    }

    @Test("TLS refuses the wrong certificate pin")
    func wrongPin() async throws {
        let host = try await WorkbenchHost.start(tcpPort: 0, tlsPort: 0)
        defer { host.stop() }
        _ = try await WorkbenchVerification.rejectsWrongPin(endpoint:
            WorkbenchEndpoint(host: "127.0.0.1", port: host.tlsPort, mode: .tls))
    }
}
