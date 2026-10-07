// mvp-e2e: the M1 "MVP slice" e2e client (plan §8, M1 f). `just mvp-e2e`
// runs it. It starts the capnp-zig TCP peer (interop/zig-peer), connects over
// TCP, and prints TAP for the four M1 checks:
//
//   1 greet                      Greeter.greet("Swift") -> "Hello, Swift!"
//   2 callback served by Swift   the peer called Listener.notify("greeted Swift")
//   3 remote exception           greet("") fails with the reason "EmptyName"
//   4 server kill -> .disconnected  SIGTERM to the peer ends the connection
//                                with RPCError.disconnected
//
// Usage: mvp-e2e --server <path to zig-peer> [--timeout <seconds>]
// Exit status 0 only when every line is `ok`.

import CapnpMVPGen
import CapnpNW
import CapnpRPC
import Foundation
import Synchronization

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

/// Records every notify; `first()` polls so a timeout can cancel the wait.
/// The Server conformance is against the GENERATED bindings (M3-h).
final class RecordingListener: Listener.Server, Sendable {
    private let messages = Mutex<[String]>([])

    func notify(params: Listener.NotifyParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Listener.NotifyResults {
        messages.withLock { $0.append((try? params.msg()) ?? "") }
        return Listener.NotifyResults()
    }

    func first() async throws -> String {
        while true {
            if let m = messages.withLock({ $0.first }) { return m }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

struct TAP {
    var lines: [String] = []
    var failures = 0

    mutating func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        let n = lines.count + 1
        if ok {
            lines.append("ok \(n) - \(name)")
        } else {
            failures += 1
            lines.append("not ok \(n) - \(name)" + (detail.isEmpty ? "" : "\n  # \(detail)"))
        }
    }

    func print(planned: Int) {
        Swift.print("TAP version 14")
        Swift.print("1..\(planned)")
        for line in lines { Swift.print(line) }
    }
}

@main
struct MVPE2E {
    static func main() async {
        var serverPath: String?
        var timeoutSeconds: Int64 = 10
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--server": serverPath = args.next()
            case "--timeout": timeoutSeconds = Int64(args.next() ?? "10") ?? 10
            default:
                FileHandle.standardError.write(Data("mvp-e2e: unknown argument \(arg)\n".utf8))
                exit(2)
            }
        }
        guard let serverPath else {
            FileHandle.standardError.write(Data("usage: mvp-e2e --server <zig-peer> [--timeout <seconds>]\n".utf8))
            exit(2)
        }

        let timeout: Duration = .seconds(timeoutSeconds)
        var tap = TAP()
        let planned = 4
        do {
            // Start the Zig peer on an ephemeral port; it prints "port=N".
            let server = Process()
            server.executableURL = URL(fileURLWithPath: serverPath)
            server.arguments = ["--host", "127.0.0.1", "--port", "0"]
            let stdout = Pipe()
            server.standardOutput = stdout
            try server.run()
            defer {
                if server.isRunning { server.terminate() }
                server.waitUntilExit()
            }
            let port: UInt16 = try await withTimeout(timeout) {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    if line.hasPrefix("port="), let p = UInt16(line.dropFirst(5)) { return p }
                }
                throw TimeoutError()
            }
            print("# zig-peer pid \(server.processIdentifier) on 127.0.0.1:\(port)")

            let connection = try await withTimeout(timeout) {
                try await RPCConnection.connect(transport: TCPTransport(host: "127.0.0.1", port: port, connectTimeout: timeout))
            }
            let greeter = Greeter.Client(cap: try await withTimeout(timeout) { try await connection.bootstrap() }, connection: connection)

            // 1. greet
            let listener = RecordingListener()
            let reply = try await withTimeout(timeout) { try await greeter.greet { $0.setName("Swift"); $0.setListener(listener) }.reply() }
            tap.check(reply == "Hello, Swift!", "greet", "reply was \(reply.debugDescription)")

            // 2. callback served by Swift
            let first = try await withTimeout(timeout) { try await listener.first() }
            tap.check(first == "greeted Swift", "callback served by Swift", "notify was \(first.debugDescription)")

            // 3. remote exception
            var exception = "no error"
            var isExpected = false
            do {
                _ = try await withTimeout(timeout) { try await greeter.greet { $0.setListener(listener) }.reply() }
            } catch let error as RPCError {
                exception = "\(error)"
                if case .failed(let reason) = error, reason == "EmptyName" { isExpected = true }
            } catch {
                exception = "\(error)"
            }
            tap.check(isExpected, "remote exception", "got \(exception)")

            // 4. server kill -> .disconnected
            server.terminate()
            let cause = try await withTimeout(timeout) { await connection.waitClosed() }
            var disconnected = false
            if case .disconnected = cause { disconnected = true }
            tap.check(disconnected, "server kill -> .disconnected", "close cause was \(cause)")
        } catch {
            tap.check(false, "e2e aborted", "\(error)")
        }
        while tap.lines.count < planned { tap.check(false, "not run") }
        tap.print(planned: planned)
        exit(tap.failures == 0 ? 0 : 1)
    }
}
