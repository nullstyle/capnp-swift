import Dispatch

/// The connection actor's executor: a `DispatchSerialQueue` that runs actor
/// jobs as ordinary `queue.async` blocks.
///
/// `DispatchSerialQueue` is itself a `SerialExecutor`, but it enqueues jobs
/// through `dispatch_async_swift_job`, which ThreadSanitizer does not
/// intercept: TSan then cannot see that an actor job and a transport callback
/// (`queue.async` from Network.framework or `LoopbackTransport`) are
/// serialized by the same queue, and reports a false race. Going through
/// `queue.async` for both keeps the M1 TSan gate meaningful and clean.
///
/// `checkIsolated` is what lets a callback block on the queue use
/// `assumeIsolated` without a running task (SE-0424).
final class QueueExecutor: SerialExecutor, @unchecked Sendable {
    let queue: DispatchSerialQueue

    init(label: String) {
        queue = DispatchSerialQueue(label: label)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { [self] in
            unowned.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
