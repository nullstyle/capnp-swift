// Swift <-> Swift RPC over LoopbackTransport (plan §8, M1): the whole runtime
// (core, actor, drain, exports, releases) without a socket. The 64 x 1k test
// is the M1 TSan gate: `swift test --sanitize=thread --filter Loopback`.

import Capnp
import CapnpMVP
import CapnpRPC
import Synchronization
import Testing

/// A Greeter served by Swift: notifies the listener, then replies.
struct SwiftGreeter: Greeter.Server {
    func greet(name: String, listener: Listener.Client) async throws -> String {
        if name.isEmpty { throw RPCError.failed(reason: "EmptyName") }
        try await listener.notify("greeted \(name)")
        return "Hello, \(name)!"
    }
}

final class RecordingListener: Listener.Server, Sendable {
    private let store = Mutex<[String]>([])

    func notify(_ msg: String) async throws {
        store.withLock { $0.append(msg) }
    }

    var messages: [String] { store.withLock { $0 } }
}

/// A connected client/server pair over loopback.
struct Pair {
    let client: RPCConnection
    let server: RPCConnection
    let greeter: Greeter.Client

    init(options: RPCConnection.Options = .init()) async throws {
        let (a, b) = LoopbackTransport.pair()
        server = try await RPCConnection.connect(transport: b, bootstrap: Greeter.Export(SwiftGreeter()), options: options)
        client = try await RPCConnection.connect(transport: a, options: options)
        greeter = Greeter.Client(cap: try await client.bootstrap(), connection: client)
    }
}

@Suite("Loopback")
struct LoopbackTests {
    @Test("greet round trip: results, a callback served by the caller, a remote exception, close")
    func roundTrip() async throws {
        let pair = try await Pair()
        let listener = RecordingListener()

        let reply = try await pair.greeter.greet(name: "Loop", listener: listener)
        #expect(reply == "Hello, Loop!")
        #expect(listener.messages == ["greeted Loop"])

        await #expect(throws: RPCError.failed(reason: "EmptyName")) {
            _ = try await pair.greeter.greet(name: "", listener: listener)
        }

        // Closing one side ends both; a call after close fails as disconnected.
        await pair.client.close()
        let clientCause = await pair.client.waitClosed()
        let serverCause = await pair.server.waitClosed()
        guard case .disconnected = clientCause else {
            Issue.record("client close cause: \(clientCause)")
            return
        }
        guard case .disconnected = serverCause else {
            Issue.record("server close cause: \(serverCause)")
            return
        }
        await #expect(throws: RPCError.self) {
            _ = try await pair.greeter.greet(name: "late", listener: listener)
        }
    }

    @Test("a call in flight when the transport closes ends with .disconnected")
    func disconnectInFlight() async throws {
        /// Never answers: the call stays open until the connection dies.
        struct Hanging: Greeter.Server {
            func greet(name: String, listener: Listener.Client) async throws -> String {
                try await Task.sleep(for: .seconds(60))
                return ""
            }
        }
        let (a, b) = LoopbackTransport.pair()
        let server = try await RPCConnection.connect(transport: b, bootstrap: Greeter.Export(Hanging()))
        let client = try await RPCConnection.connect(transport: a)
        let greeter = Greeter.Client(cap: try await client.bootstrap(), connection: client)
        let listener = RecordingListener()
        async let pending: String = withTimeout(.seconds(5)) { try await greeter.greet(name: "x", listener: listener) }
        try await Task.sleep(for: .milliseconds(50))
        await server.close()
        do {
            _ = try await pending
            Issue.record("the call returned although the server closed")
        } catch let error as RPCError {
            // The core ends the question itself (RETURN DISCONNECTED carries
            // capnp-zig's reason), not the runtime's safety net.
            #expect(error == .disconnected(reason: "disconnected"))
        }
    }

    @Test("a call deadline ends the question with .overloaded")
    func deadline() async throws {
        struct Hanging: Greeter.Server {
            func greet(name: String, listener: Listener.Client) async throws -> String {
                try await Task.sleep(for: .seconds(60))
                return ""
            }
        }
        var options = RPCConnection.Options()
        options.callTimeout = .milliseconds(200)
        options.tickInterval = .milliseconds(20)
        let (a, b) = LoopbackTransport.pair()
        let server = try await RPCConnection.connect(transport: b, bootstrap: Greeter.Export(Hanging()))
        let client = try await RPCConnection.connect(transport: a, options: options)
        let greeter = Greeter.Client(cap: try await client.bootstrap(), connection: client)
        await #expect(throws: RPCError.overloaded(reason: "deadline exceeded")) {
            _ = try await withTimeout(.seconds(5)) { try await greeter.greet(name: "slow", listener: RecordingListener()) }
        }
        await client.close()
        _ = await server.waitClosed()
    }

    @Test("64 connections x 1k calls, each with a callback (the TSan gate)")
    func manyConnections() async throws {
        let connections = 64
        let calls = 1000
        try await withThrowingTaskGroup(of: Void.self) { group in
            for c in 0..<connections {
                group.addTask {
                    let pair = try await Pair()
                    let listener = RecordingListener()
                    for i in 0..<calls {
                        let name = "c\(c)-\(i)"
                        let reply = try await pair.greeter.greet(name: name, listener: listener)
                        guard reply == "Hello, \(name)!" else { throw TestFailure("bad reply \(reply)") }
                    }
                    guard listener.messages.count == calls else { throw TestFailure("\(listener.messages.count) callbacks, expected \(calls)") }
                    await pair.client.close()
                    _ = await pair.server.waitClosed()
                }
            }
            try await group.waitForAll()
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct TestTimeout: Error {}

/// Bounds an await so a broken runtime fails the test instead of hanging it.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TestTimeout()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
