import Capnp
import CapnpRPC
import Foundation
import Synchronization
import WorkbenchRPC

public struct WorkbenchEvent: Codable, Sendable {
    public let message: String
    public let sequence: UInt32
}

public final class WorkbenchObserver: Observer.TypedServer, Sendable {
    private let recorded = Mutex<[WorkbenchEvent]>([])
    private let receive: @Sendable (WorkbenchEvent) -> Void
    public init(receive: @escaping @Sendable (WorkbenchEvent) -> Void = { _ in }) { self.receive = receive }
    public var events: [WorkbenchEvent] { recorded.withLock { $0 } }
    public func event(params: Observer.Typed.EventParams.Reader, on connection: isolated RPCConnection) async throws -> Observer.Typed.EventResults.Value {
        let event = WorkbenchEvent(message: try params.message(), sequence: params.sequence)
        recorded.withLock { $0.append(event) }
        receive(event)
        return try .init()
    }
}

typealias TextSession = Session.Typed<CapnpText>

final class WorkbenchService: Workbench.TypedServer, Sendable {
    func open(params: Workbench.Typed.OpenParams.Reader, on connection: isolated RPCConnection) async throws -> Workbench.Typed.OpenResults.Value {
        guard let observer = try params.observer() else { throw WorkbenchFailure("observer is missing") }
        _ = try await observer.event { $0.setMessage("Session opening"); $0.sequence = 0 }
        try await Task.sleep(for: .milliseconds(Int64(min(params.delayMillis, 2000))))
        _ = try await observer.event { $0.setMessage("Session result ready"); $0.sequence = 0 }
        let session = TextSession.Client(server: WorkbenchSession(observer: observer), connection: connection)
        return try .init { try $0.setSession(session) }
    }
}

final class WorkbenchSession: Session.TypedServer, Sendable {
    typealias Session_T_fc297b036c3a595b_0 = CapnpText
    private struct State { var count: UInt32 = 0; var last = ""; var sequence: UInt32 = 0 }
    private let state = Mutex(State())
    private let observer: Observer.Typed.Client
    init(observer: Observer.Typed.Client) { self.observer = observer }

    func echo(params: TextSession.EchoParams.Reader, on connection: isolated RPCConnection) async throws -> TextSession.EchoResults.Value {
        let value = try params.value()
        _ = try await observer.event { $0.setMessage("Echo received: \(value)"); $0.sequence = 0 }
        return try .init { try $0.setValue("Echo: \(value)") }
    }
    func exchange(params: TextSession.ExchangeParams<CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws -> TextSession.ExchangeResults<CapnpAnyPointer>.Value {
        try .init { try $0.setValue(params.value()) }
    }
    func push(params: TextSession.PushParams.Reader, on connection: isolated RPCConnection) async throws {
        let value = try params.value(), sequence = params.sequence
        state.withLock { $0.count += 1; $0.last = value; $0.sequence = sequence }
        _ = try await observer.event { $0.setMessage(value); $0.sequence = sequence }
    }
    func receipt(params: TextSession.ReceiptParams.Reader, on connection: isolated RPCConnection) async throws -> TextSession.ReceiptResults.Value {
        let snapshot = state.withLock { $0 }
        return try .init { $0.count = snapshot.count; try $0.setLast(snapshot.last); $0.sequence = snapshot.sequence }
    }
    func slow(params: TextSession.SlowParams.Reader, on connection: isolated RPCConnection) async throws -> TextSession.SlowResults.Value {
        // The current core does not notify handlers of a remote Finish.
        // This demo proves caller cancellation, not server work cancellation.
        _ = try await observer.event { $0.setMessage("Slow request started"); $0.sequence = UInt32.max }
        try await Task.sleep(for: .milliseconds(Int64(min(params.delayMillis, 3000))))
        return try .init { $0.completed = true }
    }
}
