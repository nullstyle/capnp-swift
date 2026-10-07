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
        releases.push(id)
    }
}

/// Import ids whose `CapRef` was dropped, waiting for the connection actor
/// to send Release. `CapRef.deinit` runs on any thread, so this is the one
/// mutex in the runtime.
final class ReleaseList: Sendable {
    private struct State {
        var pending: [UInt32] = []
        weak var connection: RPCConnection?
    }

    private let state = Mutex<State>(State())

    func attach(_ connection: RPCConnection) {
        state.withLock { $0.connection = connection }
    }

    func push(_ id: UInt32) {
        let connection = state.withLock { s -> RPCConnection? in
            s.pending.append(id)
            return s.connection
        }
        // Kick the actor so the Release goes out soon (ticks also flush).
        guard let connection else { return }
        connection.queue.async {
            connection.assumeIsolated { $0.flushReleases() }
        }
    }

    func take() -> [UInt32] {
        state.withLock { s in
            defer { s.pending.removeAll(keepingCapacity: true) }
            return s.pending
        }
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
public protocol ExportHandler: Sendable {
    func handle(_ call: InboundCall) async throws -> CallResponse
}
