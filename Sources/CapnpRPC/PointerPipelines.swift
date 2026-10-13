@_spi(Generated) import Capnp
import Synchronization

/// A pointer schema whose capability fields can be projected from a pending
/// RPC result. Struct projections follow pointer fields; interface projections
/// produce a client that can be called before the result arrives.
public protocol CapnpPipelineSchema: CapnpPointerSchema {
    associatedtype Pipeline: Sendable
    static func pipeline(_ projection: RPCPointerPipeline) -> Pipeline
}

/// An owned typed-pointer call in flight. Its result and all projections share
/// one lifetime; dropping the last handle cancels an unfinished local call or
/// releases the native question handle.
public struct RPCPointerCall: Sendable {
    let pending: RPCPointerPending

    init(_ pending: RPCPointerPending) { self.pending = pending }

    public var connection: RPCConnection { pending.connection }
    public var pipeline: RPCPointerPipeline { RPCPointerPipeline(pending: pending, path: []) }

    public func value() async throws -> PointerReader { try await pending.value() }
}

/// A path through struct pointer fields of a pending result. Wire pipelines
/// do not support list indexing or union discriminant tests; await the call's
/// value to inspect those shapes.
public struct RPCPointerPipeline: Sendable {
    let pending: RPCPointerPending
    let path: [UInt16]

    init(pending: RPCPointerPending, path: [UInt16]) {
        self.pending = pending
        self.path = path
    }

    public func field(_ index: UInt16) -> RPCPointerPipeline {
        RPCPointerPipeline(pending: pending, path: path + [index])
    }

    /// Project an interface at this path. A null or invalid result becomes an
    /// error when the client is called, rather than an invented null token.
    public func capability() -> RPCPointerCapability { RPCPointerCapability(projection: self) }

    public func value() async throws -> PointerReader { try select(from: await pending.value()) }

    func select(from root: PointerReader) throws -> PointerReader {
        guard path.count <= 64 else { throw RPCError.failed(reason: "pipeline path too deep") }
        var pointer = root
        for index in path { pointer = try pointer.field(Int(index)) }
        return pointer
    }

    var native: PipelinedCap? { pending.remote?.pipeline(path) }
}

/// An external struct's pending field remains readable even when its producer
/// was built with Capnp alone. Opt-in RPC producers also expose their typed
/// projection through `typed()` without imposing that dependency on readers.
public struct RPCStructPipeline<Schema: CapnpStructSchema>: Sendable {
    public let projection: RPCPointerPipeline
    public init(_ projection: RPCPointerPipeline) { self.projection = projection }

    public func value() async throws -> Schema.Reader { try Schema.read(from: await projection.value()) }

    public func typed() -> Schema.Pipeline where Schema: CapnpPipelineSchema {
        Schema.pipeline(projection)
    }
}

final class RPCPointerPending: Sendable {
    let connection: RPCConnection
    let remote: RemotePromise?
    private let local: RPCPointerLocalResult?
    // Keep an unresolved target's parent question alive until its child call
    // and every child projection are gone, along with the argument tokens.
    private let retained: [any Sendable]

    init(remote: RemotePromise, retained: [any Sendable]) {
        connection = remote.connection
        self.remote = remote
        local = nil
        self.retained = retained
    }

    init(local: Task<PointerReader, any Error>, connection: RPCConnection, timeoutMilliseconds: UInt32, retained: [any Sendable]) {
        self.connection = connection
        remote = nil
        self.local = RPCPointerLocalResult(operation: local, connection: connection, timeoutMilliseconds: timeoutMilliseconds)
        self.retained = retained
    }

    func value() async throws -> PointerReader {
        if let remote { return try await connection.pointerPayload(result: remote.result()) }
        guard let local else { throw RPCError.closed }
        return try await local.value()
    }
}

/// Local handlers run on the connection actor, but a handler may suspend
/// without cooperating with cancellation. Result waiters therefore observe
/// closure/cancellation independently from the handler's eventual completion.
private final class RPCPointerLocalResult: Sendable {
    private struct State {
        var result: Result<PointerReader, any Error>?
        var waiters: [CheckedContinuation<PointerReader, any Error>] = []
        var operation: Task<PointerReader, any Error>?
        var observers: [Task<Void, Never>] = []
    }
    private let state: Mutex<State>

    init(operation: Task<PointerReader, any Error>, connection: RPCConnection, timeoutMilliseconds: UInt32) {
        state = Mutex(State(operation: operation))
        let completion = Task { [weak self] in
            let result = await operation.result.mapError { error -> any Error in
                error is CancellationError ? RPCError.canceled : error
            }
            self?.finish(result)
        }
        let closure = Task { [weak self] in
            let reason = await connection.waitClosed()
            if !Task.isCancelled { self?.finish(.failure(reason)) }
        }
        var observers = [completion, closure]
        if timeoutMilliseconds > 0 {
            let deadline = ContinuousClock.now + .milliseconds(Int64(timeoutMilliseconds))
            observers.append(Task { [weak self] in
                do { try await ContinuousClock().sleep(until: deadline) }
                catch { return }
                self?.finish(.failure(RPCError.overloaded(reason: "deadline exceeded")))
            })
        }
        let finished = state.withLock { state in
            guard state.result == nil else { return true }
            state.observers = observers
            return false
        }
        if finished { for observer in observers { observer.cancel() } }
    }

    func value() async throws -> PointerReader {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<PointerReader, any Error>? in
                    if Task.isCancelled { return Result<PointerReader, any Error>.failure(RPCError.canceled) }
                    if let result = state.result { return result }
                    state.waiters.append(continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.finish(.failure(RPCError.canceled))
        }
    }

    private func finish(_ result: Result<PointerReader, any Error>) {
        let completed = state.withLock { state -> State? in
            guard state.result == nil else { return nil }
            let completed = state
            state.result = result
            state.waiters.removeAll()
            state.operation = nil
            state.observers.removeAll()
            return completed
        }
        guard let completed else { return }
        completed.operation?.cancel()
        for observer in completed.observers { observer.cancel() }
        for waiter in completed.waiters { waiter.resume(with: result) }
    }

    deinit {
        let tasks = state.withLock { ($0.operation, $0.observers) }
        tasks.0?.cancel()
        for observer in tasks.1 { observer.cancel() }
    }
}
