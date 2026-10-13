import Capnp
import CapnpRPC
import Foundation
import WorkbenchModels
import WorkbenchRPC

public struct WorkbenchFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
public struct WorkbenchCheck: Codable, Sendable {
    public let name: String
    public let passed: Bool
    public init(_ name: String, passed: Bool = true) { self.name = name; self.passed = passed }
}
public struct WorkbenchReceipt: Sendable {
    public let count: UInt32
    public let last: String
    public let sequence: UInt32
}

public final class WorkbenchClient: Sendable {
    public let connection: RPCConnection
    public let observer: WorkbenchObserver
    public let openingChecks: [WorkbenchCheck]
    private let session: TextSession.Client
    private init(connection: RPCConnection, observer: WorkbenchObserver, session: TextSession.Client, openingChecks: [WorkbenchCheck]) {
        self.connection = connection; self.observer = observer; self.session = session; self.openingChecks = openingChecks
    }

    public static func open(peer: WorkbenchPeer, receive: @escaping @Sendable (WorkbenchEvent) -> Void = { _ in }) async throws -> WorkbenchClient {
        try await open(connection: peer.connection, wire: peer.wire, receive: receive)
    }
    public static func open(connection: RPCConnection, receive: @escaping @Sendable (WorkbenchEvent) -> Void = { _ in }) async throws -> WorkbenchClient {
        try await open(connection: connection, wire: nil, receive: receive)
    }
    private static func open(connection: RPCConnection, wire: WorkbenchTransport?, receive: @escaping @Sendable (WorkbenchEvent) -> Void) async throws -> WorkbenchClient {
        let observer = WorkbenchObserver(receive: receive)
        let workbench = try Workbench.Typed.Client(cap: await connection.bootstrap(), connection: connection)
        let before = wire?.callsSent
        let pending = try await workbench.sendOpen {
            try $0.setObserver(Observer.Typed.Client(server: observer, connection: connection))
            $0.delayMillis = 500
        }
        let echo = try await pending.pipeline.session.sendEcho { try $0.setValue("before-return") }
        var checks: [WorkbenchCheck] = []
        if let before, let wire {
            try require(wire.callsSent == before + 2 && !observer.events.contains { $0.message == "Session result ready" }, "pipeline CALL is sent before server result is ready")
            checks.append(.init("pipeline CALL is sent before server result is ready"))
        }
        let opened = try await pending.value()
        guard let session = try opened.session() else { throw WorkbenchFailure("server returned a null session") }
        let echoResult = try await echo.value()
        try require(try echoResult.value() == "Echo: before-return", "projected call resolves through returned session")
        checks.append(.init("projected call resolves through returned session"))
        try require(observer.events.contains { $0.message == "Session opening" }, "server invokes client callback capability")
        checks.append(.init("server invokes client callback capability"))
        return WorkbenchClient(connection: connection, observer: observer, session: session, openingChecks: checks)
    }

    public func echo(_ message: String) async throws -> String {
        try await session.echo { try $0.setValue(message) }.value()
    }
    public func exchangeParcel() async throws -> Bool {
        typealias FreshParcel = Parcel.Typed<CapnpList<CapnpData>>
        let chunks: [[UInt8]] = [[0, 1, 255], [], [5, 8]]
        let result = try await session.exchange(as: FreshParcel.self) {
            let parcel = $0.initValue()
            try parcel.setValue(chunks)
            parcel.setLabel("chosen-in-client-module")
        }
        let parcel = try result.value()
        return try parcel.value() == chunks && parcel.label() == "chosen-in-client-module"
    }
    public func stream(count: UInt32 = 12) async throws -> WorkbenchReceipt {
        let before = try await receipt()
        if count > 0 {
            for offset in 1...count {
                let sequence = before.sequence + offset
                try await session.push { try $0.setValue("Update \(sequence)"); $0.sequence = sequence }
            }
        }
        return try await receipt()
    }
    public func receipt() async throws -> WorkbenchReceipt {
        let result = try await session.receipt()
        return WorkbenchReceipt(count: result.count, last: try result.last(), sequence: result.sequence)
    }
    public func slow() async throws -> Bool {
        try await session.slow { $0.delayMillis = 2000 }.completed
    }
    public func close() async { await connection.close() }

    public func runChecks() async throws -> [WorkbenchCheck] {
        var checks = openingChecks
        try require(try await exchangeParcel(), "unseen generic parcel survives separate-module RPC")
        checks.append(.init("unseen generic parcel survives separate-module RPC"))
        let before = try await receipt(), after = try await stream()
        try require(after.count == before.count + 12 && after.sequence == before.sequence + 12 && after.last == "Update \(after.sequence)", "stream receipt proves all acknowledged updates")
        checks.append(.init("stream receipt proves all acknowledged updates"))
        let previousEvents = observer.events.count
        let call = Task { try await self.slow() }
        do {
            try await Self.waitForSlowStart(observer, after: previousEvents)
        } catch { call.cancel(); _ = try? await call.value; throw error }
        let canceledAt = ContinuousClock.now
        call.cancel()
        var canceled = false
        do { _ = try await call.value }
        catch let error as RPCError { canceled = error == .canceled }
        catch is CancellationError { canceled = true }
        try require(canceled && canceledAt.duration(to: .now) < .seconds(1), "caller cancellation wakes before slow work completes")
        checks.append(.init("caller cancellation wakes before slow work completes"))
        try require(try await echo("after-cancel") == "Echo: after-cancel", "connection remains usable after caller cancellation")
        checks.append(.init("connection remains usable after caller cancellation"))
        return checks
    }
    private static func waitForSlowStart(_ observer: WorkbenchObserver, after count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !observer.events.dropFirst(count).contains(where: { $0.message == "Slow request started" }) {
            if .now >= deadline { throw WorkbenchFailure("slow request did not start") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

func require(_ condition: Bool, _ name: String) throws {
    guard condition else { throw WorkbenchFailure(name) }
}

public enum WorkbenchVerification {
    public static func rejectsWrongPin(endpoint: WorkbenchEndpoint) async throws -> [WorkbenchCheck] {
        var rejected = false
        do {
            let unexpected = try await endpoint.connect(wrongPin: true)
            await unexpected.connection.close()
        } catch { rejected = true }
        try require(rejected, "wrong TLS certificate pin rejects connection")
        return [.init("wrong TLS certificate pin rejects connection")]
    }
    public static func lifecycle(endpoint: WorkbenchEndpoint) async throws -> [WorkbenchCheck] {
        let first = try await endpoint.connect()
        let policy = RPCLifecyclePolicy(connection: first.connection) { try await endpoint.connect().connection }
        await policy.scenePhaseDidChange(.active)
        await policy.scenePhaseDidChange(.background)
        try require(policy.connection == nil, "background suspension releases managed connection")
        await policy.scenePhaseDidChange(.active)
        guard let connection = policy.connection else { throw WorkbenchFailure("foreground reconnect has no connection") }
        do {
            try require(connection !== first.connection, "foreground reconnect creates a fresh connection")
            let client = try await WorkbenchClient.open(connection: connection)
            try require(try await client.echo("foreground") == "Echo: foreground", "foreground session completes a new RPC")
            await connection.close()
        } catch { await connection.close(); throw error }
        return [.init("background suspension releases managed connection"),
            .init("foreground reconnect creates a fresh connection"),
            .init("foreground session completes a new RPC")]
    }
}
