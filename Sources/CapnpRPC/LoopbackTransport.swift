import Dispatch
import Synchronization

/// Two in-memory transports wired to each other (tests, plan §8 M1 TSan gate).
/// Each end hands bytes to the other end's delegate on the other end's queue,
/// never synchronously, so two connections on two queues behave like two
/// processes. `pauseReceiving` holds bytes until `resumeReceiving`.
public final class LoopbackTransport: Transport, @unchecked Sendable {
    private struct End {
        var queue: DispatchSerialQueue?
        weak var delegate: (any TransportDelegate)?
        var closed = false
        var paused = false
        var held: [[UInt8]] = []
    }

    private final class Link: Sendable {
        let ends = Mutex<[End]>([End(), End()])
    }

    private let link: Link
    private let index: Int

    private init(link: Link, index: Int) {
        self.link = link
        self.index = index
    }

    /// A connected pair.
    public static func pair() -> (LoopbackTransport, LoopbackTransport) {
        let link = Link()
        return (LoopbackTransport(link: link, index: 0), LoopbackTransport(link: link, index: 1))
    }

    public func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        link.ends.withLock { ends in
            ends[index].queue = queue
            ends[index].delegate = delegate
        }
    }

    public func open() async throws {}

    public func send(_ bytes: [UInt8], completion: @escaping @Sendable () -> Void) {
        let other = 1 - index
        let target: (DispatchSerialQueue, any TransportDelegate)? = link.ends.withLock { ends in
            if ends[index].closed || ends[other].closed { return nil }
            if ends[other].paused {
                ends[other].held.append(bytes)
                return nil
            }
            guard let q = ends[other].queue, let d = ends[other].delegate else { return nil }
            return (q, d)
        }
        if let (queue, delegate) = target {
            queue.async { delegate.transportDidReceive(bytes) }
        }
        // "Left our buffer" at once: the other end's queue holds it now.
        completion()
    }

    public func pauseReceiving() {
        link.ends.withLock { $0[index].paused = true }
    }

    public func resumeReceiving() {
        let release: (DispatchSerialQueue, any TransportDelegate, [[UInt8]])? = link.ends.withLock { ends in
            ends[index].paused = false
            let held = ends[index].held
            ends[index].held.removeAll()
            guard !held.isEmpty, let q = ends[index].queue, let d = ends[index].delegate else { return nil }
            return (q, d, held)
        }
        if let (queue, delegate, held) = release {
            queue.async { for chunk in held { delegate.transportDidReceive(chunk) } }
        }
    }

    public func cancel() {
        // Both ends end: the peer sees an orderly close.
        let targets: [(DispatchSerialQueue, any TransportDelegate)] = link.ends.withLock { ends in
            var out: [(DispatchSerialQueue, any TransportDelegate)] = []
            for i in 0..<2 where !ends[i].closed {
                ends[i].closed = true
                ends[i].held.removeAll()
                if let q = ends[i].queue, let d = ends[i].delegate { out.append((q, d)) }
            }
            return out
        }
        for (queue, delegate) in targets {
            queue.async { delegate.transportDidClose(error: nil) }
        }
    }
}
