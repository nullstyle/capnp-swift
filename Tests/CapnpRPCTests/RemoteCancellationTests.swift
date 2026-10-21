// The caller cancels a call that a Swift handler is still running (M9 G6,
// capnp-zig H13). The caller's core sends Finish. A core with
// CAPNP_FEATURE_ANSWER_FINISHED reports it, and the runtime cancels the
// handler's Task and answers Return{canceled} at once.

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

/// Ignores cancellation: it answers only when the test opens its gate.
final class StubbornEcho: Echo.Server, Sendable {
    private struct State {
        var started = false
        var open = false
        var gate: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    var started: Bool { state.withLock { $0.started } }

    func openGate() {
        let gate = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.open = true
            defer { s.gate = nil }
            return s.gate
        }
        gate?.resume()
    }

    func echo(_ n: UInt64) async throws -> UInt64 {
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                s.started = true
                if s.open { return true }
                s.gate = gate
                return false
            }
            if now { gate.resume() }
        }
        return n
    }
}

/// True as soon as `condition` holds; false when `limit` passes first.
private func eventually(_ limit: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
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

        #expect(await eventually(.seconds(1)) { probe.cancelled }, "the handler's Task was not cancelled within 1 s")
        #expect(await eventually(.seconds(1)) { await server.owedAnswerCount == 0 })
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("a handler that ignores the cancel: the caller is answered at once, the late answer is dropped")
    func lateAnswerIsDropped() async throws {
        let probe = StubbornEcho()
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: probe))
        let echo = Echo.Client(target: .cap(cap), connection: client)

        let call = Task { try await echo.echo(1) }
        #expect(await eventually(.seconds(5)) { probe.started }, "the handler never started")
        call.cancel()
        _ = await call.result
        // Return{canceled} went out while the handler still waits.
        #expect(await eventually(.seconds(1)) { await server.owedAnswerCount == 0 }, "no canceled answer while the handler runs")
        probe.openGate()
        #expect(await eventually(.seconds(1)) { await server.lateAnswersDropped == 1 })
        // The connection is healthy: the next call is answered.
        #expect(try await echo.echo(5) == 5)
        #expect(await server.closeCause == nil)
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("answer once: handlers that end while the caller cancels")
    func answerOnceRace() async throws {
        let counter = CountingEcho()
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: counter))
        let echo = Echo.Client(target: .cap(cap), connection: client)

        for i in 0..<200 {
            let call = Task { try await echo.echo(UInt64(i)) }
            if i % 2 == 0 { await Task.yield() }
            call.cancel()
            _ = await call.result
        }
        #expect(try await echo.echo(7) == 7)
        #expect(await eventually(.seconds(2)) { await server.owedAnswerCount == 0 })
        let ran = counter.count
        let dropped = await server.lateAnswersDropped
        #expect(dropped > 0, "no call took the cancel path")
        #expect(await client.closeCause == nil)
        #expect(await server.closeCause == nil)
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("cancelHandlersOnFinish = false keeps the handler running")
    func optionOff() async throws {
        var options = RPCConnection.Options()
        options.cancelHandlersOnFinish = false
        let probe = CancelProbe()
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: probe), serverOptions: options)
        let echo = Echo.Client(target: .cap(cap), connection: client)

        let call = Task { try await echo.echo(1) }
        #expect(await eventually(.seconds(5)) { probe.started }, "the handler never started")
        call.cancel()
        _ = await call.result
        #expect(!(await eventually(.milliseconds(300)) { probe.cancelled }))
        #expect(await server.owedAnswerCount == 1)
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("closing the connection cancels the handlers that still run")
    func closeCancelsHandlers() async throws {
        let probe = CancelProbe()
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: probe))
        let echo = Echo.Client(target: .cap(cap), connection: client)

        let call = Task { try await echo.echo(1) }
        #expect(await eventually(.seconds(5)) { probe.started }, "the handler never started")
        await client.close()
        _ = await server.waitClosed()
        #expect(await eventually(.seconds(1)) { probe.cancelled }, "the handler's Task was not cancelled by the close")
        _ = await call.result
    }
}

/// Counts its calls.
final class CountingEcho: Echo.Server, Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func echo(_ n: UInt64) async throws -> UInt64 {
        calls.withLock { $0 += 1 }
        return n
    }
}
