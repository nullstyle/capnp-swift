// Unix-domain sockets over Network.framework (plan §7, M5): a client
// transport and a listener addition. The plan's two hard rules:
//
//   - `NWConnection(to: .unix(path:))` TRAPS synchronously when the path
//     is 105 bytes or more (an M0 probe finding): every entry point checks
//     `path.utf8.count <= 104` before any NW call.
//   - An `NWListener` on such a path reports `.ready` but creates no socket
//     file: after `.ready` the listener verifies the file exists (and
//     creates the 0700 parent directory + `flock`s `<path>.lock`, capnp-zig's
//     convention, so concurrent listeners cannot silently shadow each other).
//
// capnp-zig peers must keep `max_fds_per_message = 0` toward us; fd passing
// stays compiled out of the core either way.

import CapnpRPC
import Dispatch
import Foundation
import Network

/// The longest unix socket path Network.framework accepts without trapping
/// (104 bytes, sun_path minus its NUL).
public let capnpUnixPathLimit = 104

enum UnixPathError: Error, CustomStringConvertible, Sendable {
    case tooLong(Int)
    case socketFileMissing(String)

    var description: String {
        switch self {
        case .tooLong(let n): "unix socket path is \(n) bytes (limit \(capnpUnixPathLimit))"
        case .socketFileMissing(let p): "listener reported ready but \(p) does not exist"
        }
    }
}

func checkUnixPath(_ path: String) throws {
    guard path.utf8.count <= capnpUnixPathLimit else {
        throw UnixPathError.tooLong(path.utf8.count)
    }
}

/// A client `Transport` over an `AF_UNIX` socket.
public final class UnixTransport: Transport, @unchecked Sendable {
    private let path: String
    private let connectTimeout: Duration
    private var connection: NWConnection?
    private var queue: DispatchSerialQueue?
    private var delegate: (any TransportDelegate)?
    private var ready = false
    private var closed = false
    private var paused = false
    private var receiving = false
    private var buffered: [([UInt8], @Sendable () -> Void)] = []
    private var opening: CheckedContinuation<Void, any Error>?
    private var timeoutWork: DispatchWorkItem?

    public init(path: String, connectTimeout: Duration = .seconds(10)) {
        self.path = path
        self.connectTimeout = connectTimeout
    }

    public func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        self.queue = queue
        self.delegate = delegate
        do {
            try checkUnixPath(path)
        } catch {
            fail(TCPTransport.ConnectError.failed("\(error)"))
            return
        }
        let nw = NWConnection(to: .unix(path: path), using: NWParameters.tcp)
        connection = nw
        scheduleTimeout()
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !ready, !closed else { return }
                ready = true
                cancelTimeout()
                let pending = buffered
                buffered.removeAll()
                for (bytes, completion) in pending { send(bytes, completion: completion) }
                if let opening {
                    self.opening = nil
                    opening.resume()
                }
                receiveLoop()
            case .failed(let error):
                cancelTimeout()
                fail(TCPTransport.ConnectError.failed("\(error)"))
            case .cancelled:
                cancelTimeout()
                fail(TCPTransport.ConnectError.cancelled)
            default:
                break
            }
        }
        nw.start(queue: queue)
    }

    public func open() async throws {
        if ready { return }
        if closed { throw TCPTransport.ConnectError.cancelled }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue?.async { [weak self] in
                guard let self else { return continuation.resume(throwing: TCPTransport.ConnectError.cancelled) }
                if self.ready { return continuation.resume() }
                if self.closed { return continuation.resume(throwing: TCPTransport.ConnectError.cancelled) }
                self.opening = continuation
            }
        }
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !(ready || closed) else { return }
            connection?.cancel()
        }
        timeoutWork = work
        queue?.asyncAfter(deadline: .now() + Double(connectTimeout.components.seconds), execute: work)
    }

    private func cancelTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }

    private func fail(_ error: any Error) {
        guard !closed else { return }
        closed = true
        cancelTimeout()
        if let opening {
            self.opening = nil
            opening.resume(throwing: error)
        }
        delegate?.transportDidClose(error: error)
    }

    public func send(_ bytes: [UInt8], completion: @escaping @Sendable () -> Void) {
        guard ready, !closed else {
            completion()
            return
        }
        if paused {
            buffered.append((bytes, completion))
            return
        }
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in completion() })
    }

    public func pauseReceiving() {
        paused = true
    }

    public func resumeReceiving() {
        paused = false
        let held = buffered
        buffered = []
        for (bytes, completion) in held {
            send(bytes, completion: completion)
        }
        receiveLoop()
    }

    private func receiveLoop() {
        guard ready, !closed, !paused, !receiving else { return }
        receiving = true
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            receiving = false
            if let data, !data.isEmpty {
                delegate?.transportDidReceive(Array(data))
            }
            if let error {
                fail(TCPTransport.ConnectError.failed("\(error)"))
                return
            }
            if isComplete {
                fail(TCPTransport.ConnectError.cancelled)
                return
            }
            receiveLoop()
        }
    }

    public func cancel() {
        guard !closed else { return }
        closed = true
        cancelTimeout()
        connection?.cancel()
        delegate?.transportDidClose(error: nil)
    }
}
