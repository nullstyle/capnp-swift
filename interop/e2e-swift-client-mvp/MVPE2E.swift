#if !os(macOS)
// mvp-e2e starts the Zig peer binary: a macOS-only build tool.
import Foundation
@main struct MVPE2ENoop { static func main() { fatalError("mvp-e2e is macOS-only") } }
#else
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

// The test TLS fixture (Tests/fixtures/tls): the PEMs feed zig-peer's
// QUIC server, the DERs pin/build the Swift side.
func fixture(_ name: String) -> String {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/fixtures/tls")
    return dir.appendingPathComponent(name).path
}

/// A Greeter served by Swift for the Zig->Swift lane: notifies the
/// caller's listener, then replies (mirrors the Zig peer's semantics).
struct E2EGreeter: Greeter.Server {
    func greet(params: Greeter.GreetParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Greeter.GreetResults {
        let name = try params.name()
        if name.isEmpty { throw RPCError.failed(reason: "EmptyName") }
        guard let listener = params.listener(caps, on: connection) else {
            throw RPCError.failed(reason: "no listener capability")
        }
        _ = try await listener.notify { $0.setMsg("greeted \(name)") }
        return Greeter.GreetResults { $0.setReply("Hello, \(name)!") }
    }
}

func serveGreeterOverQUIC() async {
    guard #available(macOS 26.0, iOS 26.0, *) else {
        FileHandle.standardError.write(Data("mvp-e2e: --serve-quic needs macOS 26\n".utf8))
        exit(2)
    }
    do {
        let cert = try Data(contentsOf: URL(fileURLWithPath: fixture("test-cert.der")))
        let key = try Data(contentsOf: URL(fileURLWithPath: fixture("test-key.der")))
        let identity = try TLSIdentity(certificateDER: cert, keyDER: key)
        let listener = QUICListener(port: 0, identity: identity, bootstrap: { Greeter.Export(E2EGreeter()) })
        let port = try await withTimeout(.seconds(10)) { try await listener.start() }
        print("port=\(port)")
        fflush(stdout)
        print("# mvp-e2e serving Greeter over QUIC on 127.0.0.1:\(port)")
        fflush(stdout)
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    } catch {
        FileHandle.standardError.write(Data("mvp-e2e --serve-quic failed: \(error)\n".utf8))
        exit(1)
    }
}

@main
struct MVPE2E {
    static func main() async {
        var serverPath: String?
        var timeoutSeconds: Int64 = 10
        var useQuic = false
        var idleSeconds: Int64 = 0
        var serveQuic = false
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--server": serverPath = args.next()
            case "--timeout": timeoutSeconds = Int64(args.next() ?? "10") ?? 10
            case "--transport":
                let v = args.next() ?? "tcp"
                if v == "quic" { useQuic = true } else if v != "tcp" {
                    FileHandle.standardError.write(Data("mvp-e2e: unknown transport \(v)\n".utf8))
                    exit(2)
                }
            case "--idle-seconds": idleSeconds = Int64(args.next() ?? "0") ?? 0
            case "--serve-quic": serveQuic = true
            default:
                FileHandle.standardError.write(Data("mvp-e2e: unknown argument \(arg)\n".utf8))
                exit(2)
            }
        }
        if serveQuic { await serveGreeterOverQUIC(); return }
        guard let serverPath else {
            FileHandle.standardError.write(Data(
                "usage: mvp-e2e --server <zig-peer> [--timeout <seconds>] [--transport tcp|quic] [--idle-seconds N] | --serve-quic\n".utf8))
            exit(2)
        }

        let timeout: Duration = .seconds(timeoutSeconds)
        var tap = TAP()
        var planned = 4
        if useQuic {
            if #available(macOS 26.0, *) { planned += 1 }  // second-stream reset gate
            if idleSeconds > 0 { planned += 1 }  // idle gate
            planned += 1  // clean-close gate
        }
        do {
            // Start the Zig peer on an ephemeral port; it prints "port=N".
            let server = Process()
            server.executableURL = URL(fileURLWithPath: serverPath)
            var serverArgs = ["--host", "127.0.0.1", "--port", "0"]
            if useQuic {
                guard #available(macOS 26.0, iOS 26.0, *) else {
                    FileHandle.standardError.write(Data("mvp-e2e: --transport quic needs macOS 26\n".utf8))
                    exit(2)
                }
                serverArgs += ["--transport", "quic", "--cert-pem", fixture("test-cert.pem"), "--key-pem", fixture("test-key.pem")]
            }
            server.arguments = serverArgs
            let stdout = Pipe()
            let stderr = Pipe()
            server.standardOutput = stdout
            server.standardError = stderr
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

            let connection: RPCConnection
            var quicTransport: (any Transport)?
            if useQuic, #available(macOS 26.0, *) {
                let der = try Data(contentsOf: URL(fileURLWithPath: fixture("test-cert.der")))
                var options = RPCConnection.Options()
                options.framing = .u32LE
                let framedOptions = options
                let quic = QUICTransport(
                    host: "127.0.0.1",
                    port: port,
                    trust: .testOnlyTrustThisCertificate(der),
                    connectTimeout: timeout,
                    idleTimeout: .seconds(150))
                quicTransport = quic
                connection = try await withTimeout(timeout) {
                    try await RPCConnection.connect(transport: quic, options: framedOptions)
                }
            } else {
                connection = try await withTimeout(timeout) {
                    try await RPCConnection.connect(transport: TCPTransport(host: "127.0.0.1", port: port, connectTimeout: timeout))
                }
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

            var plannedExtra = 0
            if useQuic {
                // 5. second stream reset (0x434e5002) and the connection stays up
                if #available(macOS 26.0, *) {
                    if let quicTransport = quicTransport as? QUICTransport {
                        let probe = try await withTimeout(timeout) { await quicTransport.probeSecondaryStream() }
                        let refused = probe.receiveError != nil || probe.sendThrew
                        let after = try await withTimeout(timeout) {
                            try await greeter.greet { $0.setName("AfterReset"); $0.setListener(listener) }.reply()
                        }
                        let stayedUp = after == "Hello, AfterReset!"
                        tap.check(refused && stayedUp, "second stream reset, connection stays up",
                            "refused=\(refused) sendThrew=\(probe.sendThrew) recv=\(probe.receiveError ?? "none") code=\(probe.applicationErrorCode.map { String($0, radix: 16) } ?? "n/a") stayedUp=\(stayedUp)")
                        plannedExtra += 1
                    }
                }

                // 6. idle survival
                if idleSeconds > 0 {
                    try await Task.sleep(for: .seconds(idleSeconds))
                    let afterIdle = try await withTimeout(timeout) {
                        try await greeter.greet { $0.setName("AfterIdle"); $0.setListener(listener) }.reply()
                    }
                    tap.check(afterIdle == "Hello, AfterIdle!", "\(idleSeconds) s idle then greet", "reply was \(afterIdle.debugDescription)")
                    plannedExtra += 1
                }

                // 7. clean close -> peer reports close code 0 (peer_close)
                await connection.close()
                let cause7 = try await withTimeout(timeout) { await connection.waitClosed() }
                _ = cause7
                var peerClose = false
                for _ in 0..<100 {
                    let data = stderr.fileHandleForReading.availableData
                    if let text = String(data: data, encoding: .utf8), text.contains("close_cause=peer_close") {
                        peerClose = true
                        break
                    }
                    if !server.isRunning { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                tap.check(peerClose, "clean close -> peer_close", "server never reported close_cause=peer_close")
                plannedExtra += 1
            }

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

#endif
