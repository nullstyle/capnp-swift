import Dispatch
import Synchronization

/// Two in-memory transports wired to each other (tests, plan §8 M1 TSan gate).
/// Each end hands bytes to the other end's delegate on the other end's queue,
/// never synchronously, so two connections on two queues behave like two
/// processes.
public final class LoopbackTransport: Transport, @unchecked Sendable {
    private struct End {
        var queue: DispatchSerialQueue?
        weak var delegate: (any TransportDelegate)?
        var closed = false
        var opened = false
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

    public func open() async throws {
        link.ends.withLock { $0[index].opened = true }
    }

    public func send(_ bytes: [UInt8]) {
        let other = 1 - index
        let target: (DispatchSerialQueue, any TransportDelegate)? = link.ends.withLock { ends in
            if ends[index].closed || ends[other].closed { return nil }
            guard let q = ends[other].queue, let d = ends[other].delegate else { return nil }
            return (q, d)
        }
        guard let (queue, delegate) = target else { return }
        queue.async { delegate.transportDidReceive(bytes) }
    }

    public func cancel() {
        // Both ends end: the peer sees an orderly close.
        let targets: [(DispatchSerialQueue, any TransportDelegate)] = link.ends.withLock { ends in
            var out: [(DispatchSerialQueue, any TransportDelegate)] = []
            for i in 0..<2 where !ends[i].closed {
                ends[i].closed = true
                if let q = ends[i].queue, let d = ends[i].delegate { out.append((q, d)) }
            }
            return out
        }
        for (queue, delegate) in targets {
            queue.async { delegate.transportDidClose(error: nil) }
        }
    }
}
