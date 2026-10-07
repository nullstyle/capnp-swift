/// Errors the RPC runtime throws (plan §5).
public enum RPCError: Error, Sendable, Equatable {
    /// The remote answered with an exception of type `failed` (rpc.capnp
    /// `Exception.Type` 0).
    case failed(reason: String)
    /// `overloaded` (1): temporary; retry much later.
    case overloaded(reason: String)
    /// `disconnected` (2): the connection ended, or the remote said the
    /// capability is gone. Local causes carry the core's reason text.
    case disconnected(reason: String)
    /// `unimplemented` (3): the remote does not implement the method.
    case unimplemented(reason: String)
    /// The question was canceled before it returned.
    case canceled
    /// The core refused an operation (`code` is a `CAPNP_E_*` value).
    case core(code: Int32, operation: String)
    /// The connection is closed; no new work is accepted.
    case closed
    /// A payload was not a well-formed message (`CapnpError` text).
    case malformed(String)
    /// A capability from another connection was used on this one.
    case foreignCapability

    /// The remote exception for an `Exception.Type` ordinal.
    static func remote(type: UInt16, reason: String) -> RPCError {
        switch type {
        case 1: return .overloaded(reason: reason)
        case 2: return .disconnected(reason: reason)
        case 3: return .unimplemented(reason: reason)
        default: return .failed(reason: reason)
        }
    }

    /// What a handler's thrown error becomes on the wire: the exception type
    /// ordinal and the reason the remote sees. Only `RPCError`'s own reasons
    /// cross the wire; any other error is sanitized to a generic reason
    /// (plan §5: never leak an app's error text), and `sanitized` tells the
    /// caller to log the real error with a correlation id.
    static func wire(for error: any Error) -> (type: UInt16, reason: String, sanitized: Bool) {
        switch error {
        case let e as RPCError:
            switch e {
            case .failed(let r): return (0, r, false)
            case .overloaded(let r): return (1, r, false)
            case .disconnected(let r): return (2, r, false)
            case .unimplemented(let r): return (3, r, false)
            case .canceled: return (0, "canceled", false)
            case .malformed(let r): return (0, "malformed payload: \(r)", false)
            case .core, .closed, .foreignCapability: return (0, "capnp-swift: handler failed", true)
            }
        case is CancellationError:
            return (0, "canceled", false)
        default:
            return (0, "capnp-swift: handler failed", true)
        }
    }
}
