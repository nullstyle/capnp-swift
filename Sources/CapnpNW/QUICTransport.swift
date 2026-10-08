// QUIC baseline over Network.framework's modern async API (plan §7.4, M6;
// Experimental — it is Experimental in capnp-zig too).
//
// Wire shape (frozen by capnp-zig, H3): ALPN "capnp-rpc/1" (read from the
// core via `capnp_core_quic_alpn()`), the client's first bidirectional
// stream (stream 0) carries every RPC frame as one u32 little-endian
// length prefix plus its standalone segment-table bytes — the connection
// MUST be created with `Options.framing = .u32LE` on both ends (the
// default `.segmentTable` never parses the peer's frames). A second
// stream is reset by the
// PEER with application error 0x434e5002 (`protocol_error`, capnp-zig
// `peer_streams.refusal_code`) and the connection stays up; close code 0
// means normal.
//
// Availability: `NetworkConnection<QUIC>`/`NetworkListener<QUIC>` need
// macOS 26 / iOS 26 (plan D2); the package floor stays macOS 15 / iOS 18.
//
// Teardown note: the modern channel classes expose no public `cancel()` in
// this SDK; the transports release their references and let the channel
// deinit close the session (the round-trip test observes the close through
// the RPC layer).

import CapnpCore
import CapnpRPC
import Dispatch
import Foundation
import Network

/// Stage tracing for the QUIC transports: set CAPNP_QUIC_TRACE=1.
private let quicTrace = ProcessInfo.processInfo.environment["CAPNP_QUIC_TRACE"] == "1"
private func qtrace(_ message: @autoclosure () -> String) {
    if quicTrace { NSLog("[quic] %@", message()) }
}

/// The application-close codes the QUIC transport uses (capnp-zig
/// `ApplicationCloseCode`): 0 is a normal close, the 0x434e50xx range the
/// error classes; 0x434e5002 doubles as the refused-stream reset code.
public enum QUICCloseCode: Sendable {
    public static let normal: UInt64 = 0
    public static let frameError: UInt64 = 0x434e_5001
    public static let protocolError: UInt64 = 0x434e_5002
    public static let internalError: UInt64 = 0x434e_5003
    public static let peerCallbackFailure: UInt64 = 0x434e_5004
}

/// The frozen QUIC baseline ALPN, read from the linked core
/// (`capnp_core_quic_alpn`).
public let capnpQUICALPN: String = {
    guard let cString = capnp_core_quic_alpn() else { return "capnp-rpc/1" }
    return String(cString: cString)
}()

@available(macOS 26.0, iOS 26.0, *)
public final class QUICTransport: Transport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let trust: TLSTrust
    private let connectTimeout: Duration
    private let idleTimeout: Duration
    private var connection: NetworkConnection<QUIC>?
    private var stream: QUIC.Stream<QUICStream>?
    private var queue: DispatchSerialQueue?
    private var delegate: (any TransportDelegate)?
    private var ready = false
    private var closed = false
    private var paused = false
    private var receiving = false
    private var receiveTask: Task<Void, Never>?
    private var buffered: [([UInt8], @Sendable () -> Void)] = []
    private var opening: CheckedContinuation<Void, any Error>?
    private var timeoutWork: DispatchWorkItem?

    /// `idleTimeout` must exceed any planned quiet period (the 90 s idle
    /// gate uses 120 s); the default matches the core's 30 s.
    public init(
        host: String,
        port: UInt16,
        trust: TLSTrust,
        connectTimeout: Duration = .seconds(10),
        idleTimeout: Duration = .seconds(30)
    ) {
        self.host = host
        self.port = port
        self.trust = trust
        self.connectTimeout = connectTimeout
        self.idleTimeout = idleTimeout
    }

    private func makeConnection() -> NetworkConnection<QUIC> {
        NetworkConnection<QUIC>(
            to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
            using: .init {
                var quic = QUIC(alpn: [capnpQUICALPN])
                quic = quic.idleTimeout(Int(idleTimeout.components.seconds) * 1000)
                switch self.trust {
                case .pinnedCertificates, .testOnlyTrustThisCertificate:
                    let verify = self.trust.verifyBlock()
                    quic = quic.tls.certificateValidator { _, secTrust in
                        verify(secTrust)
                    }
                }
                return quic
            })
    }

    public func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        self.queue = queue
        self.delegate = delegate
        let connection = makeConnection()
        self.connection = connection
        scheduleTimeout()
        connection.onStateUpdate { [weak self] _, state in
                guard let self else { return }
            switch state {
            case .ready:
                self.cancelTimeout()
                guard !self.ready, !self.closed else { return }
                self.ready = true
            case .failed(let error):
                self.cancelTimeout()
                self.fail(TCPTransport.ConnectError.failed("\(error)"))
            case .cancelled:
                self.cancelTimeout()
                self.fail(TCPTransport.ConnectError.cancelled)
            default:
                break
            }
        }
        // All channel setup funnels through the transport's queue, keeping
        // start(), the state callbacks, and streamReady() ordered.
        queue.async { _ = connection.start() }
        Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await connection.openStream()
                self.queue?.async { [weak self] in self?.streamReady(stream) }
            } catch {
                self.queue?.async { [weak self] in
                    self?.fail(TCPTransport.ConnectError.failed("\(error)"))
                }
            }
        }
    }

    private func streamReady(_ stream: QUIC.Stream<QUICStream>) {
        guard ready, !closed else { return }
        self.stream = stream
        if let opening {
            self.opening = nil
            opening.resume()
        }
        receiveLoop()
    }

    public func open() async throws {
        if ready, stream != nil { return }
        if closed { throw TCPTransport.ConnectError.cancelled }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue?.async { [weak self] in
                guard let self else { return continuation.resume(throwing: TCPTransport.ConnectError.cancelled) }
                if self.ready, self.stream != nil { return continuation.resume() }
                if self.closed { return continuation.resume(throwing: TCPTransport.ConnectError.cancelled) }
                self.opening = continuation
            }
        }
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !(ready || closed) else { return }
            self.fail(TCPTransport.ConnectError.timedOut(self.connectTimeout))
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
        qtrace("client send(\(bytes.count)) ready=\(ready) stream=\(stream != nil) paused=\(paused)")
        guard ready, !closed, let stream else {
            completion()
            return
        }
        if paused {
            buffered.append((bytes, completion))
            return
        }
        Task { [weak self] in
            guard let self else { return completion() }
            do {
                try await stream.send(Data(bytes))
                qtrace("client sent \(bytes.count)")
                self.queue?.async { completion() }
            } catch {
                self.queue?.async {
                    completion()
                    self.fail(TCPTransport.ConnectError.failed("\(error)"))
                }
            }
        }
    }

    public func pauseReceiving() {
        paused = true
    }

    public func resumeReceiving() {
        paused = false
        let held = buffered
        buffered.removeAll()
        for (bytes, completion) in held {
            send(bytes, completion: completion)
        }
        receiveLoop()
    }

    private func receiveLoop() {
        guard ready, !closed, !paused, !receiving, let stream else { return }
        receiving = true
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await stream.receive(atLeast: 1, atMost: 65536)
                let data = message.content
                qtrace("client received \(data.count)")
                self.queue?.async { [weak self] in
                    guard let self else { return }
                    self.receiving = false
                    if !data.isEmpty {
                        self.delegate?.transportDidReceive(Array(data))
                    }
                    self.receiveLoop()
                }
            } catch {
                self.queue?.async { [weak self] in
                    guard let self else { return }
                    self.receiving = false
                    if !self.closed {
                        self.fail(TCPTransport.ConnectError.failed("\(error)"))
                    }
                }
            }
        }
    }

    public func cancel() {
        guard !closed else { return }
        closed = true
        cancelTimeout()
        // The modern channels expose no public cancel(); the close is real
        // anyway: FIN on stream 0 (the baseline's RPC stream) tells the
        // peer the session is over, the pending receive is cancelled so it
        // stops holding the stream alive, and dropping our references lets
        // the channel deinit tear the QUIC connection down.
        let stream = self.stream
        let receiveTask = self.receiveTask
        if let queue {
            queue.async { [weak self] in
                if let stream {
                    Task {
                        try? await stream.send(Data(), endOfStream: true)
                        qtrace("client cancel(): FIN sent on stream 0")
                    }
                }
                receiveTask?.cancel()
                self?.connection = nil
                self?.stream = nil
                self?.delegate?.transportDidClose(error: nil)
            }
        } else {
            delegate?.transportDidClose(error: nil)
        }
    }

    private struct SecondaryStreamError: Error {
        let message: String
        static func receiveFailed(_ message: String) -> SecondaryStreamError {
            SecondaryStreamError(message: message)
        }
    }

    /// What `probeSecondaryStream()` observed on the extra stream.
    public struct SecondaryStreamProbe: Sendable {
        public let openThrew: Bool
        public let sendThrew: Bool
        public let receiveError: String?
        /// The stream's application error code after the reset, when this
        /// SDK surfaces it (capnp-zig resets unexpected streams with
        /// 0x434e5002 and keeps the connection up).
        public let applicationErrorCode: UInt64?
    }

    /// M6 gate: open a second bidirectional stream the baseline does not
    /// define, write a stray frame, and report how the peer refused it.
    /// Diagnostic only — never touches the RPC stream.
    public func probeSecondaryStream() async -> SecondaryStreamProbe {
        guard let connection else {
            return SecondaryStreamProbe(openThrew: true, sendThrew: false, receiveError: "no connection", applicationErrorCode: nil)
        }
        let stream: QUIC.Stream<QUICStream>
        do {
            stream = try await connection.openStream()
        } catch {
            return SecondaryStreamProbe(openThrew: true, sendThrew: false, receiveError: "\(error)", applicationErrorCode: nil)
        }
        var sendThrew = false
        do {
            try await stream.send(Data([0, 0, 0, 1]))
        } catch {
            sendThrew = true
        }
        // Race the receive against a timer: a silent peer (no reset, no
        // data) would otherwise suspend forever, and structured cancellation
        // cannot interrupt a Network.framework await.
        var receiveError: String?
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        _ = try await stream.receive(atLeast: 1, atMost: 65536)
                    } catch is CancellationError {
                    } catch {
                        qtrace("secondary stream receive error: \(error)")
                        throw SecondaryStreamError.receiveFailed("\(error)")
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                }
                do {
                    _ = try await group.next()
                } catch let error as SecondaryStreamError {
                    receiveError = error.message
                } catch {
                    // The timer won: the peer stayed silent on the stream.
                }
                group.cancelAll()
            }
        }
        return SecondaryStreamProbe(
            openThrew: false,
            sendThrew: sendThrew,
            receiveError: receiveError,
            applicationErrorCode: stream.streamApplicationErrorCode
        )
    }
}

/// One accepted QUIC stream as a `Transport` (the server side of the
/// baseline: the peer's stream 0).
@available(macOS 26.0, iOS 26.0, *)
final class QUICStreamTransport: Transport, @unchecked Sendable {
    private let stream: QUIC.Stream<QUICStream>
    private var queue: DispatchSerialQueue?
    private var delegate: (any TransportDelegate)?
    private var closed = false
    private var paused = false
    private var receiving = false
    private var receiveTask: Task<Void, Never>?
    private var buffered: [([UInt8], @Sendable () -> Void)] = []

    init(stream: QUIC.Stream<QUICStream>) {
        self.stream = stream
    }

    func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        self.queue = queue
        self.delegate = delegate
        receiveLoop()
    }

    func open() async throws {}

    func send(_ bytes: [UInt8], completion: @escaping @Sendable () -> Void) {
        guard !closed else {
            completion()
            return
        }
        if paused {
            buffered.append((bytes, completion))
            return
        }
        Task { [weak self] in
            guard let self else { return completion() }
            do {
                try await stream.send(Data(bytes))
                self.queue?.async { completion() }
            } catch {
                self.queue?.async {
                    completion()
                    self.close(with: error)
                }
            }
        }
    }

    func pauseReceiving() {
        paused = true
    }

    func resumeReceiving() {
        paused = false
        let held = buffered
        buffered.removeAll()
        for (bytes, completion) in held {
            send(bytes, completion: completion)
        }
        receiveLoop()
    }

    private func receiveLoop() {
        guard !closed, !paused, !receiving else { return }
        receiving = true
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await stream.receive(atLeast: 1, atMost: 65536)
                let data = message.content
                self.queue?.async { [weak self] in
                    guard let self else { return }
                    self.receiving = false
                    if !data.isEmpty {
                        self.delegate?.transportDidReceive(Array(data))
                    }
                    self.receiveLoop()
                }
            } catch {
                self.queue?.async { [weak self] in
                    guard let self else { return }
                    self.receiving = false
                    self.close(with: error)
                }
            }
        }
    }

    func cancel() {
        close(with: nil)
    }

    private func close(with error: (any Error)?) {
        guard !closed else { return }
        closed = true
        // FIN the stream: without it the peer sits on an open stream until
        // its idle timeout, and the caller's open questions end as
        // deadlines instead of disconnects (found by the zig e2e client's
        // disconnectNow check over QUIC, 2026-10-08).
        // Cancel the pending receive too: the suspended receive holds the
        // stream, the stream holds its parent connection, and a live
        // connection never sends the close the peer needs (the zig e2e
        // client's disconnectNow ends as CallTimedOut instead; 2026-10-08).
        receiveTask?.cancel()
        Task { [stream] in
            try? await stream.send(Data(), endOfStream: true)
            qtrace("server stream FIN sent")
        }
        // Deferred for the same reason as QUICTransport.cancel().
        let nsError = error.map { $0 as NSError }
        if let queue {
            queue.async { [weak self] in self?.delegate?.transportDidClose(error: nsError) }
        } else {
            delegate?.transportDidClose(error: nsError)
        }
    }
}

/// A QUIC listener: `start()` resolves with the bound UDP port once
/// listening; each accepted connection gets its own `RPCConnection`
/// (`.u32LE` framing) serving the app's bootstrap.
@available(macOS 26.0, iOS 26.0, *)
public final class QUICListener: @unchecked Sendable {
    private let listener: NetworkListener<QUIC>
    private let bootstrap: @Sendable () -> any ExportHandler
    private let options: RPCConnection.Options
    private let state = NSLock()
    private var readyContinuation: CheckedContinuation<UInt16, any Error>?
    private var cancelled = false

    /// Serve QUIC presenting `identity` (clients pin its certificate or
    /// trust the test certificate). The idle timeout is long enough for the
    /// 90 s idle gate.
    public init(
        port: UInt16,
        identity: TLSIdentity,
        bootstrap: @escaping @Sendable () -> any ExportHandler,
        options: RPCConnection.Options = .init()
    ) {
        self.bootstrap = bootstrap
        var framed = options
        framed.framing = .u32LE
        self.options = framed

        let listener: NetworkListener<QUIC>
        do {
            var quic = QUIC(alpn: [capnpQUICALPN])
            quic = quic.idleTimeout(120_000)
            if let secIdentity = sec_identity_create(identity.identity) {
                quic = quic.tls.localIdentity(secIdentity)
            }
            // Built outside the result-builder closure: a multi-statement
            // body there crashes this Swift (rdar-worthy, 2026-10-08).
            let builder = NWParametersBuilder.parameters { quic }
            // Bind the requested port: without an explicit localPort the
            // listener silently picks an ephemeral one (anything but port 0
            // dialed the wrong port; found by the 5-schema matrix,
            // 2026-10-08). requiredLocalEndpoint is ignored by the modern
            // listener; localPort is its spelling.
            var bound = builder
            if port != 0 {
                bound = builder.localPort(NWEndpoint.Port(rawValue: port)!)
            }
            listener = try NetworkListener<QUIC>(using: bound)
        } catch {
            // The builder path is infallible for QUIC (no provider); keep
            // the throwing shape anyway for source stability.
            fatalError("NetworkListener<QUIC> init failed: \(error)")
        }
        self.listener = listener
    }

    /// Start listening; resolves with the bound port.
    public func start() async throws -> UInt16 {
        listener.onStateUpdate { [weak self] listener, state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                self.state.lock()
                let waiter = self.readyContinuation
                self.readyContinuation = nil
                self.state.unlock()
                waiter?.resume(returning: port)
                self.serve()
            case .failed(let error):
                self.state.lock()
                let waiter = self.readyContinuation
                self.readyContinuation = nil
                self.state.unlock()
                waiter?.resume(throwing: RPCListener.ListenError.failed(String(describing: error)))
            default:
                break
            }
        }
        // The modern listener has no start(): `run` both starts serving
        // and pumps accepts. Serve from a task; .ready (with the bound
        // port) arrives through onStateUpdate once run warms up.
        serve()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            state.lock()
            readyContinuation = continuation
            state.unlock()
        }
    }

    /// Stop accepting. In-flight connections finish on their own.
    public func cancel() {
        state.lock()
        cancelled = true
        state.unlock()
    }

    private func serve() {
        Task { [weak self] in
            guard let self else { return }
            while !self.cancelled {
                do {
                    try await self.listener.run { [weak self] connection in
                        guard let self else { return }
                        await self.accept(connection)
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func accept(_ connection: NetworkConnection<QUIC>) async {
        // Started inline, before inboundStreams is attached, so the
        // peer's first stream cannot race the start.
        _ = connection.start()
        do {
            // Baseline: one RPC stream per connection (the client's
            // stream 0); the connection ends when the app drops it.
            try await connection.inboundStreams { [weak self] stream in
                qtrace("server inbound stream id=\(stream.streamID)")
                guard let self else { return }
                let transport = QUICStreamTransport(stream: stream)
                let handler = self.bootstrap()
                guard let rpc = try? RPCConnection(transport: transport, bootstrap: handler, options: self.options) else { return }
                do {
                    try await rpc.start()
                } catch {}
                _ = await rpc.waitClosed()
            }
        } catch {
            // The listener stopped or the connection failed during its
            // handshake; both end the accept quietly.
        }
    }
}
