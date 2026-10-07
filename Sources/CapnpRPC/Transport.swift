import Dispatch

/// Where a transport delivers bytes and its end. The connection implements
/// it; every call happens on the connection's queue.
public protocol TransportDelegate: AnyObject, Sendable {
    func transportDidReceive(_ bytes: [UInt8])
    /// The transport is gone (remote close, failure, or `cancel`). Called at
    /// most once. `error` is nil for an orderly end.
    func transportDidClose(error: (any Error)?)
}

/// A byte stream the connection owns (plan §2: Swift owns every socket; the
/// core never sees one). The connection calls every method on its own
/// `DispatchSerialQueue`, and the transport runs every delegate callback on
/// that queue, so implementations need no locking of their own.
public protocol Transport: AnyObject, Sendable {
    /// Attach and begin: connect, then read. Called once, first.
    func start(queue: DispatchSerialQueue, delegate: any TransportDelegate)
    /// Resolves once bytes can flow (connected), or throws the connect
    /// failure (including the transport's connect timeout).
    func open() async throws
    /// Queue `bytes` for sending, in order. `completion` runs on the queue
    /// once the bytes left the transport's own buffer (outbound backpressure
    /// counts bytes between `send` and it). Bytes sent before `open` resolves
    /// are buffered.
    func send(_ bytes: [UInt8], completion: @escaping @Sendable () -> Void)
    /// Stop delivering received bytes until `resumeReceiving` (inbound
    /// backpressure). Bytes already read may still be delivered.
    func pauseReceiving()
    func resumeReceiving()
    /// Close. Leads to one `transportDidClose`.
    func cancel()
}
