// The M5 lifecycle gate (plan §8): background suspends the connection
// (shutdown + close), foreground reconnects through the factory.

import CapnpRPC
import Synchronization
import Testing

@Suite("Lifecycle")
struct LifecycleTests {
    @Test("background suspends, foreground reconnects")
    func suspendAndReconnect() async throws {
        let (a, b) = LoopbackTransport.pair()
        let first = try await RPCConnection.connect(transport: b)
        a.cancel()

        let counter = Mutex(0)
        let policy = RPCLifecyclePolicy(connection: first) {
            counter.withLock { $0 += 1 }
            let (x, y) = LoopbackTransport.pair()
            x.cancel()
            return try await RPCConnection.connect(transport: y)
        }
        #expect(policy.connection != nil)

        await policy.scenePhaseDidChange(.background)
        #expect(policy.connection == nil, "background suspended the connection")
        // The policy closed the connection itself; whatever close reason
        // surfaces, the connection must be finished.
        _ = await first.waitClosed()
        #expect(await first.isClosed)

        await policy.scenePhaseDidChange(.active)
        #expect(policy.connection != nil, "foreground reconnected")
        #expect(counter.withLock { $0 } == 1)

        // A second activation with a live connection reconnects nothing.
        await policy.scenePhaseDidChange(.inactive)
        await policy.scenePhaseDidChange(.active)
        #expect(counter.withLock { $0 } == 1)
        await policy.connection?.close()
    }

    @Test("a failing reconnect reports the reason and retries on demand")
    func failedReconnect() async throws {
        let (a, b) = LoopbackTransport.pair()
        let first = try await RPCConnection.connect(transport: b)
        a.cancel()

        let policy = RPCLifecyclePolicy(connection: first) {
            throw RPCError.disconnected(reason: "unreachable")
        }
        await policy.scenePhaseDidChange(.background)
        await policy.scenePhaseDidChange(.active)
        #expect(policy.connection == nil)

        if case .failed = await policy.reconnect() {
            // expected
        } else {
            Issue.record("reconnect should have failed")
        }
        await first.close()
    }
}
