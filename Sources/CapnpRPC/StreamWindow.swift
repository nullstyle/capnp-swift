// The streaming-input window (plan §5): a caller on a `-> stream` method
// suspends above `Options.streamWindowMaxCalls` in-flight streaming calls or
// `streamWindowMaxBytes` bytes of their params. The StreamResult return (the
// call completing) frees space. Either limit at 0 disables that bound.

import Dispatch

public struct StreamWindow: Sendable {
    private final class State: @unchecked Sendable {
        struct Waiter {
            let id: UInt64?
            let bytes: Int
            let legacy: CheckedContinuation<Void, Never>?
            let throwing: CheckedContinuation<Void, any Error>?

            func resume(_ error: RPCError? = nil) {
                if let legacy { legacy.resume() }
                if let throwing {
                    if let error { throwing.resume(throwing: error) }
                    else { throwing.resume() }
                }
            }
        }

        let lock = DispatchSemaphore(value: 1)
        let maxCalls: Int
        let maxBytes: Int
        var calls = 0
        var bytes = 0
        var waiters: [Waiter] = []
        var nextWaiter: UInt64 = 0
        var closed: RPCError?

        init(maxCalls: Int, maxBytes: Int) {
            self.maxCalls = maxCalls
            self.maxBytes = maxBytes
        }

        func hasSpace(for bytes: Int) -> Bool {
            closed == nil && (maxCalls == 0 || calls < maxCalls) && (maxBytes == 0 || bytes <= maxBytes - self.bytes)
        }

        func lockState() { lock.wait() }
        func unlockState() { lock.signal() }

        /// Claim space for `bytes`, or park `continuation`. The continuation
        /// resumes only after `release` claimed on its behalf.
        func acquireOrPark(bytes: Int, continuation: CheckedContinuation<Void, Never>) {
            lockState()
            if closed != nil {
                unlockState()
                continuation.resume()
            } else if hasSpace(for: bytes) {
                calls += 1
                self.bytes += bytes
                unlockState()
                continuation.resume()
            } else {
                waiters.append(Waiter(id: nil, bytes: bytes, legacy: continuation, throwing: nil))
                unlockState()
            }
        }

        func allocateWaiter() -> UInt64 {
            lockState()
            defer { unlockState() }
            let id = nextWaiter
            nextWaiter &+= 1
            return id
        }

        func acquireOrPark(bytes: Int, id: UInt64, continuation: CheckedContinuation<Void, any Error>) {
            lockState()
            let error: RPCError?
            // Check cancellation while holding the same lock used by removal.
            // Cancellation before registration cannot disappear in that gap.
            if Task.isCancelled { error = .canceled }
            else if let closed { error = closed }
            else if bytes < 0 || maxCalls < 0 || maxBytes < 0 { error = .overloaded(reason: "invalid stream window size") }
            else if maxBytes > 0 && bytes > maxBytes { error = .overloaded(reason: "stream payload is larger than the byte window") }
            else { error = nil }
            if let error {
                unlockState()
                continuation.resume(throwing: error)
            } else if hasSpace(for: bytes) {
                calls += 1
                self.bytes += bytes
                unlockState()
                continuation.resume()
            } else {
                waiters.append(Waiter(id: id, bytes: bytes, legacy: nil, throwing: continuation))
                unlockState()
            }
        }

        func cancel(_ id: UInt64) {
            lockState()
            let waiter: Waiter?
            if let index = waiters.firstIndex(where: { $0.id == id }) { waiter = waiters.remove(at: index) }
            else { waiter = nil }
            let ready = waiter == nil ? [] : claimReady()
            unlockState()
            // Once granted, ownership belongs to acquireThrowing/the caller;
            // cancellation must not release that same permit a second time.
            waiter?.resume(.canceled)
            for next in ready { next.resume() }
        }

        func close(_ error: RPCError) {
            lockState()
            guard closed == nil else { unlockState(); return }
            closed = error
            let blocked = waiters
            waiters.removeAll()
            unlockState()
            for waiter in blocked { waiter.resume(error) }
        }

        func closeReason() -> RPCError? {
            lockState()
            defer { unlockState() }
            return closed
        }

        private func claimReady() -> [Waiter] {
            var ready: [Waiter] = []
            while let next = waiters.first, hasSpace(for: next.bytes) {
                waiters.removeFirst()
                calls += 1
                self.bytes += next.bytes
                ready.append(next)
            }
            return ready
        }

        func release(bytes: Int) {
            lockState()
            calls = max(0, calls - 1)
            self.bytes = max(0, self.bytes - bytes)
            let ready = claimReady()
            unlockState()
            for waiter in ready { waiter.resume() }
        }
    }

    private let state: State

    init(maxCalls: Int, maxBytes: Int) {
        state = State(maxCalls: maxCalls, maxBytes: maxBytes)
    }

    /// Wait for window space for one streaming call whose params are `bytes`
    /// long, claiming it before returning.
    public func acquire(bytes: Int) async {
        // Fast path without a continuation hop.
        state.lockState()
        if state.closed != nil { state.unlockState(); return }
        if state.hasSpace(for: bytes) {
            // Claim inline.
            state.calls += 1
            state.bytes += bytes
            state.unlockState()
            return
        }
        state.unlockState()
        await withCheckedContinuation { continuation in
            state.acquireOrPark(bytes: bytes, continuation: continuation)
        }
    }

    /// Typed wrappers can report cancellation, closure and an oversized
    /// payload without changing the legacy nonthrowing acquisition API.
    func acquireThrowing(bytes: Int) async throws {
        let id = state.allocateWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.acquireOrPark(bytes: bytes, id: id, continuation: continuation)
            }
        } onCancel: {
            state.cancel(id)
        }
        // A grant may win the registration/cancellation or grant/close race.
        // Until this function returns, it alone owns and releases that grant.
        if Task.isCancelled { state.release(bytes: bytes); throw RPCError.canceled }
        if let error = state.closeReason() { state.release(bytes: bytes); throw error }
    }

    func close(_ error: RPCError) { state.close(error) }

    /// Free the space one finished streaming call held.
    public func release(bytes: Int) {
        state.release(bytes: bytes)
    }

    func usageSnapshot() -> (calls: Int, bytes: Int, waiters: Int) {
        state.lockState()
        defer { state.unlockState() }
        return (state.calls, state.bytes, state.waiters.count)
    }
}
