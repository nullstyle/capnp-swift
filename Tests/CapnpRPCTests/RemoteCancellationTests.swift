// The caller cancels a call that a Swift handler is still running (M9 G6).
// The caller's core sends Finish. The core tells a host that opts in
// (capnp-zig v0.28.0, handoff H13: CAPNP_EFFECT_ANSWER_FINISHED), but the
// runtime does not opt in yet, so the handler's Task runs on. Until it does,
// the check below is a known issue: Swift Testing fails the test when the
// issue stops happening, so the adoption must remove the wrapper.

@testable import CapnpRPC
import Synchronization
import Testing

/// Records that its call started, and that the call's Task was cancelled.
final class CancelProbe: Echo.Server, Sendable {
    private let state = Mutex<(started: Bool, cancelled: Bool)>((false, false))

    var started: Bool { state.withLock { $0.started } }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func echo(_ n: UInt64) async throws -> UInt64 {
        state.withLock { $0.started = true }
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            state.withLock { $0.cancelled = true }
            throw error
        }
        return n
    }
}

/// True as soon as `condition` holds; false when `limit` passes first.
private func eventually(_ limit: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite("Remote cancellation")
struct RemoteCancellationTests {
    @Test("a caller's cancel cancels the Swift handler's Task (H13)")
    func callerCancelReachesHandler() async throws {
        let probe = CancelProbe()
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: probe))
        let echo = Echo.Client(target: .cap(cap), connection: client)

        let call = Task { try await echo.echo(1) }
        #expect(await eventually(.seconds(5)) { probe.started }, "the handler never started")
        call.cancel()
        guard case .failure(let error as RPCError) = await call.result else {
            Issue.record("the cancelled call did not fail")
            return
        }
        #expect(error == .canceled)

        let reached = await eventually(.seconds(1)) { probe.cancelled }
        withKnownIssue("H13: the runtime does not opt in to ANSWER_FINISHED yet") {
            #expect(reached, "the handler's Task was not cancelled within 1 s")
        }
        await client.close()
        _ = await server.waitClosed()
    }
}
