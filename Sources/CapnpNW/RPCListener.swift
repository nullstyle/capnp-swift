import CapnpRPC
import Dispatch
import Foundation
import Network
import Synchronization

/// A TCP server (plan §5 `RPCListener`): an `NWListener` that gives every
/// accepted connection its own `RPCConnection` (its own actor and queue) with
/// a fresh bootstrap object from `bootstrap()`.
public final class RPCListener: Sendable {
    private struct State {
        var connections: [ObjectIdentifier: RPCConnection] = [:]
        var ready: CheckedContinuation<UInt16, any Error>?
        var port: UInt16?
        var failed: (any Error)?
        var cancelled = false
    }

    public enum ListenError: Error, Sendable {
        case failed(String)
        case cancelled
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "capnp-swift.listener")
    private let bootstrap: @Sendable () -> any ExportHandler
    private let options: RPCConnection.Options
    private let state = Mutex<State>(State())
    private let serverOptions: Options

    public struct Options: Sendable {
        /// Refuse connections beyond this many live ones (0 = no limit).
        public var maxConnections = 0

        public init() {}
    }

    /// Listen on `port` (0 for an ephemeral one, read `port` after `start`).
    public init(
        port: UInt16,
        bootstrap: @escaping @Sendable () -> any ExportHandler,
        options: RPCConnection.Options = .init(),
        serverOptions: Options = .init()
    ) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcp)
        listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.bootstrap = bootstrap
        self.options = options
        self.serverOptions = serverOptions
    }

    /// Start accepting; resolves with the bound port.
    public func start() async throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] nwState in
            guard let self else { return }
            switch nwState {
            case .ready:
                let port = self.listener.port?.rawValue ?? 0
                let waiter = self.state.withLock { s -> CheckedContinuation<UInt16, any Error>? in
                    s.port = port
                    defer { s.ready = nil }
                    return s.ready
                }
                waiter?.resume(returning: port)
            case .failed(let error):
                let waiter = self.state.withLock { s -> CheckedContinuation<UInt16, any Error>? in
                    s.failed = error
                    defer { s.ready = nil }
                    return s.ready
                }
                waiter?.resume(throwing: ListenError.failed(String(describing: error)))
            case .cancelled:
                let waiter = self.state.withLock { s -> CheckedContinuation<UInt16, any Error>? in
                    s.cancelled = true
                    defer { s.ready = nil }
                    return s.ready
                }
                waiter?.resume(throwing: ListenError.cancelled)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nwConnection in
            self?.accept(nwConnection)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            state.withLock { $0.ready = continuation }
            listener.start(queue: queue)
        }
    }

    /// The bound port once `start` resolved.
    public var port: UInt16? { state.withLock { $0.port } }

    /// Live connections.
    public var connectionCount: Int { state.withLock { $0.connections.count } }

    /// Stop accepting and close every connection.
    public func cancel() {
        listener.cancel()
        let live = state.withLock { s -> [RPCConnection] in
            defer { s.connections.removeAll() }
            return Array(s.connections.values)
        }
        for connection in live {
            Task { await connection.close() }
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let over = state.withLock { s in serverOptions.maxConnections > 0 && s.connections.count >= serverOptions.maxConnections }
        if over {
            nwConnection.cancel()
            return
        }
        let transport = TCPTransport(connection: nwConnection)
        let handler = bootstrap()
        let connection: RPCConnection
        do {
            connection = try RPCConnection(transport: transport, bootstrap: handler, options: options)
        } catch {
            nwConnection.cancel()
            return
        }
        state.withLock { $0.connections[ObjectIdentifier(connection)] = connection }
        Task { [weak self] in
            do {
                try await connection.start()
            } catch {
                // The connection reports its own close; drop it below.
            }
            _ = await connection.waitClosed()
            self?.state.withLock { _ = $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
        }
    }
}
