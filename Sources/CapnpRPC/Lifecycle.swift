// Opt-in app lifecycle handling (plan §5, M5). An app holds one
// `RPCLifecyclePolicy` per connection and forwards UIKit/SwiftUI scene
// phase changes to it:
//
//     let policy = RPCLifecyclePolicy(connection: conn)
//     .onChange { phase in policy.scenePhaseDidchange(phase) }
//
// On `.background`: the policy asks for background time
// (`beginBackgroundTask`), shuts the connection down with a short drain
// (the OS suspends the process anyway), and closes with `.suspended`.
// On `.active` again: `reconnect()` builds a fresh connection through the
// factory the app supplied. The policy never throws: a failed reconnect
// surfaces on `connection` as `.disconnected`, and `reconnect()` reports
// whether a new connection exists.
//
// The test suite drives the same state machine directly (no UIKit needed).

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class RPCLifecyclePolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Phase = .inactive
    private var current: RPCConnection?
    private let makeConnection: @Sendable () async throws -> RPCConnection
    #if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    private let drainTimeout: Duration

    public enum Phase: String, Sendable {
        case inactive, active, background
    }

    public enum ReconnectResult: Sendable {
        case reconnected
        /// The reconnect failed; `reason` carries the connect error.
        case failed(String)
        /// The policy was already active with a live connection.
        case alreadyActive
    }

    /// - Parameters:
    ///   - first: the live connection this policy manages.
    ///   - reconnect: builds a replacement after a background suspend.
    ///   - drainTimeout: how long `shutdown()` may wait for in-flight
    ///     calls when backgrounding (default 2 s; the plan's short drain).
    public init(
        connection first: RPCConnection,
        drainTimeout: Duration = .seconds(2),
        reconnect: @escaping @Sendable () async throws -> RPCConnection
    ) {
        self.current = first
        self.makeConnection = reconnect
        self.drainTimeout = drainTimeout
    }

    /// The managed connection (nil while suspended before a reconnect).
    public var connection: RPCConnection? {
        lock.withLock { current }
    }

    /// Forward a scene-phase change.
    public func scenePhaseDidChange(_ phase: Phase) async {
        let previous = lock.withLock { () -> Phase in
            defer { state = phase }
            return state
        }
        switch (previous, phase) {
        case (_, .background):
            await suspend()
        case (.background, .active):
            _ = await reconnect()
        default:
            break
        }
    }

    private func suspend() async {
        // Ask the OS for a little time (main-actor), shut down, close, end
        // the task. The task ID round-trips through the lock.
        let taskID = await requestBackgroundTime()
        if let connection = lock.withLock({ current }) {
            _ = await connection.shutdown()
            await connection.close()
            lock.withLock { current = nil }
        }
        if taskID != nil {
            await releaseBackgroundTime()
        }
    }

    #if canImport(UIKit)
    private func requestBackgroundTime() async -> UIBackgroundTaskIdentifier? {
        await MainActor.run {
            let id = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
            lock.withLock { backgroundTaskID = id }
            return id
        }
    }

    private func releaseBackgroundTime() async {
        let id = lock.withLock { () -> UIBackgroundTaskIdentifier in
            defer { backgroundTaskID = .invalid }
            return backgroundTaskID
        }
        guard id != .invalid else { return }
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(id)
        }
    }
    #else
    private func requestBackgroundTime() async -> Int? { nil }
    private func releaseBackgroundTime() async {}
    #endif

    /// Try to come back after a suspend. Safe to call directly.
    public func reconnect() async -> ReconnectResult {
        if lock.withLock({ current }) != nil {
            return .alreadyActive
        }
        do {
            let fresh = try await makeConnection()
            lock.withLock { current = fresh }
            return .reconnected
        } catch {
            return .failed("\(error)")
        }
    }
}
