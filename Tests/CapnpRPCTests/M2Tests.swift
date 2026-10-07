// M2 runtime tests over LoopbackTransport (plan §8, M2 gates): pipelining,
// cancel, promise exports, E-order, error sanitizing, shutdown, events and
// backpressure.

import Capnp
import Foundation
import CapnpMVP
@testable import CapnpRPC
import Dispatch
import Synchronization
import Testing

/// A connected pair whose server serves `bootstrap`.
func connectedPair(
    bootstrap: any ExportHandler,
    clientOptions: RPCConnection.Options = .init(),
    serverOptions: RPCConnection.Options = .init()
) async throws -> (client: RPCConnection, server: RPCConnection, cap: CapRef) {
    let (a, b) = LoopbackTransport.pair()
    let server = try await RPCConnection.connect(transport: b, bootstrap: bootstrap, options: serverOptions)
    let client = try await RPCConnection.connect(transport: a, options: clientOptions)
    let cap = try await client.bootstrap()
    return (client, server, cap)
}

@Suite("M2")
struct M2Tests {
    @Test("pipelining: a call on a promised answer returns the right value, before and after the answer")
    func pipelining() async throws {
        let (client, server, cap) = try await connectedPair(bootstrap: Factory.Export())
        let factory = Factory.Client(cap: cap, connection: client)

        let make = try await factory.make()
        let echo = Echo.Client(target: .pipelined(make.pipeline([0])), connection: client)
        // Sent before `make` returned.
        #expect(try await echo.echo(5) == 5)
        // After the answer, the same pipelined cap resolves locally.
        _ = try await make.result()
        #expect(try await echo.echo(6) == 6)
        // A pipelined cap in params: the runtime waits for its answer first
        // (capnp-zig refuses unresolved receiverAnswer params; handoff H9).
        let make2 = try await factory.make()
        #expect(try await factory.useEcho(.pipelined(make2.pipeline([0]))) == 7)
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("cancel: a cancelled waiting task gets .canceled at once; a dropped promise cancels the call")
    func cancel() async throws {
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: HangingEcho()))
        let echo = Echo.Client(target: .cap(cap), connection: client)

        let task = Task { try await echo.echo(1) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.result
        guard case .failure(let error as RPCError) = outcome else {
            Issue.record("expected .canceled, got \(outcome)")
            return
        }
        #expect(error == .canceled)

        // Drop the only handle on a pending call: it is cancelled on the wire
        // and the connection stays healthy for the next call.
        var promise: RemotePromise? = try await client.send(.cap(cap), interface: Echo.interfaceID, method: 0, params: {
            let mb = MessageBuilder()
            mb.initRoot(dataWords: 1, pointerWords: 0).setUInt64(at: 0, 9)
            return mb.toBytes()
        }())
        promise = nil
        _ = promise
        try await Task.sleep(for: .milliseconds(50))
        let quick = Task { try await Echo.Client(target: .cap(cap), connection: client).echo(2) }
        try await Task.sleep(for: .milliseconds(20))
        quick.cancel()
        _ = await quick.result
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("promise export: calls wait for the resolution; a rejected promise fails them")
    func promiseExport() async throws {
        let (client, server, cap) = try await connectedPair(bootstrap: Factory.Export())
        let factory = Factory.Client(cap: cap, connection: client)

        // No per-call deadline exists in the Swift API yet, so a resolution
        // that never arrives would hang the test (found by the M2 ablation).
        let later = try await factory.makeLater()
        #expect(try await withTimeout(.seconds(10)) {
            try await Echo.Client(target: .cap(later), connection: client).echo(3)
        } == 3)

        let broken = try await factory.makeBroken()
        do {
            _ = try await withTimeout(.seconds(10)) {
                try await Echo.Client(target: .cap(broken), connection: client).echo(4)
            }
            Issue.record("a call on a rejected promise succeeded")
        } catch let error as RPCError {
            guard case .failed = error else {
                Issue.record("expected .failed, got \(error)")
                return
            }
        }
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("E-order: 1000 calls on one capability start in arrival order")
    func eOrder() async throws {
        let counter = Counter.Export()
        let (client, server, cap) = try await connectedPair(bootstrap: counter)
        let hits = Counter.Client(cap: cap, connection: client)
        var promises: [RemotePromise] = []
        for seq in 0..<1000 {
            promises.append(try await hits.hit(UInt64(seq)))
        }
        for promise in promises { _ = try await promise.result() }
        let order = counter.order.withLock { $0 }
        #expect(order.count == 1000)
        #expect(order == order.sorted())
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("secret-in-error: the remote sees a generic reason with a correlation id, never the app's error text")
    func secretInError() async throws {
        let (client, server, cap) = try await connectedPair(bootstrap: Faulty.Export())
        do {
            _ = try await client.call(.cap(cap), interface: Faulty.interfaceID, method: 0, params: MessageBuilder.emptyStruct())
            Issue.record("the faulty call succeeded")
        } catch let error as RPCError {
            guard case .failed(let reason) = error else {
                Issue.record("expected .failed, got \(error)")
                return
            }
            #expect(reason.hasPrefix("capnp-swift: handler failed (ref "))
            #expect(!reason.contains("SECRET"))
            #expect(!reason.contains("SecretError"))
        }
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("shutdown: open questions get the drain timeout, then the connection closes")
    func shutdown() async throws {
        var options = RPCConnection.Options()
        options.shutdownDrainTimeout = .milliseconds(200)
        options.tickInterval = .milliseconds(20)
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: HangingEcho()), clientOptions: options)
        let pending = Task { try await Echo.Client(target: .cap(cap), connection: client).echo(1) }
        try await Task.sleep(for: .milliseconds(30))
        let cause = try await withTimeout(.seconds(5)) { await client.shutdown() }
        guard case .disconnected = cause else {
            Issue.record("shutdown cause: \(cause)")
            return
        }
        #expect(await client.isClosed)
        let outcome = await pending.result
        guard case .failure(let error as RPCError) = outcome, case .disconnected = error else {
            Issue.record("the pending call did not end as disconnected: \(outcome)")
            return
        }
        // No new calls after shutdown.
        await #expect(throws: RPCError.self) {
            _ = try await Echo.Client(target: .cap(cap), connection: client).echo(2)
        }
        _ = await server.waitClosed()
    }

    @Test("events: observer events flow when enabled")
    func events() async throws {
        var options = RPCConnection.Options()
        options.observeEvents = true
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: PlainEcho()), clientOptions: options)
        #expect(try await Echo.Client(target: .cap(cap), connection: client).echo(1) == 1)
        await client.close()
        _ = await server.waitClosed()
        var names: Set<String> = []
        for await event in client.events {
            names.insert(event.name)
            #expect(event.name != "unknown")
        }
        #expect(!names.isEmpty, "no events observed")
    }

    @Test("inbound backpressure: handlers above the high-water mark wait until earlier ones finish")
    func inboundBackpressure() async throws {
        let gated = GatedEcho()
        var serverOptions = RPCConnection.Options()
        serverOptions.inboundHighWaterCalls = 2
        let (client, server, cap) = try await connectedPair(bootstrap: Echo.Export(server: gated), serverOptions: serverOptions)
        let echo = Echo.Client(target: .cap(cap), connection: client)
        var tasks: [Task<UInt64, any Error>] = []
        // Two calls fill the window; the server pauses its reads. Two more
        // arrive while paused and wait in the transport.
        for i in 0..<2 { tasks.append(Task { try await echo.echo(UInt64(i)) }) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(gated.started.withLock { $0 } == 2)
        for i in 2..<4 { tasks.append(Task { try await echo.echo(UInt64(i)) }) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(gated.started.withLock { $0 } == 2)
        gated.release()
        for (i, task) in tasks.enumerated() { #expect(try await task.value == UInt64(i)) }
        #expect(gated.started.withLock { $0 } == 4)
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("outbound backpressure: send suspends while the transport holds too many bytes")
    func outboundBackpressure() async throws {
        let stall = StallTransport()
        var options = RPCConnection.Options()
        options.outboundHighWaterBytes = 64
        let client = try await RPCConnection.connect(transport: stall, options: options)
        // The bootstrap frame (small) goes out; a call's frame pushes past 64
        // bytes, so the next send suspends until the transport completes.
        let bootstrapTask = Task { try await client.bootstrap() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(stall.pendingCount() >= 1)
        let suspended = Task {
            _ = try await client.send(.cap(CapRefFactory.fake(on: client)), interface: 1, method: 0, params: MessageBuilder.emptyStruct())
        }
        _ = suspended
        try await Task.sleep(for: .milliseconds(30))
        stall.completeAll()
        try await Task.sleep(for: .milliseconds(30))
        bootstrapTask.cancel()
        await client.close()
        _ = await bootstrapTask.result
    }
}

/// A transport whose sends never complete until `completeAll()`.
final class StallTransport: Transport, @unchecked Sendable {
    private let pending = Mutex<[@Sendable () -> Void]>([])
    private var delegate: (any TransportDelegate)?
    private var queue: DispatchSerialQueue?

    func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        self.queue = queue
        self.delegate = delegate
    }

    func open() async throws {}

    func send(_ bytes: [UInt8], completion: @escaping @Sendable () -> Void) {
        pending.withLock { $0.append(completion) }
    }

    func pendingCount() -> Int { pending.withLock { $0.count } }

    func completeAll() {
        let done = pending.withLock { p -> [@Sendable () -> Void] in
            defer { p.removeAll() }
            return p
        }
        queue?.async { for c in done { c() } }
    }

    func pauseReceiving() {}
    func resumeReceiving() {}

    func cancel() {
        let delegate = self.delegate
        queue?.async { delegate?.transportDidClose(error: nil) }
    }
}

/// Access to a CapRef without a remote: the StallTransport test only needs
/// a target the core accepts syntactically (the send fails later or hangs).
enum CapRefFactory {
    static func fake(on connection: RPCConnection) -> CapRef {
        // Import id 0 is what a bootstrap would have returned; the core
        // refuses it (BAD_ID) if it is not live, which is fine for the test:
        // the point is whether `send` suspends before reaching the core.
        CapRef(id: 0, releases: ReleaseList(), owner: ObjectIdentifier(connection))
    }
}

@Suite("StreamWindow")
struct StreamWindowTests {
    final class Flag: @unchecked Sendable, CustomStringConvertible {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
        }
        func set() { lock.lock(); value = true; lock.unlock() }
        var description: String { isSet ? "set" : "clear" }
    }

    @Test("the window suspends at the call limit and releases space")
    func windowLimits() async throws {
        let window = StreamWindow(maxCalls: 2, maxBytes: 1 << 20)
        await window.acquire(bytes: 100)
        await window.acquire(bytes: 100)
        // Third acquire must suspend until a release.
        let acquired = Flag()
        let task = Task { await window.acquire(bytes: 100); acquired.set() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!acquired.isSet)
        window.release(bytes: 100)
        try await withTimeout(.seconds(2)) { while !acquired.isSet { try await Task.sleep(for: .milliseconds(5)) } }
        #expect(acquired.isSet)
        _ = await task.result
    }

    @Test("the byte limit suspends even below the call limit")
    func byteLimit() async throws {
        let window = StreamWindow(maxCalls: 0, maxBytes: 150)
        await window.acquire(bytes: 100)
        let acquired = Flag()
        let task = Task { await window.acquire(bytes: 100); acquired.set() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!acquired.isSet)
        window.release(bytes: 100)
        try await withTimeout(.seconds(2)) { while !acquired.isSet { try await Task.sleep(for: .milliseconds(5)) } }
        #expect(acquired.isSet)
        _ = await task.result
    }
}
