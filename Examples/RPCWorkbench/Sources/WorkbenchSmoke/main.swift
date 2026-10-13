import Foundation
import WorkbenchKit

@main enum WorkbenchSmoke {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "serve" {
            let host = try await WorkbenchHost.start()
            print("RPC_WORKBENCH_READY tcp=\(host.tcpPort) tls=\(host.tlsPort)")
            fflush(stdout)
            while !Task.isCancelled { try await Task.sleep(for: .seconds(60)) }
            host.stop()
            return
        }
        let host = try await WorkbenchHost.start(tcpPort: 0, tlsPort: 0)
        defer { host.stop() }
        for mode in WorkbenchMode.allCases {
            let endpoint = WorkbenchEndpoint(host: "127.0.0.1", port: mode == .tcp ? host.tcpPort : host.tlsPort, mode: mode)
            let peer = try await endpoint.connect()
            do {
                let client = try await WorkbenchClient.open(peer: peer)
                for check in try await client.runChecks() { print("WORKBENCH_PASS [\(mode.rawValue)]: \(check.name)") }
                await client.close()
                for check in try await WorkbenchVerification.lifecycle(endpoint: endpoint) { print("WORKBENCH_PASS [\(mode.rawValue)]: \(check.name)") }
            } catch { await peer.connection.close(); throw error }
        }
        let tls = WorkbenchEndpoint(host: "127.0.0.1", port: host.tlsPort, mode: .tls)
        for check in try await WorkbenchVerification.rejectsWrongPin(endpoint: tls) { print("WORKBENCH_PASS: \(check.name)") }
    }
}
