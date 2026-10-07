// The streaming-input window (plan §5): a caller on a `-> stream` method
// suspends above `Options.streamWindowMaxCalls` in-flight streaming calls or
// `streamWindowMaxBytes` bytes of their params. The StreamResult return (the
// call completing) frees space. Either limit at 0 disables that bound.

import Dispatch

public struct StreamWindow: Sendable {
    private final class State: @unchecked Sendable {
        let lock = DispatchSemaphore(value: 1)
        let maxCalls: Int
        let maxBytes: Int
        var calls = 0
        var bytes = 0
        var waiters: [(bytes: Int, continuation: CheckedContinuation<Void, Never>)] = []

        init(maxCalls: Int, maxBytes: Int) {
            self.maxCalls = maxCalls
            self.maxBytes = maxBytes
        }

        func hasSpace(for bytes: Int) -> Bool {
            (maxCalls == 0 || calls < maxCalls) && (maxBytes == 0 || self.bytes + bytes <= maxBytes)
        }

        func lockState() { lock.wait() }
        func unlockState() { lock.signal() }

        /// Claim space for `bytes`, or park `continuation`. The continuation
        /// resumes only after `release` claimed on its behalf.
        func acquireOrPark(bytes: Int, continuation: CheckedContinuation<Void, Never>) {
            lockState()
            if hasSpace(for: bytes) {
                calls += 1
                self.bytes += bytes
                unlockState()
                continuation.resume()
            } else {
                waiters.append((bytes, continuation))
                unlockState()
            }
        }

        func release(bytes: Int) {
            lockState()
            calls = max(0, calls - 1)
            self.bytes = max(0, self.bytes - bytes)
            while let next = waiters.first, hasSpace(for: next.bytes) {
                waiters.removeFirst()
                calls += 1
                self.bytes += next.bytes
                next.continuation.resume()
            }
            unlockState()
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

    /// Free the space one finished streaming call held.
    public func release(bytes: Int) {
        state.release(bytes: bytes)
    }
}
