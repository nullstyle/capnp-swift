import Dispatch
import Synchronization

/// An imported capability: one wire reference on a remote export, owned by
/// this object. Dropping the last reference releases it on the connection
/// (plan §5: a Mutex-guarded release list the connection actor drains).
public final class CapRef: Sendable {
    /// The import id on `connection`.
    public let id: UInt32
    let releases: ReleaseList
    /// Identity of the owning connection: a cap may only be used there.
    let owner: ObjectIdentifier

    init(id: UInt32, releases: ReleaseList, owner: ObjectIdentifier) {
        self.id = id
        self.releases = releases
        self.owner = owner
    }

    deinit {
        releases.push(.release(id))
    }
}

/// Work a dropped handle leaves for the connection actor.
enum DeferredWork: Sendable {
    /// Release one wire reference on an import (`CapRef.deinit`).
    case release(UInt32)
    /// The last `RemotePromise` / `PipelinedCap` of a question is gone:
    /// finish it (returned) or cancel it (still open).
    case questionDropped(UInt32)
}

/// Deferred work from `deinit`s, which run on any thread; the connection
/// actor drains it. The one mutex in the runtime.
final class ReleaseList: Sendable {
    private struct State {
        var pending: [DeferredWork] = []
        weak var connection: RPCConnection?
    }

    private let state = Mutex<State>(State())

    func attach(_ connection: RPCConnection) {
        state.withLock { $0.connection = connection }
    }

    func push(_ work: DeferredWork) {
        let connection = state.withLock { s -> RPCConnection? in
            s.pending.append(work)
            return s.connection
        }
        // Kick the actor so the work happens soon (ticks also flush).
        guard let connection else { return }
        connection.queue.async {
            connection.assumeIsolated { $0.flushDeferredWork() }
        }
    }

    func take() -> [DeferredWork] {
        state.withLock { s in
            defer { s.pending.removeAll(keepingCapacity: true) }
            return s.pending
        }
    }
}

/// Shared by every handle of one question; its `deinit` is "the last handle
/// dropped" (plan §5: Finish goes out when the last `RemotePromise` or
/// pipelined handle for a qid is gone).
final class QuestionLifetime: Sendable {
    let qid: UInt32
    let releases: ReleaseList
    let owner: ObjectIdentifier

    init(qid: UInt32, releases: ReleaseList, owner: ObjectIdentifier) {
        self.qid = qid
        self.releases = releases
        self.owner = owner
    }

    deinit {
        releases.push(.questionDropped(qid))
    }
}

/// A call in flight (plan §5 `RemotePromise`). `result()` awaits the RETURN;
/// `pipeline(_:)` names a capability inside the future results, usable as a
/// call target (and in payloads) before the RETURN arrives. The question is
/// finished when this promise and every pipelined capability made from it are
/// gone; dropping them all before the RETURN cancels the call.
public final class RemotePromise: Sendable {
    let lifetime: QuestionLifetime
    public let connection: RPCConnection

    init(lifetime: QuestionLifetime, connection: RPCConnection) {
        self.lifetime = lifetime
        self.connection = connection
    }

    /// The question id (diagnostics).
    public var qid: UInt32 { lifetime.qid }

    /// The RETURN: results, or the remote exception, `.canceled` or
    /// `.disconnected`. Cancelling the waiting task cancels the call.
    public func result() async throws -> CallResult {
        try await connection.awaitResult(of: self)
    }

    /// The capability at `path` (pointer-field indices from the results
    /// struct; empty: the results root) of the future results.
    public func pipeline(_ path: [UInt16] = []) -> PipelinedCap {
        PipelinedCap(lifetime: lifetime, path: path)
    }
}

/// A capability inside the results of a call that may not have returned yet
/// (plan §4 PROMISED). Calls on it go out at once; once the RETURN is in, the
/// connection resolves the path itself.
public final class PipelinedCap: Sendable {
    let lifetime: QuestionLifetime
    public let path: [UInt16]

    init(lifetime: QuestionLifetime, path: [UInt16]) {
        self.lifetime = lifetime
        self.path = path
    }
}

/// What a call can target.
public enum CallTarget: Sendable {
    case cap(CapRef)
    case pipelined(PipelinedCap)
}

/// A promise this side exported: a capability the remote can already call,
/// which the exporter resolves (or rejects) later (plan §4 promise exports).
public final class PromiseExport: Sendable {
    public let id: UInt32
    let owner: ObjectIdentifier

    init(id: UInt32, owner: ObjectIdentifier) {
        self.id = id
        self.owner = owner
    }
}

/// One entry of a received payload's cap table (`RETURN` results or
/// `INBOUND_CALL` params).
public enum CapTableEntry: Sendable {
    case none
    /// The remote's export, now held by this `CapRef`.
    case imported(CapRef)
    /// One of this connection's own exports came back (its export id).
    case exported(UInt32)
}

/// One entry of a payload's cap table the host sends (`call` params or
/// `return_results`).
public enum CapSlot: Sendable {
    case none
    /// Pass an import this connection holds.
    case imported(CapRef)
    /// Export a new host object and pass it.
    case export(any ExportHandler)
    /// Pass a capability from the results of a call still in flight.
    case pipelined(PipelinedCap)
    /// Pass a promise export (resolve it later).
    case promise(PromiseExport)
}

/// A call the remote made on one of this connection's exports.
public struct InboundCall: Sendable {
    public let interfaceID: UInt64
    public let methodID: UInt16
    /// A standalone message whose root is the params struct.
    public let params: [UInt8]
    public let caps: [CapTableEntry]
    /// The connection the call arrived on (to call back on its caps).
    public let connection: RPCConnection

    /// Public so an app can dispatch to one of its own handlers locally (a
    /// capability of ours that came back as `.exported`).
    public init(interfaceID: UInt64, methodID: UInt16, params: [UInt8], caps: [CapTableEntry], connection: RPCConnection) {
        self.interfaceID = interfaceID
        self.methodID = methodID
        self.params = params
        self.caps = caps
        self.connection = connection
    }
}

/// What a handler answers with.
public struct CallResponse: Sendable {
    /// A standalone message whose root is the results struct.
    public var message: [UInt8]
    public var caps: [CapSlot]

    public init(message: [UInt8], caps: [CapSlot] = []) {
        self.message = message
        self.caps = caps
    }
}

/// The RETURN of a call.
public struct CallResult: Sendable {
    /// A standalone message whose root is the results struct.
    public let message: [UInt8]
    public let caps: [CapTableEntry]
}

/// A host object the connection exports. Generated `Server` glue conforms;
/// throw `RPCError.unimplemented` for unknown methods.
///
/// E-order (plan §5): `handle` runs isolated to the connection, so handlers
/// for one connection start in arrival order and run until their first
/// suspension before the next one starts; after that they interleave. Hand
/// long work to the app's own actors from inside.
public protocol ExportHandler: Sendable {
    func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse
}

/// A Peer observer event (`RPCConnection.Options.observeEvents`). Match on
/// `name` with a default case: the set grows with capnp-zig.
public struct RPCEvent: Sendable, Equatable {
    /// capnp-zig's `events.Event` tag.
    public let tag: UInt8
    /// Its name: "connection", "frame", "backpressure", "resource_rejection",
    /// "protocol_error", "close", "timeout", "pressure", "call_latency",
    /// "cancel_failure", or "unknown".
    public let name: String
    /// The event's error name, "" if it has none.
    public let errorName: String
}
