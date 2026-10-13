// Diagnostic only. Uses public Network APIs; no Capnp modules or wire peer.
// Each invocation exits with its connections retained, isolating startup from teardown.
import Dispatch
import Foundation
import Network
import Synchronization

private func trace(_ stage: String, id: Int = -1) {
    let ns = DispatchTime.now().uptimeNanoseconds
    FileHandle.standardError.write(Data("QUIC_ORDER_STAGE ns=\(ns) id=\(id) \(stage)\n".utf8))
}

private final class Progress: Sendable {
    struct State {
        var startWaiting: Set<Int> = []
        var openWaiting: Set<Int> = []
        var startEntered: Set<Int> = []
        var startReturned: Set<Int> = []
        var openEntered: Set<Int> = []
        var held = false
    }
    private let state = Mutex(State())
    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var snapshot: State { state.withLock { $0 } }
}

private final class StartBarrier: Sendable {
    private struct State { var released = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())
    private let synchronous = DispatchSemaphore(value: 0)
    func waitSynchronous() { synchronous.wait() }
    func waitAsync() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.released { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func release(count: Int, opensFirst: Bool) {
        let waiters = state.withLock { state in
            state.released = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        // Alternate which side is signaled first across isolated runs. There
        // is no intervening await or sleep; every participant shares this gate.
        if opensFirst { for waiter in waiters { waiter.resume() } }
        for _ in 0..<count { synchronous.signal() }
        if !opensFirst { for waiter in waiters { waiter.resume() } }
    }
}

@available(macOS 26.0, *)
@main private enum NetworkQUICOrder {
    private static func open(_ connection: NetworkConnection<QUIC>, id: Int, progress: Progress) async {
        progress.update { $0.openEntered.insert(id) }
        trace("openStream_enter", id: id)
        do {
            let stream = try await connection.openStream()
            trace("openStream_return", id: id)
            withExtendedLifetime(stream) {}
        } catch {
            trace("openStream_error \(error)", id: id)
        }
    }
    private static func wait(_ name: String, until condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                FileHandle.standardError.write(Data("QUIC_ORDER_FAIL: \(name) timed out\n".utf8))
                exit(2)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let count = Int(args[2]), count > 0, count <= 16,
              ["concurrent", "queued-start", "inline-start", "open-only", "construct-only"].contains(args[1]),
              ["starts-first", "opens-first"].contains(args[3]) else {
            FileHandle.standardError.write(Data("QUIC_ORDER_FAIL: use <mode> <1...16 connections> <starts-first|opens-first>\n".utf8))
            exit(2)
        }
        let mode = args[1], opensFirst = args[3] == "opens-first"
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
            FileHandle.standardError.write(Data("QUIC_ORDER_FAIL: process watchdog expired\n".utf8)); exit(2)
        }
        let progress = Progress(), barrier = StartBarrier()
        let heldQueue = DispatchSemaphore(value: 0)
        var connections: [NetworkConnection<QUIC>] = []
        var queues: [DispatchSerialQueue] = []
        for id in 0..<count {
            trace("constructor_enter", id: id)
            // Mirrors the client ALPN/idle timeout/validator setup. The validator
            // rejects all certificates: this probe never trusts an external peer.
            let quic = QUIC(alpn: ["capnp-rpc/1"]).idleTimeout(30_000)
                .tls.certificateValidator { _, _ in false }
            let connection = NetworkConnection<QUIC>(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 9)!),
                using: .init { quic })
            trace("constructor_return", id: id)
            trace("onStateUpdate_enter", id: id)
            connection.onStateUpdate { _, state in
                switch state {
                case .ready: trace("state_ready", id: id)
                case .failed: trace("state_failed", id: id)
                case .cancelled: trace("state_cancelled", id: id)
                default: trace("state_other", id: id)
                }
            }
            trace("onStateUpdate_return", id: id)
            connections.append(connection)
            let queue = DispatchSerialQueue(label: "capnp.diagnostic.quic-order.\(id)")
            queues.append(queue)
            if mode == "concurrent" {
                queue.async {
                    progress.update { $0.startWaiting.insert(id) }
                    trace("explicit_start_waiting", id: id)
                    barrier.waitSynchronous()
                    progress.update { $0.startEntered.insert(id) }
                    trace("explicit_start_enter", id: id)
                    _ = connection.start()
                    progress.update { $0.startReturned.insert(id) }
                    trace("explicit_start_return", id: id)
                }
                Task.detached {
                    progress.update { $0.openWaiting.insert(id) }
                    trace("openStream_waiting", id: id)
                    await barrier.waitAsync()
                    await open(connection, id: id, progress: progress)
                }
            } else {
                queue.async {
                    if mode == "queued-start" {
                        queue.async {
                            progress.update { $0.startEntered.insert(id) }
                            trace("explicit_start_enter", id: id)
                            _ = connection.start()
                            progress.update { $0.startReturned.insert(id) }
                            trace("explicit_start_return", id: id)
                        }
                    } else if mode == "inline-start" {
                        progress.update { $0.startEntered.insert(id) }
                        trace("explicit_start_enter", id: id)
                        _ = connection.start()
                        progress.update { $0.startReturned.insert(id) }
                        trace("explicit_start_return", id: id)
                    }
                    if mode != "construct-only" {
                        Task.detached { await open(connection, id: id, progress: progress) }
                    }
                    progress.update { $0.held = true }
                    trace("dispatch_queue_held", id: id)
                    heldQueue.wait()
                }
            }
        }
        if mode == "concurrent" {
            try await wait("all barrier participants") {
                let state = progress.snapshot
                return state.startWaiting.count == count && state.openWaiting.count == count
            }
            trace("barrier_release \(args[3]) connections=\(count)")
            barrier.release(count: count, opensFirst: opensFirst)
            try await wait("both public API entries") {
                let state = progress.snapshot
                return state.startEntered.count == count && state.openEntered.count == count && state.startReturned.count == count
            }
        } else {
            try await wait("held queue and public API entry") {
                let state = progress.snapshot
                return state.held && (mode == "construct-only" || state.openEntered.count == count)
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        let final = progress.snapshot
        guard mode != "queued-start" || final.startEntered.isEmpty else {
            FileHandle.standardError.write(Data("QUIC_ORDER_FAIL: queued explicit start escaped the held queue\n".utf8)); exit(2)
        }
        withExtendedLifetime((connections, queues, progress, barrier, heldQueue)) {
            print("QUIC_ORDER_SURVIVED: mode=\(mode) connections=\(count) release=\(args[3]) explicit_start_entries=\(final.startEntered.count) openStream_entries=\(final.openEntered.count)")
            // Retained objects and held queues are intentionally not torn down.
            // A different probe/real test must diagnose SDK teardown behavior.
            exit(0)
        }
    }
}
