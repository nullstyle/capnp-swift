@_spi(Generated) import Capnp
@_spi(Generated) @testable import CapnpRPC
import TypedExternal
import Foundation
import Dispatch
import Synchronization

struct PipelineFailure: Error { let name: String }
func pipelineCheck(_ result: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try result() else { throw PipelineFailure(name: name) }
    print("PASS: \(name)")
}
func pipelineObserve(_ name: String, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw PipelineFailure(name: name) }
        try await Task.sleep(for: .milliseconds(1))
    }
}
final class PipelineGate: Sendable {
    private struct State { var open = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())
    var isOpen: Bool { state.withLock { $0.open } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
final class PipelineRecorder: Transport, Sendable {
    private final class Frames: Sendable { let values = Mutex<[[UInt8]]>([]) }
    private final class Receiver: TransportDelegate, @unchecked Sendable {
        weak var delegate: (any TransportDelegate)?
        let frames: Frames
        init(_ delegate: any TransportDelegate, frames: Frames) { self.delegate = delegate; self.frames = frames }
        func transportDidReceive(_ bytes: [UInt8]) { frames.values.withLock { $0.append(bytes) }; delegate?.transportDidReceive(bytes) }
        func transportDidClose(error: (any Error)?) { delegate?.transportDidClose(error: error) }
    }
    let base: any Transport
    private let receiver = Mutex<Receiver?>(nil)
    private let incoming = Frames()
    private let outgoing = Frames()
    init(_ base: any Transport) { self.base = base }
    func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        let proxy = Receiver(delegate, frames: incoming)
        receiver.withLock { $0 = proxy }; base.start(queue: queue, delegate: proxy)
    }
    func open() async throws { try await base.open() }
    func send(_ bytes: [UInt8], completion: @escaping @Sendable () -> Void) { outgoing.values.withLock { $0.append(bytes) }; base.send(bytes, completion: completion) }
    func pauseReceiving() { base.pauseReceiving() }
    func resumeReceiving() { base.resumeReceiving() }
    func cancel() { base.cancel() }
    private func count(_ frames: Frames, tag: UInt16) -> Int {
        frames.values.withLock { $0.filter { (try? Message(bytes: $0).rootStruct().readUInt16(at: 0)) == tag }.count }
    }
    var sentCalls: Int { count(outgoing, tag: 2) }
    var receivedCalls: Int { count(incoming, tag: 2) }
    var sentFinishes: Int { count(outgoing, tag: 4) }
}
struct PipelinePair {
    let client: RPCConnection
    let server: RPCConnection
    let cap: CapRef
    let clientWire: PipelineRecorder
    let serverWire: PipelineRecorder
    init(_ handler: any ExportHandler, options: RPCConnection.Options = .init()) async throws {
        let (a,b) = LoopbackTransport.pair()
        clientWire = PipelineRecorder(a); serverWire = PipelineRecorder(b)
        var bounded = options
        if bounded.callTimeout == nil { bounded.callTimeout = .seconds(12) }
        server = try await RPCConnection.connect(transport: serverWire, bootstrap: handler, options: bounded)
        client = try await RPCConnection.connect(transport: clientWire, options: bounded)
        cap = try await client.bootstrap()
    }
    func close() async { await client.close(); _ = await server.waitClosed() }
}
struct PipelineSink: PSink.TypedServer {
    let prefix: String
    func echo(params: PSink.Typed.EchoParams.Reader, on connection: isolated RPCConnection) async throws -> PSink.Typed.EchoResults.Value { try .init { $0.setValue(prefix + (try params.value())) } }
}
final class PipelineFactory: PFactory.TypedServer, Sendable {
    struct State { var makes = 0; var returned = 0; var accepts = 0; var streams: [PointerReader] = []; var echoOrder: [String] = []; var canceled = false }
    let state = Mutex(State())
    let makeGate: PipelineGate?
    let streamGate: PipelineGate?
    let echoGate: PipelineGate?
    let echoResultGate: PipelineGate?
    let sleeps: Bool
    init(makeGate: PipelineGate? = nil, streamGate: PipelineGate? = nil, echoGate: PipelineGate? = nil, echoResultGate: PipelineGate? = nil, sleeps: Bool = false) {
        self.makeGate = makeGate; self.streamGate = streamGate; self.echoGate = echoGate; self.echoResultGate = echoResultGate; self.sleeps = sleeps
    }
    private func delay() async throws {
        state.withLock { $0.makes += 1 }
        if sleeps {
            do { try await Task.sleep(for: .seconds(600)) }
            catch { state.withLock { $0.canceled = true }; throw error }
        }
        if let makeGate { await makeGate.wait() }
        state.withLock { $0.returned += 1 }
    }
    private func sink(on connection: RPCConnection) -> PSink.Typed.Client { PSink.Typed.Client(server: PipelineSink(prefix: "remote:"), connection: connection) }
    func make(params: PFactory.Typed.MakeParams.Reader, on connection: isolated RPCConnection) async throws -> PFactory.Typed.MakeResults.Value {
        try await delay(); return try .init { try $0.setSink(sink(on: connection)) }
    }
    func nested(params: PFactory.Typed.NestedParams.Reader, on connection: isolated RPCConnection) async throws -> PFactory.Typed.NestedResults.Value {
        try await delay(); return try .init { try $0.initNested().initBox().setValue(sink(on: connection)) }
    }
    func nullable(params: PFactory.Typed.NullableParams.Reader, on connection: isolated RPCConnection) async throws -> PFactory.Typed.NullableResults.Value { try .init() }
    func echo(params: PFactory.Typed.EchoParams<CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws -> PFactory.Typed.EchoResults<CapnpAnyPointer>.Value {
        if let echoResultGate { await echoResultGate.wait() }
        if let echoGate {
            let value = try CapnpText.read(from: params.value())
            let first = state.withLock { $0.echoOrder.append(value); return $0.echoOrder.count == 1 }
            if first { await echoGate.wait() }
        }
        return try .init { try $0.setValue(params.value()) }
    }
    func accept(params: PFactory.Typed.AcceptParams.Reader, on connection: isolated RPCConnection) async throws -> PFactory.Typed.AcceptResults.Value {
        state.withLock { $0.accepts += 1 }
        guard let sink = try params.sink() else { throw PipelineFailure(name: "future argument became null") }
        let result = try await sink.echo { $0.setValue(try params.value()) }
        return try .init { $0.setValue(try result.value()) }
    }
    func shapes(params: PFactory.Typed.ShapesParams.Reader, on connection: isolated RPCConnection) async throws -> PFactory.Typed.ShapesResults.Value {
        let sink = sink(on: connection)
        return try .init { builder in try builder.setList([sink, nil]); try builder.initChoice().setCap(sink) }
    }
    func stream(params: PFactory.Typed.StreamParams<CapnpAnyPointer>.Reader, on connection: isolated RPCConnection) async throws {
        let value = try params.value()
        let first = state.withLock { $0.streams.append(value); return $0.streams.count == 1 }
        if first, let streamGate { await streamGate.wait() }
    }
}
final class PipelineChild: PChild.TypedServer, Sendable {
    let values = Mutex<[String]>([])
    func push(params: PGeneric.Typed<CapnpText>.PushParams.Reader, on connection: isolated RPCConnection) async throws { let value = try params.value(); values.withLock { $0.append(value) } }
}
struct PipelineNamed: PNamed.TypedServer {
    func echo(params: PNInput.Typed.Reader, on connection: isolated RPCConnection) async throws -> PNOutput.Typed.Value { try .init { $0.setValue("echo:" + (try params.value())) } }
    func sendEcho(params: PNInput.Typed.Reader, on connection: isolated RPCConnection) async throws -> PNOutput.Typed.Value { try .init { $0.setValue("wire:" + (try params.value())) } }
}

@main enum VerifyTypedPipelines {
    static func native(_ nested: Bool) async throws {
        let gate = PipelineGate(), factory = PipelineFactory(makeGate: gate)
        let pair = try await PipelinePair(PFactory.Typed.Export(factory))
        do {
            let client = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            let sink: PSink.Typed.Client
            var retained: (any Sendable)?
            if nested { let call = try await client.sendNested(); sink = call.pipeline.nested.box.value(); retained = call }
            else { let call = try await client.sendMake(); sink = call.pipeline.sink; retained = call }
            try await pipelineObserve("factory entered held result") { factory.state.withLock { $0.makes == 1 } }
            let sending = Task { try await sink.sendEcho { $0.setValue("before return") } }
            try await pipelineObserve(nested ? "nested typed native pipeline emits CALL before RETURN" : "typed native pipeline emits CALL before RETURN") { pair.serverWire.receivedCalls == 2 }
            let reply = try await sending.value
            try pipelineCheck(pair.clientWire.sentCalls == 2 && !gate.isOpen && factory.state.withLock { $0.returned == 0 }, nested ? "nested typed native pipeline emits CALL before RETURN" : "typed native pipeline emits CALL before RETURN")
            gate.release()
            let value = try await reply.value()
            try pipelineCheck((try value.value()) == "remote:before return" && retained != nil, nested ? "nested pointer-field transforms reach the returned capability" : "typed native pipeline reaches the returned capability")
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
    }
    static func waitThenPass() async throws {
        let gate = PipelineGate(), factory = PipelineFactory(makeGate: gate)
        let pair = try await PipelinePair(PFactory.Typed.Export(factory))
        do {
            let client = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            let source = try await client.sendMake(), projected = source.pipeline.sink
            guard let id = source.pending.pending.remote?.qid else { throw PipelineFailure(name: "expected native question") }
            let passed = Task { try await client.accept { try $0.setSink(projected); $0.setValue("passed") } }
            try await pipelineObserve("future argument awaits its original question") { await pair.client.pointerQuestionWaiterCount(id) == 1 }
            try pipelineCheck(pair.clientWire.sentCalls == 1 && pair.serverWire.receivedCalls == 1 && factory.state.withLock { $0.accepts == 0 } && !gate.isOpen, "typed future arguments wait before passing under H9")
            gate.release()
            let reply = try await passed.value
            try pipelineCheck((try reply.value()) == "remote:passed" && factory.state.withLock { $0.accepts == 1 }, "typed future arguments arrive as callable resolved capabilities")
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
    }
    static func genericOwnership() async throws {
        let pair = try await PipelinePair(PFactory.Typed.Export(PipelineFactory()))
        do {
            let client = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            func retained() async throws -> PSink.Typed.Client {
                let own = PSink.Typed.Client(server: PipelineSink(prefix: "owned:"), connection: pair.client)
                let outer = PSink.Typed.Client(server: PipelineSink(prefix: "outer:"), connection: pair.client)
                let call = try await client.sendEcho(as: TypedExternal.Outer.Typed<PSink.Typed>.Inner<PSink.Typed>.self) {
                    let value = $0.initValue(); try value.setOuter(outer); try value.setInner(own)
                }
                _ = try await call.value()
                return call.pipeline.value().inner()
            }
            let sink = try await retained()
            let result = try await sink.echo { $0.setValue("retained") }
            try pipelineCheck((try result.value()) == "owned:retained", "unseen external generic pipelines retain returned own capabilities")
            let own = PSink.Typed.Client(server: PipelineSink(prefix: "own:"), connection: pair.client)
            let direct = try await client.sendEcho(as: PSink.Typed.self) { try $0.setValue(own) }
            _ = try await direct.value()
            let answer = try await direct.pipeline.value().echo { $0.setValue("home") }
            try pipelineCheck((try answer.value()) == "own:home", "native pipelines resolve returned local handlers after RETURN")
        } catch { await pair.close(); throw error }
        await pair.close()
    }
    static func returnedOwnFutureArgument() async throws {
        let gate = PipelineGate(), factory = PipelineFactory(echoResultGate: gate)
        let pair = try await PipelinePair(PFactory.Typed.Export(factory))
        do {
            let client = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            let own = PSink.Typed.Client(server: PipelineSink(prefix: "own future:"), connection: pair.client)
            let source = try await client.sendEcho(as: PSink.Typed.self) { try $0.setValue(own) }
            guard let id = source.pending.pending.remote?.qid else { throw PipelineFailure(name: "expected returned-own future question") }
            let passed = Task { try await client.accept { try $0.setSink(source.pipeline.value()); $0.setValue("passed") } }
            try await pipelineObserve("own future argument waits for source RETURN") { await pair.client.pointerQuestionWaiterCount(id) == 1 }
            guard pair.clientWire.sentCalls == 1 && !gate.isOpen else { throw PipelineFailure(name: "returned-own future bypassed H9 wait") }
            gate.release()
            let result = await passed.result
            let valid: Bool
            switch result {
            case .success(let reply): valid = (try reply.value()) == "own future:passed"
            case .failure: valid = false
            }
            try pipelineCheck(valid, "typed future arguments materialize returned local handlers before passing")
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
    }
    static func local() async throws {
        let pair = try await PipelinePair(PFactory.Typed.Export(PipelineFactory()))
        let gate = PipelineGate(), factory = PipelineFactory(makeGate: gate)
        do {
            let client = PFactory.Typed.Client(server: factory, connection: pair.client)
            let pending = try await client.sendMake()
            let projected = pending.pipeline.sink
            let answer = Task { try await projected.echo { $0.setValue("local") } }
            try await pipelineObserve("local factory starts without wire export") { factory.state.withLock { $0.makes == 1 } }
            try pipelineCheck(pair.clientWire.sentCalls == 0 && factory.state.withLock { $0.returned == 0 }, "local pending pipelines await owned handlers without wire exports")
            gate.release()
            let result = try await answer.value
            let aliases = await pair.client.pointerLocalAliasCount
            try pipelineCheck((try result.value()) == "remote:local" && aliases == 0, "local pending pipelines return callable handlers and clean aliases")
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
    }
    static func lifetime() async throws {
        let gate = PipelineGate(), factory = PipelineFactory(makeGate: gate)
        let pair = try await PipelinePair(PFactory.Typed.Export(factory))
        do {
            let client = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            func child() async throws -> PSink.Typed.Client.EchoCall {
                let source = try await client.sendMake()
                return try await source.pipeline.sink.sendEcho { $0.setValue("lifetime") }
            }
            let priorFinishes = pair.clientWire.sentFinishes
            let child = try await child()
            try await pipelineObserve("child native CALL reaches peer") { pair.serverWire.receivedCalls == 2 }
            try pipelineCheck(pair.clientWire.sentFinishes == priorFinishes && !gate.isOpen, "child calls retain their unresolved parent question")
            gate.release()
            let result = try await child.value()
            try pipelineCheck((try result.value()) == "remote:lifetime", "child calls survive dropping source call and projected client")
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
    }
    static func errorsAndFallbacks() async throws {
        let pair = try await PipelinePair(PFactory.Typed.Export(PipelineFactory()))
        do {
            let client = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            let empty = try await client.sendNullable(); _ = try await empty.value()
            var null = false
            do { _ = try await empty.pipeline.sink.echo() } catch let error as RPCError { if case .failed(let reason) = error { null = reason.contains("null") } }
            try pipelineCheck(null, "null capability projections fail explicitly after RETURN")
            let shapes = try await client.sendShapes(), result = try await shapes.value()
            guard let first = try result.list().first ?? nil, let choice = try result.choice().cap() else { throw PipelineFailure(name: "awaited shapes lost capabilities") }
            let a = try await first.echo { $0.setValue("list") }, b = try await choice.echo { $0.setValue("union") }
            try pipelineCheck((try a.value()) == "remote:list" && (try b.value()) == "remote:union", "lists and unions remain available through awaited typed results")
        } catch { await pair.close(); throw error }
        await pair.close()
    }
    static func localOrderingAndDrop() async throws {
        let pair = try await PipelinePair(PFactory.Typed.Export(PipelineFactory()))
        let gate = PipelineGate(), factory = PipelineFactory(echoGate: gate)
        do {
            let local = PFactory.Typed.Client(server: factory, connection: pair.client)
            let first = try await local.sendEcho(as: CapnpText.self) { try $0.setValue("first") }
            let second = try await local.sendEcho(as: CapnpText.self) { try $0.setValue("second") }
            try await pipelineObserve("both local sends entered handlers") { factory.state.withLock { $0.echoOrder.count == 2 } }
            try pipelineCheck(factory.state.withLock { $0.echoOrder } == ["first", "second"], "consecutive local sends preserve handler entry ordering")
            gate.release(); _ = try await first.value(); _ = try await second.value()
            let sleeping = PipelineFactory(sleeps: true)
            let sleeper = PFactory.Typed.Client(server: sleeping, connection: pair.client)
            var pending: PFactory.Typed.Client.MakeCall? = try await sleeper.sendMake()
            try await pipelineObserve("local pending handler started") { sleeping.state.withLock { $0.makes == 1 } }
            guard pending != nil else { throw PipelineFailure(name: "local pending call was missing") }
            pending = nil
            try await pipelineObserve("last local pending handle cancels handler") { sleeping.state.withLock { $0.canceled } }
            let aliases = await pair.client.pointerLocalAliasCount
            try pipelineCheck(sleeping.state.withLock { $0.canceled } && aliases == 0, "dropping the last local call handle cancels its task")
            try await pipelineObserve("completed and dropped local calls remove close observers") { await pair.client.pointerCloseWaiterCount == 0 }
            let observers = await pair.client.pointerCloseWaiterCount
            try pipelineCheck(observers == 0, "normal completion and last-handle drop remove local close observers")
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
    }
    static func namedSender() async throws {
        let pair = try await PipelinePair(PNamed.Typed.Export(PipelineNamed()))
        do {
            let client = try PNamed.Typed.Client(cap: pair.cap, connection: pair.client)
            let a = try await client.echo { $0.setValue("a") }
            let b = try await client.sendEcho { $0.setValue("b") }
            let c = try await client.sendEcho2 { $0.setValue("c") }
            let d = try await c.value()
            try pipelineCheck((try a.value()) == "echo:a" && (try b.value()) == "wire:b" && (try d.value()) == "echo:c", "pending sender names preserve named RPC method dispatch")
        } catch { await pair.close(); throw error }
        await pair.close()
    }
    static func localStop(_ closing: Bool) async throws {
        let pair = try await PipelinePair(PFactory.Typed.Export(PipelineFactory()))
        let gate = PipelineGate(), factory = PipelineFactory(makeGate: gate)
        do {
            let local = PFactory.Typed.Client(server: factory, connection: pair.client)
            let call = try await local.sendMake()
            let finished = Mutex(false)
            let waiter = Task { () -> RPCError? in
                defer { finished.withLock { $0 = true } }
                do { _ = try await call.value(); return nil }
                catch { return error as? RPCError }
            }
            try await pipelineObserve("local handler and close observer registered") {
                let observers = await pair.client.pointerCloseWaiterCount
                return factory.state.withLock { $0.makes == 1 } && observers == 1
            }
            if closing { await pair.client.close() } else { waiter.cancel() }
            let name = closing ? "connection closure wakes local pending values before handler completion" : "local value cancellation wakes before an uncooperative handler completes"
            try await pipelineObserve(name) { finished.withLock { $0 } }
            let error = await waiter.value
            let expected: Bool
            if closing, case .disconnected = error { expected = true }
            else { expected = !closing && error == .canceled }
            try pipelineCheck(expected && !gate.isOpen && factory.state.withLock { $0.returned == 0 }, name)
            try await pipelineObserve("canceled local call removes close observer") { await pair.client.pointerCloseWaiterCount == 0 }
            let observers = await pair.client.pointerCloseWaiterCount
            try pipelineCheck(observers == 0, closing ? "closed local calls remove their result observers" : "canceled local calls remove their result observers")
            gate.release()
            try await pipelineObserve("uncooperative local handler eventually finishes") { factory.state.withLock { $0.returned == 1 } }
            let aliases = await pair.client.pointerLocalAliasCount
            guard aliases == 0 else { throw PipelineFailure(name: "local stopped call leaked capability aliases") }
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
    }
    static func foreignFuture() async throws {
        let gate = PipelineGate(), factory = PipelineFactory(makeGate: gate)
        let source = try await PipelinePair(PFactory.Typed.Export(factory))
        let target = try await PipelinePair(PFactory.Typed.Export(PipelineFactory()))
        do {
            let a = try PFactory.Typed.Client(cap: source.cap, connection: source.client)
            let b = try PFactory.Typed.Client(cap: target.cap, connection: target.client)
            let call = try await a.sendMake()
            guard let id = call.pending.pending.remote?.qid else { throw PipelineFailure(name: "expected foreign future question") }
            let finished = Mutex(false)
            let passing = Task { () -> Bool in
                defer { finished.withLock { $0 = true } }
                do { _ = try await b.accept { try $0.setSink(call.pipeline.sink) }; return false }
                catch let error as RPCError { return error == .foreignCapability }
                catch { return false }
            }
            try await pipelineObserve("foreign future arguments are rejected before awaiting or sending") { finished.withLock { $0 } }
            let rejected = await passing.value
            let waiters = await source.client.pointerQuestionWaiterCount(id)
            try pipelineCheck(rejected && waiters == 0 && target.clientWire.sentCalls == 0 && !gate.isOpen, "foreign future arguments are rejected before awaiting or sending")
            gate.release(); _ = try await call.value()
        } catch { gate.release(); await source.close(); await target.close(); throw error }
        gate.release(); await source.close(); await target.close()
    }
    static func windowCancellationEdges() async throws {
        let window = StreamWindow(maxCalls: 0, maxBytes: 100)
        let start = PipelineGate()
        try await window.acquireThrowing(bytes: 100)
        let prefinished = Mutex(false)
        let precanceled = Task { () -> Bool in
            defer { prefinished.withLock { $0 = true } }
            await start.wait()
            do { try await window.acquireThrowing(bytes: 40); window.release(bytes: 40); return false }
            catch let error as RPCError { return error == .canceled }
            catch { return false }
        }
        precanceled.cancel(); start.release()
        try await pipelineObserve("stream cancellation before waiter registration consumes no permit") { prefinished.withLock { $0 } }
        let rejected = await precanceled.value
        try pipelineCheck(rejected && window.usageSnapshot().calls == 1 && window.usageSnapshot().bytes == 100 && window.usageSnapshot().waiters == 0, "stream cancellation before waiter registration consumes no permit")
        window.release(bytes: 100)
        try await window.acquireThrowing(bytes: 40); try await window.acquireThrowing(bytes: 40)
        let headFinished = Mutex(false)
        let head = Task { () -> Bool in
            defer { headFinished.withLock { $0 = true } }
            do { try await window.acquireThrowing(bytes: 70); window.release(bytes: 70); return false }
            catch let error as RPCError { return error == .canceled }
            catch { return false }
        }
        try await pipelineObserve("oversized queued head registered") { window.usageSnapshot().waiters == 1 }
        let followerGate = PipelineGate(), followerEntered = Mutex(false)
        let follower = Task {
            try await window.acquireThrowing(bytes: 30)
            defer { window.release(bytes: 30) }
            followerEntered.withLock { $0 = true }; await followerGate.wait()
        }
        try await pipelineObserve("queued follower registered") { window.usageSnapshot().waiters == 2 }
        window.release(bytes: 40)
        head.cancel()
        try await pipelineObserve("canceling a blocked stream head admits a fitting queued follower") { headFinished.withLock { $0 } }
        let canceled = await head.value
        try await pipelineObserve("canceling queued head admits an eligible follower") { followerEntered.withLock { $0 } }
        let usage = window.usageSnapshot()
        try pipelineCheck(canceled && usage.calls == 2 && usage.bytes == 70 && usage.waiters == 0, "canceling a blocked stream head admits a fitting queued follower")
        followerGate.release(); try await follower.value; window.release(bytes: 40)
        guard window.usageSnapshot().calls == 0 && window.usageSnapshot().bytes == 0 else { throw PipelineFailure(name: "follower window permits leaked") }

        struct Activity { var active = 0; var maximum = 0; var unexpectedError = false }
        let activity = Mutex(Activity())
        let raced = StreamWindow(maxCalls: 1, maxBytes: 8)
        for _ in 0..<8 {
            try await raced.acquireThrowing(bytes: 8)
            let finished = Mutex(0)
            let workers = (0..<16).map { _ in Task {
                defer { finished.withLock { $0 += 1 } }
                do {
                    try await raced.acquireThrowing(bytes: 8)
                    defer { raced.release(bytes: 8) }
                    activity.withLock { $0.active += 1; $0.maximum = max($0.maximum, $0.active) }
                    defer { activity.withLock { $0.active -= 1 } }
                    try await Task.sleep(for: .milliseconds(1))
                } catch let error as RPCError {
                    if error != .canceled { activity.withLock { $0.unexpectedError = true } }
                } catch is CancellationError {} catch { activity.withLock { $0.unexpectedError = true } }
            } }
            try await pipelineObserve("grant cancellation race workers queued") { raced.usageSnapshot().waiters == 16 }
            let canceler = Task { for index in stride(from: 0, to: workers.count, by: 2) { workers[index].cancel(); await Task.yield() } }
            raced.release(bytes: 8)
            await canceler.value
            try await pipelineObserve("stream grant and cancellation races preserve one permit owner") { finished.withLock { $0 == 16 } }
            for worker in workers { await worker.value }
        }
        let balanced = raced.usageSnapshot()
        try pipelineCheck(activity.withLock { $0.maximum == 1 && $0.active == 0 && !$0.unexpectedError } && balanced.calls == 0 && balanced.bytes == 0 && balanced.waiters == 0, "stream grant and cancellation races preserve one permit owner")
    }
    static func streamWindow(_ mode: String) async throws {
        let gate = PipelineGate(), factory = PipelineFactory(streamGate: gate)
        var options = RPCConnection.Options(); options.streamWindowMaxCalls = mode == "bytes" ? 0 : 1
        let byteCount = try PFactory.Typed.StreamParams<CapnpText>.Value { try $0.setValue("first") }.pointer.serialized().bytes.count
        options.streamWindowMaxBytes = mode == "oversize" ? byteCount - 1 : (mode == "bytes" ? byteCount : 0)
        let pair = try await PipelinePair(PFactory.Typed.Export(factory), options: options)
        do {
            let client = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            if mode == "oversize" {
                let finished = Mutex(false)
                let oversized = Task { () -> Bool in
                    defer { finished.withLock { $0 = true } }
                    do { try await client.stream(as: CapnpText.self) { try $0.setValue("first") }; return false }
                    catch let error as RPCError { if case .overloaded(let reason) = error { return reason.contains("larger than") }; return false }
                    catch { return false }
                }
                try await pipelineObserve("typed streams reject oversized payloads without parking") { finished.withLock { $0 } }
                let rejected = await oversized.value
                try pipelineCheck(rejected && pair.clientWire.sentCalls == 0 && pair.client.streamWindow.usageSnapshot().waiters == 0, "typed streams reject oversized payloads without parking")
            } else {
                let first = Task { try await client.stream(as: CapnpText.self) { try $0.setValue("first") } }
                try await pipelineObserve("first stream reached its handler") { factory.state.withLock { $0.streams.count == 1 } }
                let secondFinished = Mutex(false)
                let second = Task { defer { secondFinished.withLock { $0 = true } }; try await client.stream(as: CapnpText.self) { try $0.setValue("later") } }
                try await pipelineObserve(mode == "bytes" ? "typed streaming byte bounds wait for acknowledgement" : "typed streaming call bounds wait for acknowledgement") { pair.client.streamWindow.usageSnapshot().waiters == 1 }
                if mode == "cancel" {
                    second.cancel()
                    try await pipelineObserve("queued typed stream cancellation removes only its waiter") { secondFinished.withLock { $0 } }
                    var canceled = false
                    do { try await second.value } catch let error as RPCError { canceled = error == .canceled }
                    try pipelineCheck(canceled && pair.client.streamWindow.usageSnapshot().waiters == 0 && pair.client.streamWindow.usageSnapshot().calls == 1, "queued typed stream cancellation removes only its waiter")
                    gate.release(); try await first.value
                } else if mode == "close" {
                    await pair.client.close()
                    try await pipelineObserve("connection closure wakes queued typed stream callers") { secondFinished.withLock { $0 } }
                    var closed = false
                    do { try await second.value } catch let error as RPCError { if case .disconnected = error { closed = true } }
                    gate.release(); _ = await first.result
                    try pipelineCheck(closed && pair.client.streamWindow.usageSnapshot().waiters == 0 && pair.client.streamWindow.usageSnapshot().calls == 0, "connection closure wakes queued typed stream callers")
                } else {
                    try pipelineCheck(pair.clientWire.sentCalls == 1 && factory.state.withLock { $0.streams.count == 1 }, mode == "bytes" ? "typed streaming byte bounds wait for acknowledgement" : "typed streaming call bounds wait for acknowledgement")
                    gate.release(); try await first.value; try await second.value
                    try pipelineCheck(factory.state.withLock { $0.streams.count == 2 } && pair.client.streamWindow.usageSnapshot().calls == 0 && pair.client.streamWindow.usageSnapshot().bytes == 0, mode == "bytes" ? "stream byte acknowledgements release window permits" : "stream call acknowledgements release window permits")
                }
            }
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
    }
    static func inheritedAndActorStreams() async throws {
        let child = PipelineChild(), pair = try await PipelinePair(PChild.Typed.Export(child))
        do {
            let client = try PChild.Typed.Client(cap: pair.cap, connection: pair.client).pGeneric
            try await client.push { try $0.setValue("inherited") }
            try pipelineCheck(child.values.withLock { $0 } == ["inherited"], "typed streaming preserves inherited outer bindings")
        } catch { await pair.close(); throw error }
        await pair.close()
        let factory = PipelineFactory(), p = try await PipelinePair(PFactory.Typed.Export(factory))
        @MainActor final class UI {
            var value = "UI stream"
            func send(_ client: PFactory.Typed.Client) async throws { try await client.stream(as: CapnpText.self) { MainActor.assertIsolated(); try $0.setValue(self.value) } }
        }
        do {
            let client = try PFactory.Typed.Client(cap: p.cap, connection: p.client), ui = UI()
            try await ui.send(client)
            let recorded = factory.state.withLock { $0.streams }
            try pipelineCheck(recorded.count == 1 && (try CapnpText.read(from: recorded[0])) == "UI stream", "typed streaming request builders preserve caller actor isolation")
        } catch { await p.close(); throw error }
        await p.close()
    }
    static func closeWithHeldPermit() async throws {
        var options = RPCConnection.Options(); options.streamWindowMaxCalls = 1
        let pair = try await PipelinePair(PFactory.Typed.Export(PipelineFactory()), options: options)
        await pair.client.streamWindow.acquire(bytes: 1)
        do {
            let client = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            let finished = Mutex(false)
            let blocked = Task { () -> Bool in
                defer { finished.withLock { $0 = true } }
                do { try await client.stream(as: CapnpText.self) { try $0.setValue("closed") }; return false }
                catch let error as RPCError { if case .disconnected = error { return true }; return false }
                catch { return false }
            }
            try await pipelineObserve("stream waiting behind a retained permit") { pair.client.streamWindow.usageSnapshot().waiters == 1 }
            await pair.client.close()
            let name = "connection closure wakes stream waiters while another caller retains its permit"
            try await pipelineObserve(name) { finished.withLock { $0 } }
            let closed = await blocked.value
            let usage = pair.client.streamWindow.usageSnapshot()
            try pipelineCheck(closed && usage.calls == 1 && usage.bytes == 1 && usage.waiters == 0 && pair.clientWire.sentCalls == 0, name)
        } catch { pair.client.streamWindow.release(bytes: 1); await pair.close(); throw error }
        pair.client.streamWindow.release(bytes: 1); await pair.close()
    }
    static func localDeadline() async throws {
        var options = RPCConnection.Options(); options.callTimeout = .milliseconds(40); options.tickInterval = .milliseconds(5)
        let pair = try await PipelinePair(PFactory.Typed.Export(PipelineFactory(sleeps: true)), options: options)
        let gate = PipelineGate(), local = PipelineFactory(makeGate: gate)
        do {
            let imported = try PFactory.Typed.Client(cap: pair.cap, connection: pair.client)
            var nativeDeadline = false
            do { _ = try await imported.make() }
            catch let error as RPCError { nativeDeadline = error == .overloaded(reason: "deadline exceeded") }
            let client = PFactory.Typed.Client(server: local, connection: pair.client)
            let call = try await client.sendMake(), finished = Mutex(false)
            let waiting = Task { () -> Bool in
                defer { finished.withLock { $0 = true } }
                do { _ = try await call.value(); return false }
                catch let error as RPCError { return error == .overloaded(reason: "deadline exceeded") }
                catch { return false }
            }
            let name = "local pending calls honor the configured RPC deadline"
            try await pipelineObserve(name) { finished.withLock { $0 } }
            let timedOut = await waiting.value
            try pipelineCheck(nativeDeadline && timedOut && !gate.isOpen && local.state.withLock { $0.returned == 0 }, name)
            gate.release()
            let cooperative = PipelineFactory(sleeps: true)
            let sleeping = PFactory.Typed.Client(server: cooperative, connection: pair.client)
            var canceledDeadline = false
            do { _ = try await sleeping.make() }
            catch let error as RPCError { canceledDeadline = error == .overloaded(reason: "deadline exceeded") }
            try await pipelineObserve("deadline cancels local handler and close observer") {
                let observers = await pair.client.pointerCloseWaiterCount
                return cooperative.state.withLock { $0.canceled } && observers == 0
            }
            let observers = await pair.client.pointerCloseWaiterCount
            try pipelineCheck(canceledDeadline && cooperative.state.withLock { $0.canceled } && observers == 0, "local deadlines cancel handlers and remove result observers")
        } catch { gate.release(); await pair.close(); throw error }
        gate.release(); await pair.close()
        for timeout in [Duration.zero, .microseconds(500)] {
            let held = PipelineGate(), factory = PipelineFactory(makeGate: held)
            var unbounded = RPCConnection.Options(); unbounded.callTimeout = timeout; unbounded.tickInterval = .milliseconds(5)
            let p = try await PipelinePair(PFactory.Typed.Export(factory), options: unbounded)
            do {
                let remote = try PFactory.Typed.Client(cap: p.cap, connection: p.client)
                let local = PFactory.Typed.Client(server: factory, connection: p.client)
                let a = try await remote.sendMake(), b = try await local.sendMake()
                try await pipelineObserve("unbounded local and native handlers entered") { factory.state.withLock { $0.makes == 2 } }
                try await Task.sleep(for: .milliseconds(40)); held.release()
                let remoteValue = try await a.value(), localValue = try await b.value()
                try pipelineCheck((try remoteValue.sink()) != nil && (try localValue.sink()) != nil, timeout == .zero ? "zero RPC deadlines leave local and native pending calls unbounded" : "sub-millisecond RPC deadlines preserve native disabled semantics")
            } catch { held.release(); await p.close(); throw error }
            held.release(); await p.close()
        }
    }
    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { FileHandle.standardError.write(Data("PIPELINE_FAIL: watchdog expired\n".utf8)); exit(1) }
        do {
            try await native(false); try await native(true); try await waitThenPass(); try await returnedOwnFutureArgument(); try await genericOwnership(); try await local(); try await lifetime(); try await errorsAndFallbacks(); try await localOrderingAndDrop(); try await namedSender()
            try await localStop(false); try await localStop(true); try await foreignFuture(); try await windowCancellationEdges()
            for mode in ["calls", "bytes", "oversize", "cancel", "close"] { try await streamWindow(mode) }
            try await closeWithHeldPermit()
            try await localDeadline()
            try await inheritedAndActorStreams()
        } catch { FileHandle.standardError.write(Data("PIPELINE_FAIL: \(error)\n".utf8)); exit(1) }
    }
}
