// ExecutorProbe (plan §5, M0 gate): an actor whose executor is a
// DispatchSerialQueue can hand that same queue to Network.framework, and every
// NW callback then runs isolated to the actor, so the connection actor can
// drain the core's effects synchronously (`assumeIsolated`) from inside them.
//
// The probe runs an NWListener and an NWConnection over loopback TCP, both on
// the actor's queue, echoes a payload, and records for every callback whether
// it ran on the actor's executor. It passes only if every callback did, and
// every expected callback fired at least once.

import Dispatch
import Foundation
import Network
import Synchronization
import Testing

/// Where each callback ran. Mutex-guarded so callbacks that are NOT isolated
/// (the failure case) can still record themselves without a data race.
private final class CallbackLog: Sendable {
    struct Entry: Sendable {
        let tag: String
        let isolated: Bool
    }

    private let entries = Mutex<[Entry]>([])

    func record(_ tag: String, isolated: Bool) {
        entries.withLock { $0.append(Entry(tag: tag, isolated: isolated)) }
    }

    var snapshot: [Entry] {
        entries.withLock { $0 }
    }
}

/// Resumes a continuation exactly once, from any thread.
private final class Once<Value: Sendable>: Sendable {
    private let state = Mutex<CheckedContinuation<Value, Never>?>(nil)

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        state.withLock { $0 = continuation }
    }

    func resume(_ value: Value) {
        let continuation = state.withLock { slot -> CheckedContinuation<Value, Never>? in
            defer { slot = nil }
            return slot
        }
        continuation?.resume(returning: value)
    }
}

/// Tags the actor's queue so a callback can ask "am I on it?" without trapping.
private let probeQueueKey = DispatchSpecificKey<String>()

private actor ExecutorProbe {
    nonisolated let queue: DispatchSerialQueue
    nonisolated let log = CallbackLog()
    private nonisolated let token = UUID().uuidString

    /// Actor state touched only from inside `assumeIsolated`: proves the
    /// callbacks get synchronous isolated access, not just "the right thread".
    private var isolatedCallbacks = 0

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init() {
        queue = DispatchSerialQueue(label: "capnp-swift.executor-probe")
        queue.setSpecific(key: probeQueueKey, value: token)
    }

    /// Called first thing in every NW callback.
    nonisolated func observe(_ tag: String) {
        guard DispatchQueue.getSpecific(key: probeQueueKey) == token else {
            log.record(tag, isolated: false)
            return
        }
        // Traps if the Swift runtime does not consider this queue the actor's
        // executor, even though we are on it.
        assumeIsolated { probe in
            probe.isolatedCallbacks += 1
        }
        log.record(tag, isolated: true)
    }

    func isolatedCallbackCount() -> Int {
        isolatedCallbacks
    }
}

private enum EchoResult: Sendable, Equatable {
    case echoed([UInt8])
    case failed(String)
}

@Suite("ExecutorProbe")
struct ExecutorProbeTests {
    @Test("NW callbacks on the actor's DispatchSerialQueue run isolated to the actor")
    func nwCallbacksRunIsolated() async throws {
        let probe = ExecutorProbe()
        let payload = Array("capnp-swift executor probe".utf8)
        let done = Once<EchoResult>()

        let listener = try NWListener(using: .tcp, on: .any)
        let serverConnections = Mutex<[NWConnection]>([])
        let clientBox = Mutex<NWConnection?>(nil)

        listener.newConnectionHandler = { connection in
            probe.observe("listener.newConnection")
            serverConnections.withLock { $0.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .ready = state { probe.observe("server.ready") }
                if case .failed(let error) = state { done.resume(.failed("server: \(error)")) }
            }
            connection.receive(minimumIncompleteLength: payload.count, maximumLength: 65536) { data, _, _, error in
                probe.observe("server.receive")
                guard let data, error == nil else {
                    done.resume(.failed("server receive: \(String(describing: error))"))
                    return
                }
                connection.send(content: data, completion: .contentProcessed { error in
                    probe.observe("server.send")
                    if let error { done.resume(.failed("server send: \(error)")) }
                })
            }
            connection.start(queue: probe.queue)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                probe.observe("listener.ready")
                guard let port = listener.port else {
                    done.resume(.failed("listener has no port"))
                    return
                }
                let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
                clientBox.withLock { $0 = client }
                client.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        probe.observe("client.ready")
                        client.send(content: Data(payload), completion: .contentProcessed { error in
                            probe.observe("client.send")
                            if let error { done.resume(.failed("client send: \(error)")) }
                        })
                        client.receive(minimumIncompleteLength: payload.count, maximumLength: 65536) { data, _, _, error in
                            probe.observe("client.receive")
                            guard let data, error == nil else {
                                done.resume(.failed("client receive: \(String(describing: error))"))
                                return
                            }
                            done.resume(.echoed(Array(data)))
                        }
                    case .failed(let error):
                        done.resume(.failed("client: \(error)"))
                    default:
                        break
                    }
                }
                client.start(queue: probe.queue)
            case .failed(let error):
                done.resume(.failed("listener: \(error)"))
            default:
                break
            }
        }

        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            done.resume(.failed("timed out after 10 s"))
        }
        let result = await withCheckedContinuation { continuation in
            done.arm(continuation)
            listener.start(queue: probe.queue)
        }
        timeout.cancel()
        clientBox.withLock { $0?.cancel() }
        serverConnections.withLock { $0.forEach { $0.cancel() } }
        listener.cancel()

        #expect(result == .echoed(payload))

        let entries = probe.log.snapshot
        let expected = [
            "listener.ready", "listener.newConnection", "server.ready", "server.receive",
            "server.send", "client.ready", "client.send", "client.receive",
        ]
        for tag in expected {
            #expect(entries.contains { $0.tag == tag }, "callback \(tag) never ran")
        }
        let notIsolated = entries.filter { !$0.isolated }.map(\.tag)
        #expect(notIsolated.isEmpty, "callbacks not isolated to the actor: \(notIsolated)")
        let isolatedCount = await probe.isolatedCallbackCount()
        #expect(isolatedCount == entries.filter(\.isolated).count)
    }
}
