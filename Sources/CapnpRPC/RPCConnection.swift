internal import CapnpCore
import Capnp
import Dispatch
import os

/// One RPC connection (plan §5): an actor whose executor is a
/// `DispatchSerialQueue` shared with its transport, so transport callbacks
/// drain the core's effects synchronously (`assumeIsolated`), without an
/// actor hop per frame (proved by `ExecutorProbe`).
///
/// Flow: every call into the core (`push_bytes`, `tick`, `call`, ...) is
/// followed by a non-async `drain()` that pulls every queued effect and acts
/// on it: `OUT_FRAME` -> `transport.send` (in order), `RETURN` -> resume the
/// caller, `INBOUND_CALL` -> run the export's handler in a Task and answer,
/// `CLOSE_REQUESTED` -> `transport.cancel()`. When the transport reports its
/// end, the core ends every open question with `RETURN DISCONNECTED`.
public actor RPCConnection: TransportDelegate {
    public struct Options: Sendable {
        /// Deadline of every outbound call (`default_call_timeout_ms`); nil
        /// for none.
        public var callTimeout: Duration? = nil
        /// How often the core's clock advances (deadlines fire on a tick).
        public var tickInterval: Duration = .milliseconds(100)
        /// `max_retained_questions`; 0 keeps the core default (1024).
        public var maxRetainedQuestions: UInt32 = 0

        public init() {}
    }

    private struct Export {
        let handler: any ExportHandler
        let id: UInt32
    }

    /// Owns the `capnp_conn*`. A class so the actor's nonisolated `deinit`
    /// needs no access to a non-Sendable pointer: the box frees the core when
    /// the actor (its only owner) goes away.
    private final class CoreBox: @unchecked Sendable {
        let raw: OpaquePointer

        init(_ raw: OpaquePointer) { self.raw = raw }

        deinit { capnp_conn_free(raw) }
    }

    private nonisolated let executor: QueueExecutor

    /// The actor's executor queue and the transport's callback queue.
    public nonisolated var queue: DispatchSerialQueue { executor.queue }

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private let core: CoreBox
    private let transport: any Transport
    private let options: Options
    private let bootstrapHandler: (any ExportHandler)?
    private let releases = ReleaseList()
    private var pending: [UInt32: CheckedContinuation<CallResult, any Error>] = [:]
    /// Bootstrap questions: the core finishes them itself (plan §4.1).
    private var bootstrapQIDs: Set<UInt32> = []
    private var exports: [UInt64: Export] = [:]
    private var nextHostTag: UInt64 = 1
    private var timer: DispatchSourceTimer?
    private var started = false
    private var transportIsClosed = false
    private var closeReason: RPCError?
    private var closeWaiters: [UInt64: CheckedContinuation<RPCError, Never>] = [:]
    private var nextWaiterKey: UInt64 = 0

    private static let logger = Logger(subsystem: "capnp-swift", category: "RPCConnection")

    /// Creates the core connection. Call `start()` next (or use `connect`).
    /// `bootstrap` is the object the remote gets from its Bootstrap.
    public init(transport: any Transport, bootstrap: (any ExportHandler)? = nil, options: Options = Options()) throws {
        executor = QueueExecutor(label: "capnp-swift.connection")
        self.transport = transport
        self.options = options
        bootstrapHandler = bootstrap

        var opts = capnp_conn_opts()
        opts.struct_size = UInt32(MemoryLayout<capnp_conn_opts>.size)
        opts.framing = UInt8(CAPNP_FRAMING_SEGMENT_TABLE)
        if let timeout = options.callTimeout {
            opts.default_call_timeout_ms = UInt32(clamping: Self.milliseconds(timeout))
        }
        opts.max_retained_questions = options.maxRetainedQuestions
        var out: OpaquePointer? = nil
        let rc = capnp_conn_new(&opts, Self.now(), &out)
        guard rc == CAPNP_OK, let created = out else {
            throw RPCError.core(code: rc, operation: "capnp_conn_new")
        }
        core = CoreBox(created)
    }

    deinit {
        timer?.cancel()
    }

    /// Create, start and wait until the transport is open.
    public static func connect(
        transport: any Transport,
        bootstrap: (any ExportHandler)? = nil,
        options: Options = Options()
    ) async throws -> RPCConnection {
        let connection = try RPCConnection(transport: transport, bootstrap: bootstrap, options: options)
        try await connection.start()
        return connection
    }

    /// Export the bootstrap object, start the transport and the tick timer,
    /// and wait until bytes can flow. A connect failure throws
    /// `.disconnected`.
    public func start() async throws {
        precondition(!started, "RPCConnection.start called twice")
        started = true
        releases.attach(self)
        if let bootstrapHandler {
            let tag = nextHostTag
            nextHostTag += 1
            var id: UInt32 = 0
            let rc = capnp_set_bootstrap(core.raw, tag, &id)
            guard rc == CAPNP_OK else { throw RPCError.core(code: rc, operation: "capnp_set_bootstrap") }
            exports[tag] = Export(handler: bootstrapHandler, id: id)
        }
        transport.start(queue: queue, delegate: self)
        startTimer()
        do {
            try await transport.open()
        } catch {
            if closeReason == nil { closeReason = .disconnected(reason: "connect failed: \(error)") }
            throw closeReason ?? .closed
        }
    }

    // MARK: Client side

    /// The remote's bootstrap capability.
    public func bootstrap() async throws -> CapRef {
        guard !transportIsClosed else { throw closeReason ?? .closed }
        var qid: UInt32 = 0
        let rc = capnp_bootstrap(core.raw, &qid)
        guard rc == CAPNP_OK else {
            drain()
            throw RPCError.core(code: rc, operation: "capnp_bootstrap")
        }
        bootstrapQIDs.insert(qid)
        let result = try await awaitReturn(of: qid)
        let message: Message
        do {
            message = try Message(bytes: result.message)
        } catch {
            throw RPCError.malformed("\(error)")
        }
        guard let index = try? message.rootCapabilityIndex(),
            Int(index) < result.caps.count,
            case .imported(let ref) = result.caps[Int(index)]
        else {
            throw RPCError.failed(reason: "bootstrap returned no capability")
        }
        return ref
    }

    /// Call `method` of `interface` on `target`. `params` is a standalone
    /// message whose root is the params struct; its capability pointers
    /// index `caps`. Returns the results, or throws the remote exception
    /// (`RPCError.failed` etc.), `.canceled`, or `.disconnected`.
    public func call(
        _ target: CapRef,
        interface: UInt64,
        method: UInt16,
        params: [UInt8],
        caps: [CapSlot] = []
    ) async throws -> CallResult {
        guard !transportIsClosed else { throw closeReason ?? .closed }
        guard target.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
        let table = try encodeSlots(caps)
        var qid: UInt32 = 0
        let rc = params.withUnsafeBufferPointer { p in
            table.withUnsafeBufferPointer { t in
                capnp_call(
                    core.raw, capnp_cap(kind: UInt8(CAPNP_CAP_IMPORT), id: target.id), interface, method,
                    p.baseAddress, p.count, t.baseAddress, t.count, 0, &qid)
            }
        }
        guard rc == CAPNP_OK else {
            drain()
            throw RPCError.core(code: rc, operation: "capnp_call")
        }
        return try await awaitReturn(of: qid)
    }

    /// Suspend until question `qid` returns. If the calling task is cancelled
    /// first, the caller gets `.canceled` at once; the question stays open in
    /// the core and is finished when its RETURN arrives (a wire Cancel is M2).
    private func awaitReturn(of qid: UInt32) async throws -> CallResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CallResult, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: RPCError.canceled)
                    return
                }
                pending[qid] = continuation
                drain()
            }
        } onCancel: {
            Task { await self.abandon(qid) }
        }
    }

    /// The caller of `qid` gave up (task cancellation).
    private func abandon(_ qid: UInt32) {
        if let continuation = pending.removeValue(forKey: qid) {
            continuation.resume(throwing: RPCError.canceled)
        }
    }

    // MARK: Lifecycle

    /// Close the transport. Every pending call ends with `.disconnected`.
    public func close() {
        guard !transportIsClosed else { return }
        if closeReason == nil { closeReason = .disconnected(reason: "closed locally") }
        transport.cancel()
    }

    public var isClosed: Bool { transportIsClosed }

    /// Why the connection closed (nil while it is open).
    public var closeCause: RPCError? { transportIsClosed ? closeReason : nil }

    /// Suspends until the connection has closed; returns the cause
    /// (`.canceled` if the waiting task is cancelled first).
    public func waitClosed() async -> RPCError {
        if transportIsClosed { return closeReason ?? .closed }
        let key = nextWaiterKey
        nextWaiterKey += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RPCError, Never>) in
                if transportIsClosed {
                    continuation.resume(returning: closeReason ?? .closed)
                } else if Task.isCancelled {
                    continuation.resume(returning: .canceled)
                } else {
                    closeWaiters[key] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCloseWaiter(key) }
        }
    }

    private func cancelCloseWaiter(_ key: UInt64) {
        if let continuation = closeWaiters.removeValue(forKey: key) {
            continuation.resume(returning: .canceled)
        }
    }

    // MARK: TransportDelegate (on the queue, isolated through assumeIsolated)

    public nonisolated func transportDidReceive(_ bytes: [UInt8]) {
        assumeIsolated { me in me.receive(bytes) }
    }

    public nonisolated func transportDidClose(error: (any Error)?) {
        assumeIsolated { me in me.handleTransportClosed(error) }
    }

    // MARK: Internals

    private func receive(_ bytes: [UInt8]) {
        guard !transportIsClosed else { return }
        let rc = bytes.withUnsafeBufferPointer { capnp_conn_push_bytes(core.raw, $0.baseAddress, $0.count) }
        if rc != CAPNP_OK { recordCoreError(rc) }
        drain()
    }

    /// After a failed `push_bytes`: keep the cause as the close reason.
    private func recordCoreError(_ rc: Int32) {
        var code: Int32 = 0
        var name: UnsafePointer<CChar>? = nil
        var nameLen = 0
        var detail: UnsafePointer<CChar>? = nil
        var detailLen = 0
        if capnp_conn_take_error(core.raw, &code, &name, &nameLen, &detail, &detailLen) == 1 {
            let cause = Self.string(name, nameLen)
            let text = Self.string(detail, detailLen)
            if closeReason == nil {
                closeReason = code == CAPNP_E_PROTOCOL
                    ? .failed(reason: "protocol error: \(cause)")
                    : .disconnected(reason: text.isEmpty ? cause : text)
            }
        } else if closeReason == nil, rc == CAPNP_E_CLOSED {
            closeReason = .disconnected(reason: "connection closed")
        }
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let nanos = Int(clamping: Self.nanoseconds(options.tickInterval))
        source.schedule(deadline: .now() + .nanoseconds(nanos), repeating: .nanoseconds(nanos))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.assumeIsolated { me in me.tick() }
        }
        source.resume()
        timer = source
    }

    private func tick() {
        guard !transportIsClosed else { return }
        _ = capnp_conn_tick(core.raw, Self.now())
        drain()
        flushReleases()
    }

    /// Send Release for every `CapRef` dropped since the last flush.
    func flushReleases() {
        let ids = releases.take()
        guard !transportIsClosed else { return }
        guard !ids.isEmpty else { return }
        for id in ids { _ = capnp_release(core.raw, id, 1) }
        drain()
    }

    /// Pull and act on every queued effect. Never async: it runs inside the
    /// transport callback or the actor method that produced the effects.
    private func drain() {
        while true {
            var effect = capnp_effect()
            effect.struct_size = UInt32(MemoryLayout<capnp_effect>.size)
            let rc = capnp_conn_next_effect(core.raw, &effect)
            if rc == 0 { return }
            precondition(rc == 1, "capnp_conn_next_effect returned \(rc)")
            handle(effect)
            capnp_conn_commit_effect(core.raw)
        }
    }

    private func handle(_ e: capnp_effect) {
        switch Int32(e.kind) {
        case CAPNP_EFFECT_OUT_FRAME:
            transport.send(Self.bytes(e.msg, e.msg_len))
        case CAPNP_EFFECT_CLOSE_REQUESTED:
            if closeReason == nil { closeReason = .disconnected(reason: "closed by the core") }
            transport.cancel()
        case CAPNP_EFFECT_RETURN:
            handleReturn(e)
        case CAPNP_EFFECT_INBOUND_CALL:
            handleInboundCall(e)
        case CAPNP_EFFECT_EXPORT_DROPPED:
            exports.removeValue(forKey: e.host_tag)
        default:
            break  // EVENT: not surfaced in M1
        }
    }

    private func handleReturn(_ e: capnp_effect) {
        let qid = e.id
        let isBootstrap = bootstrapQIDs.remove(qid) != nil
        let continuation = pending.removeValue(forKey: qid)
        switch Int32(e.return_kind) {
        case CAPNP_RETURN_RESULTS:
            let result = CallResult(message: Self.bytes(e.msg, e.msg_len), caps: capTable(e.caps, e.ncaps))
            continuation?.resume(returning: result)
        case CAPNP_RETURN_EXCEPTION:
            continuation?.resume(throwing: RPCError.remote(type: e.exception_type, reason: Self.string(e.reason, e.reason_len)))
        case CAPNP_RETURN_CANCELED:
            continuation?.resume(throwing: RPCError.canceled)
        default:
            continuation?.resume(throwing: RPCError.disconnected(reason: Self.string(e.reason, e.reason_len)))
        }
        // M1 has no pipelining, so nothing else can use the question: finish
        // it now. Never the bootstrap question (plan §4.1). A question a
        // deadline already ended answers BAD_ID; a closed connection is a
        // no-op; both are fine to ignore.
        if !isBootstrap { _ = capnp_finish(core.raw, qid, 0) }
    }

    private func handleInboundCall(_ e: capnp_effect) {
        let answerID = e.id
        guard let export = exports[e.host_tag] else {
            sendException(answerID, (3, "capnp-swift: no such export"))
            return
        }
        let call = InboundCall(
            interfaceID: e.interface_id,
            methodID: e.method_id,
            params: Self.bytes(e.msg, e.msg_len),
            caps: capTable(e.caps, e.ncaps),
            connection: self)
        let handler = export.handler
        // Inherits the actor's isolation: `complete` is a direct call. Handler
        // start order across calls is M2's E-order work.
        Task {
            let outcome: Result<CallResponse, any Error>
            do {
                outcome = .success(try await handler.handle(call))
            } catch {
                outcome = .failure(error)
            }
            self.complete(answerID: answerID, outcome)
        }
    }

    private func complete(answerID: UInt32, _ outcome: Result<CallResponse, any Error>) {
        guard !transportIsClosed else { return }
        switch outcome {
        case .success(let response):
            do {
                let table = try encodeSlots(response.caps)
                let rc = response.message.withUnsafeBufferPointer { m in
                    table.withUnsafeBufferPointer { t in
                        capnp_return_results(core.raw, answerID, m.baseAddress, m.count, t.baseAddress, t.count)
                    }
                }
                if rc != CAPNP_OK, rc != CAPNP_E_BAD_ID {
                    sendException(answerID, (0, "capnp-swift: results refused (\(rc))"))
                }
            } catch {
                sendException(answerID, RPCError.wire(for: error))
            }
        case .failure(let error):
            if !(error is RPCError) {
                Self.logger.error("export handler failed: \(String(describing: error), privacy: .public)")
            }
            sendException(answerID, RPCError.wire(for: error))
        }
        drain()
    }

    private func sendException(_ answerID: UInt32, _ wire: (type: UInt16, reason: String)) {
        var reason = Array(wire.reason.utf8)
        _ = reason.withUnsafeMutableBufferPointer { r in
            r.baseAddress!.withMemoryRebound(to: CChar.self, capacity: r.count) { p in
                capnp_return_exception(core.raw, answerID, wire.type, p, r.count)
            }
        }
    }

    private func encodeSlots(_ slots: [CapSlot]) throws -> [capnp_cap] {
        var table: [capnp_cap] = []
        table.reserveCapacity(slots.count)
        for slot in slots {
            switch slot {
            case .none:
                table.append(capnp_cap(kind: UInt8(CAPNP_CAP_NONE), id: 0))
            case .imported(let ref):
                guard ref.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
                table.append(capnp_cap(kind: UInt8(CAPNP_CAP_IMPORT), id: ref.id))
            case .export(let handler):
                table.append(capnp_cap(kind: UInt8(CAPNP_CAP_EXPORT), id: try exportHandler(handler)))
            }
        }
        return table
    }

    private func exportHandler(_ handler: any ExportHandler) throws -> UInt32 {
        let tag = nextHostTag
        nextHostTag += 1
        var id: UInt32 = 0
        let rc = capnp_export(core.raw, tag, &id)
        guard rc == CAPNP_OK else { throw RPCError.core(code: rc, operation: "capnp_export") }
        exports[tag] = Export(handler: handler, id: id)
        return id
    }

    private func capTable(_ caps: UnsafePointer<capnp_cap>?, _ count: Int) -> [CapTableEntry] {
        guard let caps, count > 0 else { return [] }
        var out: [CapTableEntry] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let cap = caps[i]
            switch Int32(cap.kind) {
            case CAPNP_CAP_IMPORT:
                out.append(.imported(CapRef(id: cap.id, releases: releases, owner: ObjectIdentifier(self))))
            case CAPNP_CAP_EXPORT:
                out.append(.exported(cap.id))
            default:
                out.append(.none)
            }
        }
        return out
    }

    private func handleTransportClosed(_ error: (any Error)?) {
        guard !transportIsClosed else { return }
        transportIsClosed = true
        if closeReason == nil {
            closeReason = .disconnected(reason: error.map { "transport failed: \($0)" } ?? "transport closed")
        }
        timer?.cancel()
        timer = nil
        // Ends every open question with RETURN DISCONNECTED (drained here).
        capnp_conn_transport_closed(core.raw)
        drain()
        let cause = closeReason ?? .closed
        for (_, continuation) in pending { continuation.resume(throwing: cause) }
        pending.removeAll()
        bootstrapQIDs.removeAll()
        exports.removeAll()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resume(returning: cause) }
    }

    // MARK: Helpers

    /// The core's clock: `DispatchTime` uptime nanoseconds (plan §5).
    static func now() -> Int64 {
        Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
    }

    static func nanoseconds(_ d: Duration) -> Int64 {
        let c = d.components
        return c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
    }

    static func milliseconds(_ d: Duration) -> Int64 {
        nanoseconds(d) / 1_000_000
    }

    static func bytes(_ p: UnsafePointer<UInt8>?, _ len: Int) -> [UInt8] {
        guard let p, len > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: len))
    }

    static func string(_ p: UnsafePointer<CChar>?, _ len: Int) -> String {
        guard let p, len > 0 else { return "" }
        return p.withMemoryRebound(to: UInt8.self, capacity: len) {
            String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
        }
    }
}
