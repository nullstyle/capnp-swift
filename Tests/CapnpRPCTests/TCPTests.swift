// Swift <-> Swift over real TCP: `RPCListener` (NWListener) serving `Greeter`,
// a `TCPTransport` client, both directions, then listener shutdown.

import CapnpMVP
import CapnpNW
import CapnpRPC
import Testing

@Suite("TCP")
struct TCPTests {
    @Test("RPCListener serves a client over loopback TCP, both directions, and closes its connections")
    func listenerRoundTrip() async throws {
        let listener = try RPCListener(port: 0, bootstrap: { Greeter.Export(SwiftGreeter()) })
        let port = try await listener.start()
        #expect(port != 0)

        let client = try await RPCConnection.connect(transport: TCPTransport(host: "127.0.0.1", port: port, connectTimeout: .seconds(5)))
        // The timeout turns a server that never starts its connection (the
        // ablation) into a fast failure instead of a hang.
        let greeter = Greeter.Client(cap: try await withTimeout(.seconds(10)) { try await client.bootstrap() }, connection: client)
        let recorder = RecordingListener()
        let reply = try await withTimeout(.seconds(10)) { try await greeter.greet(name: "TCP", listener: recorder) }
        #expect(reply == "Hello, TCP!")
        #expect(recorder.messages == ["greeted TCP"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(listener.connectionCount == 1)

        // Closing the listener closes its connections: the client sees
        // .disconnected.
        listener.cancel()
        let cause = try await withTimeout(.seconds(10)) { await client.waitClosed() }
        guard case .disconnected = cause else {
            Issue.record("close cause: \(cause)")
            return
        }
    }

    @Test("a connect to a closed port fails with .disconnected")
    func connectRefused() async throws {
        // Bind and release a port so nothing listens on it. The listener's
        // teardown is asynchronous, so a connect racing a slow close can
        // succeed — retry until the port is truly refusing (observed on a
        // loaded CI runner, 2026-10-08).
        var lastPort: UInt16 = 0
        for _ in 0..<5 {
            let probe = try RPCListener(port: 0, bootstrap: { Greeter.Export(SwiftGreeter()) })
            let port = try await probe.start()
            lastPort = port
            probe.cancel()
            try await Task.sleep(for: .milliseconds(300))
            do {
                _ = try await withTimeout(.seconds(10)) {
                    try await RPCConnection.connect(transport: TCPTransport(host: "127.0.0.1", port: port, connectTimeout: .seconds(3)))
                }
                // The listener was still up; release and try a fresh port.
                continue
            } catch let error as RPCError {
                guard case .disconnected = error else {
                    Issue.record("expected .disconnected, got \(error)")
                    return
                }
                return
            } catch {
                Issue.record("expected RPCError.disconnected, got \(error)")
                return
            }
        }
        Issue.record("connect succeeded on a closed port (5 tries, last port \(lastPort))")
    }
}
