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
/// on it: `OUT_FRAME` -> `transport.send` (in order), `RETURN` -> store the
/// result and resume waiters, `INBOUND_CALL` -> run the export's handler in a
/// Task started on this actor (E-order), `CLOSE_REQUESTED` -> `cancel`,
/// `EXPORT_DROPPED` -> drop the handler, `EVENT` -> `events`. When the
/// transport reports its end, the core ends every open question with
/// `RETURN DISCONNECTED`.
public actor RPCConnection: TransportDelegate {
    public struct Options: Sendable {
        /// Deadline of every outbound call (`default_call_timeout_ms`); nil
        /// for none.
        public var callTimeout: Duration? = nil
        /// How often the core's clock advances (deadlines and the shutdown
        /// drain fire on a tick).
        public var tickInterval: Duration = .milliseconds(100)
        /// `shutdown()` waits this long for open questions before ending them.
        public var shutdownDrainTimeout: Duration = .seconds(5)
        /// `max_retained_questions`; 0 keeps the core default (1024).
        public var maxRetainedQuestions: UInt32 = 0
        /// Queue EVENT effects into `events`.
        public var observeEvents = false
        /// Inbound backpressure (plan §5): stop reading above this many
        /// in-flight inbound handlers, or this many bytes of their params.
        public var inboundHighWaterCalls = 64
        public var inboundHighWaterBytes = 8 << 20
        /// Outbound backpressure: `send` suspends while this many bytes sit
        /// between `transport.send` and its completion.
        public var outboundHighWaterBytes = 8 << 20

        public init() {}
    }

    private struct Export {
        let handler: any ExportHandler
        let id: UInt32
    }

    /// A question this host asked (bootstrap or call).
    private struct Question {
        var result: CallResult?
        var failure: RPCError?
        var waiters: [CheckedContinuation<CallResult, any Error>] = []
        var returned = false
        var handlesDropped = false
        /// The core finishes bootstrap questions itself (plan §4.1).
        var isBootstrap = false
        /// `RETURN CANCELED` arrived (the core already sent Finish).
        var canceled = false
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
    private var questions: [UInt32: Question] = [:]
    private var exports: [UInt64: Export] = [:]
    private var nextHostTag: UInt64 = 1
    private var timer: DispatchSourceTimer?
    private var started = false
    private var transportIsClosed = false
    private var closeReason: RPCError?
    private var closeWaiters: [UInt64: CheckedContinuation<RPCError, Never>] = [:]
    private var nextWaiterKey: UInt64 = 0
    // Backpressure.
    private var inboundInFlight = 0
    private var inboundBytes = 0
    private var receivePaused = false
    private var outboundBytes = 0
    private var outboundWaiters: [CheckedContinuation<Void, Never>] = []
    // Events.
    private let eventStream: AsyncStream<RPCEvent>
    private let eventContinuation: AsyncStream<RPCEvent>.Continuation

    private static let logger = Logger(subsystem: "capnp-swift", category: "RPCConnection")

    /// Creates the core connection. Call `start()` next (or use `connect`).
    /// `bootstrap` is the object the remote gets from its Bootstrap.
    public init(transport: any Transport, bootstrap: (any ExportHandler)? = nil, options: Options = Options()) throws {
        executor = QueueExecutor(label: "capnp-swift.connection")
        self.transport = transport
        self.options = options
        bootstrapHandler = bootstrap
        (eventStream, eventContinuation) = AsyncStream<RPCEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))

        var opts = capnp_conn_opts()
        opts.struct_size = UInt32(MemoryLayout<capnp_conn_opts>.size)
        opts.framing = UInt8(CAPNP_FRAMING_SEGMENT_TABLE)
        opts.observer = options.observeEvents ? 1 : 0
        if let timeout = options.callTimeout {
            opts.default_call_timeout_ms = UInt32(clamping: Self.milliseconds(timeout))
        }
        opts.shutdown_drain_timeout_ms = UInt32(clamping: max(1, Self.milliseconds(options.shutdownDrainTimeout)))
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
        eventContinuation.finish()
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
        questions[qid] = Question(isBootstrap: true)
        drain()
        let result = try await awaitReturn(of: qid)
        questions.removeValue(forKey: qid)
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

    /// Send a call: `method` of `interface` on `target`. `params` is a
    /// standalone message whose root is the params struct; its capability
    /// pointers index `caps`. Returns at once with the promise of the RETURN
    /// (pipeline on it, or `await` its `result()`). Suspends only for
    /// outbound backpressure.
    public func send(
        _ target: CallTarget,
        interface: UInt64,
        method: UInt16,
        params: [UInt8],
        caps: [CapSlot] = []
    ) async throws -> RemotePromise {
        guard !transportIsClosed else { throw closeReason ?? .closed }
        await waitForOutboundWindow()
        guard !transportIsClosed else { throw closeReason ?? .closed }
        // A pipelined capability inside the params would reach a capnp-zig
        // callee as an unresolved receiverAnswer, which it refuses (handoff
        // H9). Wait for its question first and pass the resolved import.
        for slot in caps {
            if case .pipelined(let pipelined) = slot {
                guard pipelined.lifetime.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
                _ = try await awaitReturn(of: pipelined.lifetime.qid)
            }
        }
        let rawTarget = try resolveTarget(target)
        let encoded = try encodeSlots(caps)
        defer { encoded.release() }
        var qid: UInt32 = 0
        let rc = params.withUnsafeBufferPointer { p in
            encoded.table.withUnsafeBufferPointer { t in
                rawTarget.path.withUnsafeBufferPointer { ops in
                    var cap = rawTarget.cap
                    if !ops.isEmpty {
                        cap.ops = ops.baseAddress
                        cap.nops = UInt16(ops.count)
                    }
                    return capnp_call(core.raw, cap, interface, method, p.baseAddress, p.count, t.baseAddress, t.count, 0, &qid)
                }
            }
        }
        guard rc == CAPNP_OK else {
            drain()
            throw RPCError.core(code: rc, operation: "capnp_call")
        }
        questions[qid] = Question()
        let promise = RemotePromise(lifetime: QuestionLifetime(qid: qid, releases: releases, owner: ObjectIdentifier(self)), connection: self)
        drain()
        return promise
    }

    /// `send` and await the RETURN.
    public func call(
        _ target: CallTarget,
        interface: UInt64,
        method: UInt16,
        params: [UInt8],
        caps: [CapSlot] = []
    ) async throws -> CallResult {
        let promise = try await send(target, interface: interface, method: method, params: params, caps: caps)
        return try await promise.result()
    }

    /// `call` on an imported capability.
    public func call(
        _ target: CapRef,
        interface: UInt64,
        method: UInt16,
        params: [UInt8],
        caps: [CapSlot] = []
    ) async throws -> CallResult {
        try await call(.cap(target), interface: interface, method: method, params: params, caps: caps)
    }

    /// The RETURN of `promise`'s question (`RemotePromise.result`).
    func awaitResult(of promise: RemotePromise) async throws -> CallResult {
        guard promise.lifetime.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
        return try await awaitReturn(of: promise.lifetime.qid)
    }

    // MARK: Server side

    /// The handler behind one of this connection's exports (a cap table entry
    /// `.exported(id)`: a capability of ours came back to us). Nil once the
    /// remote released it.
    public func localHandler(forExport id: UInt32) -> (any ExportHandler)? {
        exports.values.first { $0.id == id }?.handler
    }

    /// Export a promise the remote can call now and this side resolves later.
    public func makePromise() throws -> PromiseExport {
        guard !transportIsClosed else { throw closeReason ?? .closed }
        var id: UInt32 = 0
        let rc = capnp_promise_export(core.raw, &id)
        guard rc == CAPNP_OK else { throw RPCError.core(code: rc, operation: "capnp_promise_export") }
        return PromiseExport(id: id, owner: ObjectIdentifier(self))
    }

    /// Resolve `promise` to a capability: an import this side holds, or a new
    /// export of `handler`. Once per promise.
    public func resolve(_ promise: PromiseExport, to slot: CapSlot) throws {
        guard promise.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
        guard !transportIsClosed else { return }
        let target: capnp_cap
        switch slot {
        case .imported(let ref):
            guard ref.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
            target = capnp_cap(kind: UInt8(CAPNP_CAP_IMPORT), id: ref.id, ops: nil, nops: 0)
        case .export(let handler):
            target = capnp_cap(kind: UInt8(CAPNP_CAP_EXPORT), id: try exportHandler(handler), ops: nil, nops: 0)
        case .promise(let other):
            guard other.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
            target = capnp_cap(kind: UInt8(CAPNP_CAP_EXPORT), id: other.id, ops: nil, nops: 0)
        case .none, .pipelined:
            throw RPCError.core(code: CAPNP_E_INVAL, operation: "resolve: unsupported target")
        }
        let rc = capnp_resolve_promise(core.raw, promise.id, target)
        guard rc == CAPNP_OK else { throw RPCError.core(code: rc, operation: "capnp_resolve_promise") }
        drain()
    }

    /// Reject `promise`: its callers get `RPCError.failed(reason)`.
    public func reject(_ promise: PromiseExport, reason: String) throws {
        guard promise.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
        guard !transportIsClosed else { return }
        var text = Array(reason.utf8)
        let rc = text.withUnsafeMutableBufferPointer { r -> Int32 in
            guard let base = r.baseAddress else { return capnp_reject_promise(core.raw, promise.id, nil, 0) }
            return base.withMemoryRebound(to: CChar.self, capacity: r.count) { capnp_reject_promise(core.raw, promise.id, $0, r.count) }
        }
        guard rc == CAPNP_OK else { throw RPCError.core(code: rc, operation: "capnp_reject_promise") }
        drain()
    }

    // MARK: Lifecycle

    /// Close the transport now. Every pending call ends with `.disconnected`.
    public func close() {
        guard !transportIsClosed else { return }
        if closeReason == nil { closeReason = .disconnected(reason: "closed locally") }
        transport.cancel()
    }

    /// Graceful shutdown (plan §5): no new calls; open questions may return
    /// until `Options.shutdownDrainTimeout`; then the connection closes.
    /// Returns the close cause.
    public func shutdown() async -> RPCError {
        if transportIsClosed { return closeReason ?? .closed }
        if closeReason == nil { closeReason = .disconnected(reason: "shut down") }
        capnp_conn_shutdown(core.raw)
        drain()
        return await waitClosed()
    }

    public var isClosed: Bool { transportIsClosed }

    /// Why the connection closed (nil while it is open).
    public var closeCause: RPCError? { transportIsClosed ? closeReason : nil }

    /// Peer observer events, when `Options.observeEvents` is on.
    public nonisolated var events: AsyncStream<RPCEvent> { eventStream }

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

    // MARK: Questions

    /// Suspend until question `qid` returns. Cancelling the task cancels the
    /// question on the wire (`capnp_cancel`): the caller gets `.canceled`.
    private func awaitReturn(of qid: UInt32) async throws -> CallResult {
        if let q = questions[qid], q.returned {
            if let result = q.result { return result }
            throw q.failure ?? .closed
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CallResult, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: RPCError.canceled)
                    cancelQuestion(qid)
                    return
                }
                guard var q = questions[qid] else {
                    continuation.resume(throwing: closeReason ?? .closed)
                    return
                }
                if q.returned {
                    if let result = q.result { continuation.resume(returning: result) } else { continuation.resume(throwing: q.failure ?? .closed) }
                    return
                }
                q.waiters.append(continuation)
                questions[qid] = q
            }
        } onCancel: {
            Task { await self.cancelQuestion(qid) }
        }
    }

    /// Cancel an open question on the wire; its waiters get `.canceled`
    /// through the RETURN CANCELED the core synthesizes.
    private func cancelQuestion(_ qid: UInt32) {
        guard let q = questions[qid], !q.returned, !transportIsClosed else { return }
        _ = capnp_cancel(core.raw, qid)
        drain()
    }

    /// The last `RemotePromise` / `PipelinedCap` of `qid` is gone.
    private func questionDropped(_ qid: UInt32) {
        guard var q = questions[qid] else { return }
        q.handlesDropped = true
        if q.returned {
            finishIfDue(qid, q)
        } else {
            questions[qid] = q
            if !transportIsClosed {
                _ = capnp_cancel(core.raw, qid)
                drain()
            }
        }
    }

    /// Finish a returned question once nothing can use it any more.
    private func finishIfDue(_ qid: UInt32, _ q: Question) {
        guard q.returned, q.handlesDropped, q.waiters.isEmpty else {
            questions[qid] = q
            return
        }
        questions.removeValue(forKey: qid)
        // A cancelled question is already gone in the core; bootstrap
        // questions are finished by the core (plan §4.1); after close finish
        // is a no-op.
        if !q.canceled, !q.isBootstrap, !transportIsClosed {
            _ = capnp_finish(core.raw, qid, 0)
            drain()
        }
    }

    /// The core-level target for a call: an IMPORT, or a PROMISED question
    /// with a path; a pipelined cap whose question already returned resolves
    /// here, from the stored results.
    private func resolveTarget(_ target: CallTarget) throws -> (cap: capnp_cap, path: [UInt16]) {
        switch target {
        case .cap(let ref):
            guard ref.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
            return (capnp_cap(kind: UInt8(CAPNP_CAP_IMPORT), id: ref.id, ops: nil, nops: 0), [])
        case .pipelined(let pipelined):
            return try resolvePipelined(pipelined)
        }
    }

    private func resolvePipelined(_ pipelined: PipelinedCap) throws -> (cap: capnp_cap, path: [UInt16]) {
        guard pipelined.lifetime.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
        let qid = pipelined.lifetime.qid
        guard let q = questions[qid] else { throw closeReason ?? .closed }
        guard q.returned else {
            return (capnp_cap(kind: UInt8(CAPNP_CAP_PROMISED), id: qid, ops: nil, nops: 0), pipelined.path)
        }
        guard let result = q.result else { throw q.failure ?? .closed }
        // Walk the path through the results we hold.
        var reader: StructReader
        do {
            reader = try Message(bytes: result.message).rootStruct()
            var remaining = pipelined.path[...]
            while remaining.count > 1 {
                reader = try reader.readStruct(Int(remaining.removeFirst()))
            }
            let index: UInt32?
            if let last = remaining.first {
                index = try reader.readCapabilityIndex(Int(last))
            } else {
                index = try Message(bytes: result.message).rootCapabilityIndex()
            }
            guard let index, Int(index) < result.caps.count else {
                throw RPCError.failed(reason: "pipelined capability is null")
            }
            switch result.caps[Int(index)] {
            case .imported(let ref):
                return (capnp_cap(kind: UInt8(CAPNP_CAP_IMPORT), id: ref.id, ops: nil, nops: 0), [])
            case .exported:
                throw RPCError.failed(reason: "pipelined capability is a local export")
            case .none:
                throw RPCError.failed(reason: "pipelined capability is null")
            }
        } catch let error as CapnpError {
            throw RPCError.malformed("\(error)")
        }
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
        flushDeferredWork()
    }

    /// Releases and question drops queued by `deinit`s since the last flush.
    func flushDeferredWork() {
        let work = releases.take()
        guard !work.isEmpty else { return }
        for item in work {
            switch item {
            case .release(let id):
                if !transportIsClosed { _ = capnp_release(core.raw, id, 1) }
            case .questionDropped(let qid):
                questionDropped(qid)
            }
        }
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
            let bytes = Self.bytes(e.msg, e.msg_len)
            outboundBytes += bytes.count
            let count = bytes.count
            transport.send(bytes) { [weak self] in
                guard let self else { return }
                self.assumeIsolated { me in me.sendCompleted(count) }
            }
        case CAPNP_EFFECT_CLOSE_REQUESTED:
            if closeReason == nil { closeReason = .disconnected(reason: "closed by the core") }
            transport.cancel()
        case CAPNP_EFFECT_RETURN:
            handleReturn(e)
        case CAPNP_EFFECT_INBOUND_CALL:
            handleInboundCall(e)
        case CAPNP_EFFECT_EXPORT_DROPPED:
            exports.removeValue(forKey: e.host_tag)
        case CAPNP_EFFECT_EVENT:
            let name = String(cString: capnp_core_event_name(e.event_tag))
            eventContinuation.yield(RPCEvent(tag: e.event_tag, name: name, errorName: Self.string(e.reason, e.reason_len)))
        default:
            break
        }
    }

    private func handleReturn(_ e: capnp_effect) {
        let qid = e.id
        guard var q = questions[qid] else {
            // Unknown to us (never happens for a question we asked); nothing
            // else can use it, so finish it.
            if Int32(e.return_kind) != CAPNP_RETURN_CANCELED, !transportIsClosed { _ = capnp_finish(core.raw, qid, 0) }
            return
        }
        q.returned = true
        switch Int32(e.return_kind) {
        case CAPNP_RETURN_RESULTS:
            q.result = CallResult(message: Self.bytes(e.msg, e.msg_len), caps: capTable(e.caps, e.ncaps))
        case CAPNP_RETURN_EXCEPTION:
            q.failure = RPCError.remote(type: e.exception_type, reason: Self.string(e.reason, e.reason_len))
        case CAPNP_RETURN_CANCELED:
            q.failure = .canceled
            q.canceled = true
        default:
            q.failure = .disconnected(reason: Self.string(e.reason, e.reason_len))
        }
        let waiters = q.waiters
        q.waiters.removeAll()
        for waiter in waiters {
            if let result = q.result { waiter.resume(returning: result) } else { waiter.resume(throwing: q.failure ?? .closed) }
        }
        finishIfDue(qid, q)
    }

    private func handleInboundCall(_ e: capnp_effect) {
        let answerID = e.id
        guard let export = exports[e.host_tag] else {
            sendException(answerID, (3, "capnp-swift: no such export"))
            return
        }
        let params = Self.bytes(e.msg, e.msg_len)
        let call = InboundCall(
            interfaceID: e.interface_id,
            methodID: e.method_id,
            params: params,
            caps: capTable(e.caps, e.ncaps),
            connection: self)
        inboundInFlight += 1
        inboundBytes += params.count
        applyInboundBackpressure()
        let handler = export.handler
        // The Task inherits this actor: it starts on the queue in creation
        // order and runs the handler until its first suspension (E-order),
        // and `complete` is a direct call.
        Task {
            let outcome: Result<CallResponse, any Error>
            do {
                outcome = .success(try await handler.handle(call, on: self))
            } catch {
                outcome = .failure(error)
            }
            self.complete(answerID: answerID, paramBytes: params.count, outcome)
        }
    }

    private func complete(answerID: UInt32, paramBytes: Int, _ outcome: Result<CallResponse, any Error>) {
        inboundInFlight -= 1
        inboundBytes -= paramBytes
        applyInboundBackpressure()
        guard !transportIsClosed else { return }
        switch outcome {
        case .success(let response):
            do {
                let encoded = try encodeSlots(response.caps)
                defer { encoded.release() }
                let rc = response.message.withUnsafeBufferPointer { m in
                    encoded.table.withUnsafeBufferPointer { t in
                        capnp_return_results(core.raw, answerID, m.baseAddress, m.count, t.baseAddress, t.count)
                    }
                }
                if rc != CAPNP_OK, rc != CAPNP_E_BAD_ID {
                    sendException(answerID, (0, "capnp-swift: results refused (\(rc))"))
                }
            } catch {
                let wire = RPCError.wire(for: error)
                sendException(answerID, (wire.type, wire.reason))
            }
        case .failure(let error):
            var wire = RPCError.wire(for: error)
            if wire.sanitized {
                // Plan §5: the remote gets a generic reason plus a correlation
                // id; the full error goes to the log.
                let ref = String(UInt32.random(in: 0...UInt32.max), radix: 16)
                wire.reason += " (ref \(ref))"
                Self.logger.error("export handler failed (ref \(ref, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
            sendException(answerID, (wire.type, wire.reason))
        }
        drain()
    }

    private func sendException(_ answerID: UInt32, _ wire: (type: UInt16, reason: String)) {
        var reason = Array(wire.reason.utf8)
        _ = reason.withUnsafeMutableBufferPointer { r -> Int32 in
            guard let base = r.baseAddress else { return capnp_return_exception(core.raw, answerID, wire.type, nil, 0) }
            return base.withMemoryRebound(to: CChar.self, capacity: r.count) { p in
                capnp_return_exception(core.raw, answerID, wire.type, p, r.count)
            }
        }
    }

    /// A host `caps[]` table for one C call, with the ops storage of its
    /// PROMISED entries. `release()` after the call.
    private struct EncodedCaps {
        var table: [capnp_cap] = []
        var paths: [UnsafeMutableBufferPointer<UInt16>] = []

        func release() {
            for path in paths { path.deallocate() }
        }
    }

    private func encodeSlots(_ slots: [CapSlot]) throws -> EncodedCaps {
        var encoded = EncodedCaps()
        encoded.table.reserveCapacity(slots.count)
        do {
            for slot in slots {
                switch slot {
                case .none:
                    encoded.table.append(capnp_cap(kind: UInt8(CAPNP_CAP_NONE), id: 0, ops: nil, nops: 0))
                case .imported(let ref):
                    guard ref.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
                    encoded.table.append(capnp_cap(kind: UInt8(CAPNP_CAP_IMPORT), id: ref.id, ops: nil, nops: 0))
                case .export(let handler):
                    encoded.table.append(capnp_cap(kind: UInt8(CAPNP_CAP_EXPORT), id: try exportHandler(handler), ops: nil, nops: 0))
                case .promise(let promise):
                    guard promise.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
                    encoded.table.append(capnp_cap(kind: UInt8(CAPNP_CAP_EXPORT), id: promise.id, ops: nil, nops: 0))
                case .pipelined(let pipelined):
                    let resolved = try resolvePipelined(pipelined)
                    var cap = resolved.cap
                    if !resolved.path.isEmpty {
                        let storage = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: resolved.path.count)
                        _ = storage.initialize(from: resolved.path)
                        encoded.paths.append(storage)
                        cap.ops = UnsafePointer(storage.baseAddress)
                        cap.nops = UInt16(resolved.path.count)
                    }
                    encoded.table.append(cap)
                }
            }
        } catch {
            encoded.release()
            throw error
        }
        return encoded
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

    // MARK: Backpressure

    private func applyInboundBackpressure() {
        let over = inboundInFlight >= options.inboundHighWaterCalls || inboundBytes >= options.inboundHighWaterBytes
        if over, !receivePaused {
            receivePaused = true
            transport.pauseReceiving()
        } else if !over, receivePaused, inboundInFlight <= options.inboundHighWaterCalls / 2, inboundBytes <= options.inboundHighWaterBytes / 2 {
            receivePaused = false
            transport.resumeReceiving()
        }
    }

    private func sendCompleted(_ count: Int) {
        outboundBytes -= count
        if outboundBytes < options.outboundHighWaterBytes {
            let waiters = outboundWaiters
            outboundWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func waitForOutboundWindow() async {
        while outboundBytes >= options.outboundHighWaterBytes, !transportIsClosed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                outboundWaiters.append(continuation)
            }
        }
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
        for (qid, var q) in questions where !q.returned {
            q.returned = true
            q.failure = cause
            for waiter in q.waiters { waiter.resume(throwing: cause) }
            q.waiters.removeAll()
            questions[qid] = q
        }
        exports.removeAll()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resume(returning: cause) }
        let blocked = outboundWaiters
        outboundWaiters.removeAll()
        for waiter in blocked { waiter.resume() }
        eventContinuation.finish()
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
