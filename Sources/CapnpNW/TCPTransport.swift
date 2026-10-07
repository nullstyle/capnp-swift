import CapnpRPC
import Dispatch
import Foundation
import Network

/// A TCP connection as a `Transport` (plan §7.1): `NWConnection` with
/// `TCP_NODELAY` and keepalive on, raw `receive(minimumIncompleteLength: 1)`
/// feeding `push_bytes`, sends in order, a connect timeout.
///
/// Every method runs on the connection's queue (the `RPCConnection` actor
/// calls them from its executor, and `NWConnection.start(queue:)` runs the
/// callbacks there), so the state below needs no lock.
public final class TCPTransport: Transport, @unchecked Sendable {
    private let connection: NWConnection
    private let connectTimeout: Duration
    private var queue: DispatchSerialQueue?
    private var delegate: (any TransportDelegate)?
    private var ready = false
    private var closed = false
    private var buffered: [[UInt8]] = []
    private var opening: CheckedContinuation<Void, any Error>?
    private var timeoutWork: DispatchWorkItem?

    public enum ConnectError: Error, Sendable {
        case timedOut(Duration)
        case failed(String)
        case cancelled
    }

    /// Connect to `host`:`port` when started.
    public init(host: String, port: UInt16, connectTimeout: Duration = .seconds(10)) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = Int(max(1, connectTimeout.components.seconds))
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any, using: params)
        self.connectTimeout = connectTimeout
    }

    /// Wrap an accepted or pre-built connection (not started yet).
    public init(connection: NWConnection, connectTimeout: Duration = .seconds(10)) {
        self.connection = connection
        self.connectTimeout = connectTimeout
    }

    public func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        self.queue = queue
        self.delegate = delegate
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ready, !self.closed else { return }
            self.finish(error: ConnectError.timedOut(self.connectTimeout))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: Self.nanoseconds(connectTimeout))), execute: work)
        connection.start(queue: queue)
    }

    public func open() async throws {
        if ready { return }
        if closed { throw ConnectError.cancelled }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            opening = continuation
        }
    }

    public func send(_ bytes: [UInt8]) {
        if closed { return }
        guard ready else {
            buffered.append(bytes)
            return
        }
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error: error) }
        })
    }

    public func cancel() {
        if closed { return }
        // The `.cancelled` state follows and finishes the transport.
        connection.cancel()
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !ready, !closed else { return }
            ready = true
            timeoutWork?.cancel()
            timeoutWork = nil
            let pendingSends = buffered
            buffered.removeAll()
            for frame in pendingSends { send(frame) }
            opening?.resume()
            opening = nil
            receiveNext()
        case .failed(let error):
            finish(error: ConnectError.failed(String(describing: error)))
        case .cancelled:
            finish(error: nil)
        case .waiting:
            // Retriable until the connect timeout fires (plan §5).
            break
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.delegate?.transportDidReceive([UInt8](data))
            }
            if let error {
                self.finish(error: error)
                return
            }
            if isComplete {
                self.finish(error: nil)
                return
            }
            self.receiveNext()
        }
    }

    private func finish(error: (any Error)?) {
        guard !closed else { return }
        closed = true
        timeoutWork?.cancel()
        timeoutWork = nil
        buffered.removeAll()
        if let opening {
            self.opening = nil
            opening.resume(throwing: error ?? ConnectError.cancelled)
        }
        connection.cancel()
        delegate?.transportDidClose(error: error)
    }

    private static func nanoseconds(_ d: Duration) -> Int64 {
        let c = d.components
        return c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
    }
}
