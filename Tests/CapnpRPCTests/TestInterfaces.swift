// Hand-written test interfaces for the M2 runtime tests (no schema file: the
// shapes are chosen here and encoded with the Capnp runtime).
//
//   Echo.echo(n :UInt64) -> (n :UInt64)                 data 1 word / 1 word
//   Factory.make() -> (echo :Echo)                       results: 1 pointer
//   Factory.makeLater() -> (echo :Echo)                  a promise, resolved later
//   Factory.makeBroken() -> (echo :Echo)                 a promise, rejected
//   Factory.useEcho(echo :Echo) -> (n :UInt64)           calls echo.echo(7)
//   Counter.hit(seq :UInt64) -> ()
//   Faulty.fail() -> ()                                   throws an app error with a secret

import Capnp
import CapnpRPC
import Synchronization

enum Echo {
    static let interfaceID: UInt64 = 0xe0e0_0000_0000_0001

    protocol Server: Sendable {
        func echo(_ n: UInt64) async throws -> UInt64
    }

    struct Client: Sendable {
        let target: CallTarget
        let connection: RPCConnection

        func echo(_ n: UInt64) async throws -> UInt64 {
            let mb = MessageBuilder()
            mb.initRoot(dataWords: 1, pointerWords: 0).setUInt64(at: 0, n)
            let result = try await connection.call(target, interface: Echo.interfaceID, method: 0, params: mb.toBytes())
            return try Message(bytes: result.message).rootStruct().readUInt64(at: 0)
        }
    }

    struct Export: ExportHandler {
        let server: any Server

        func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
            guard call.interfaceID == Echo.interfaceID, call.methodID == 0 else { throw RPCError.unimplemented(reason: "Echo") }
            let n = try Message(bytes: call.params).rootStruct().readUInt64(at: 0)
            let out = try await server.echo(n)
            let mb = MessageBuilder()
            mb.initRoot(dataWords: 1, pointerWords: 0).setUInt64(at: 0, out)
            return CallResponse(message: mb.toBytes())
        }
    }
}

struct PlainEcho: Echo.Server {
    func echo(_ n: UInt64) async throws -> UInt64 { n }
}

enum Factory {
    static let interfaceID: UInt64 = 0xfac7_0000_0000_0001

    struct Client: Sendable {
        let cap: CapRef
        let connection: RPCConnection

        /// The promise of `make()`; pipeline `[0]` for the echo cap.
        func make() async throws -> RemotePromise {
            try await connection.send(.cap(cap), interface: Factory.interfaceID, method: 0, params: MessageBuilder.emptyStruct())
        }

        func echoCap(from result: CallResult) throws -> CapRef {
            let idx = try Message(bytes: result.message).rootStruct().readCapabilityIndex(0)
            guard let idx, case .imported(let ref) = result.caps[Int(idx)] else { throw RPCError.failed(reason: "no echo cap") }
            return ref
        }

        func makeLater() async throws -> CapRef {
            try echoCap(from: try await connection.call(.cap(cap), interface: Factory.interfaceID, method: 1, params: MessageBuilder.emptyStruct()))
        }

        func makeBroken() async throws -> CapRef {
            try echoCap(from: try await connection.call(.cap(cap), interface: Factory.interfaceID, method: 2, params: MessageBuilder.emptyStruct()))
        }

        func useEcho(_ echo: CapSlot) async throws -> UInt64 {
            let mb = MessageBuilder()
            mb.initRoot(dataWords: 0, pointerWords: 1).setCapability(0, capIndex: 0)
            let result = try await connection.call(.cap(cap), interface: Factory.interfaceID, method: 3, params: mb.toBytes(), caps: [echo])
            return try Message(bytes: result.message).rootStruct().readUInt64(at: 0)
        }
    }

    /// Serves Factory: make returns an Echo export; makeLater a promise it
    /// resolves after `delay`; makeBroken a promise it rejects.
    struct Export: ExportHandler {
        var delay: Duration = .milliseconds(30)

        func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
            guard call.interfaceID == Factory.interfaceID else { throw RPCError.unimplemented(reason: "Factory") }
            switch call.methodID {
            case 0:
                return try capResponse(.export(Echo.Export(server: PlainEcho())))
            case 1:
                let promise = try connection.makePromise()
                let delay = self.delay
                Task {
                    try? await Task.sleep(for: delay)
                    try? connection.resolve(promise, to: .export(Echo.Export(server: PlainEcho())))
                }
                return try capResponse(.promise(promise))
            case 2:
                let promise = try connection.makePromise()
                let delay = self.delay
                Task {
                    try? await Task.sleep(for: delay)
                    try? connection.reject(promise, reason: "nope")
                }
                return try capResponse(.promise(promise))
            case 3:
                let params = try Message(bytes: call.params).rootStruct()
                guard let idx = try params.readCapabilityIndex(0) else { throw RPCError.failed(reason: "useEcho: no capability") }
                let n: UInt64
                switch call.caps[Int(idx)] {
                case .imported(let ref):
                    n = try await Echo.Client(target: .cap(ref), connection: connection).echo(7)
                case .exported(let id):
                    // Our own Echo export came back: dispatch locally.
                    guard let handler = connection.localHandler(forExport: id) else { throw RPCError.failed(reason: "useEcho: unknown export") }
                    let mb = MessageBuilder()
                    mb.initRoot(dataWords: 1, pointerWords: 0).setUInt64(at: 0, 7)
                    let local = InboundCall(interfaceID: Echo.interfaceID, methodID: 0, params: mb.toBytes(), caps: [], connection: connection)
                    n = try Message(bytes: try await handler.handle(local, on: connection).message).rootStruct().readUInt64(at: 0)
                case .none:
                    throw RPCError.failed(reason: "useEcho: null capability")
                }
                let mb = MessageBuilder()
                mb.initRoot(dataWords: 1, pointerWords: 0).setUInt64(at: 0, n)
                return CallResponse(message: mb.toBytes())
            default:
                throw RPCError.unimplemented(reason: "Factory")
            }
        }

        func capResponse(_ slot: CapSlot) throws -> CallResponse {
            let mb = MessageBuilder()
            mb.initRoot(dataWords: 0, pointerWords: 1).setCapability(0, capIndex: 0)
            return CallResponse(message: mb.toBytes(), caps: [slot])
        }
    }
}

enum Counter {
    static let interfaceID: UInt64 = 0xc0a7_0000_0000_0001

    struct Client: Sendable {
        let cap: CapRef
        let connection: RPCConnection

        func hit(_ seq: UInt64) async throws -> RemotePromise {
            let mb = MessageBuilder()
            mb.initRoot(dataWords: 1, pointerWords: 0).setUInt64(at: 0, seq)
            return try await connection.send(.cap(cap), interface: Counter.interfaceID, method: 0, params: mb.toBytes())
        }
    }

    /// Records the sequence number of every hit at handler start, in the
    /// order the handlers started.
    final class Export: ExportHandler, Sendable {
        let order = Mutex<[UInt64]>([])

        func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
            let seq = try Message(bytes: call.params).rootStruct().readUInt64(at: 0)
            order.withLock { $0.append(seq) }
            // Interleave after the first suspension: a random short sleep.
            try await Task.sleep(for: .microseconds(Int.random(in: 0...200)))
            return CallResponse(message: MessageBuilder.emptyStruct())
        }
    }
}

enum Faulty {
    static let interfaceID: UInt64 = 0xfa17_0000_0000_0001

    struct SecretError: Error {
        let token = "SECRET-TOKEN-42"
    }

    struct Export: ExportHandler {
        func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
            throw SecretError()
        }
    }
}

/// Serves Echo with a handler that never answers (until the connection ends).
struct HangingEcho: Echo.Server {
    func echo(_ n: UInt64) async throws -> UInt64 {
        try await Task.sleep(for: .seconds(60))
        return n
    }
}

/// Echo handlers block on a gate so inbound backpressure can be observed.
final class GatedEcho: Echo.Server, Sendable {
    let started = Mutex<Int>(0)
    private let gate = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let open = Mutex<Bool>(false)

    func echo(_ n: UInt64) async throws -> UInt64 {
        started.withLock { $0 += 1 }
        if !open.withLock({ $0 }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyOpen = open.withLock { $0 }
                if alreadyOpen { continuation.resume() } else { gate.withLock { $0.append(continuation) } }
            }
        }
        return n
    }

    func release() {
        open.withLock { $0 = true }
        let waiting = gate.withLock { g -> [CheckedContinuation<Void, Never>] in
            defer { g.removeAll() }
            return g
        }
        for w in waiting { w.resume() }
    }
}
