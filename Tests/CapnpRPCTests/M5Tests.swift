// M5 tests (plan §8): unix sockets and TLS, both over the same RPC stack
// the Loopback/TCP suites cover. The TLS fixture (Tests/fixtures/tls) is a
// self-signed test identity generated once with openssl (see the README
// there); the plan's `SecPKCS12Import` path is exercised by
// `TLSIdentity(p12:password:)`.

import CapnpMVP
import CapnpNW
import CapnpRPC
import Testing
import Foundation

struct NoopListener: Listener.Server, Sendable {
    func notify(_ msg: String) async throws {}
}

// Serialized: both TLS tests call SecPKCS12Import, and concurrent imports
// of the same file raced on a CI runner (OSStatus -26276, 2026-10-08).
@Suite("M5", .serialized)
struct M5Tests {
    #if os(macOS)
    @Test("a unix listener serves a unix client, with path guards")
    func unixRoundTrip() async throws {
        // 0700 parent dir + a short path (the flock file sits next to it).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capnp-swift-m5-\(getpid())-\(Int.random(in: 0..<9999))")
        let path = dir.appendingPathComponent("m5.sock").path
        defer { try? FileManager.default.removeItem(at: dir) }

        let listener = try RPCListener(unixPath: path, bootstrap: { Greeter.Export(SwiftGreeter()) })
        let started = try await withTimeout(.seconds(5)) { try await listener.start() }
        #expect(started == 0)
        // .ready must mean the socket file exists (M0 finding).
        #expect(FileManager.default.fileExists(atPath: path))

        let client = try await RPCConnection.connect(transport: UnixTransport(path: path, connectTimeout: .seconds(5)))
        let greeter = Greeter.Client(cap: try await client.bootstrap(), connection: client)
        _ = try await withTimeout(.seconds(5)) { try await greeter.greet(name: "Unix", listener: NoopListener()) }
        await client.close()
        _ = await client.waitClosed()
        listener.cancel()
    }

    @Test("a second listener on the same socket path fails on its lock")
    func unixLocking() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capnp-swift-m5-lock-\(getpid())-\(Int.random(in: 0..<9999))")
        let path = dir.appendingPathComponent("m5.sock").path
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try RPCListener(unixPath: path, bootstrap: { Greeter.Export(SwiftGreeter()) })
        _ = try await withTimeout(.seconds(5)) { try await first.start() }
        defer { first.cancel() }
        #expect(throws: (any Error).self) {
            _ = try RPCListener(unixPath: path, bootstrap: { Greeter.Export(SwiftGreeter()) })
        }
    }
    #endif

    @Test("a path over 104 bytes is refused before any Network call")
    func unixPathLimit() async throws {
        let long = String(repeating: "x", count: 120)
        #expect(throws: (any Error).self) {
            _ = try RPCListener(unixPath: long, bootstrap: { Greeter.Export(SwiftGreeter()) })
        }
        var refused = false
        do {
            _ = try await RPCConnection.connect(transport: UnixTransport(path: long, connectTimeout: .seconds(1)))
        } catch {
            refused = true
        }
        #expect(refused, "a 120-byte path must be refused")
    }

    @Test("a TLS listener serves a TLS client with the pinned certificate")
    func tlsRoundTrip() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/tls")
        let p12 = try Data(contentsOf: fixtures.appendingPathComponent("test-identity.p12"))
        let certDER = try Data(contentsOf: fixtures.appendingPathComponent("test-cert.der"))
        let identity = try TLSIdentity(p12: p12, password: "capnp-swift-test")

        let listener = try RPCListener(tls: 0, identity: identity, bootstrap: { Greeter.Export(SwiftGreeter()) })
        let port = try await withTimeout(.seconds(5)) { try await listener.start() }
        #expect(port != 0)

        let client = try await RPCConnection.connect(
            transport: TLSTransport(host: "127.0.0.1", port: port, trust: .testOnlyTrustThisCertificate(certDER), connectTimeout: .seconds(10)))
        let greeter = Greeter.Client(cap: try await client.bootstrap(), connection: client)
        _ = try await withTimeout(.seconds(5)) { try await greeter.greet(name: "TLS", listener: NoopListener()) }
        await client.close()
        listener.cancel()
    }

    @Test("a TLS client with the wrong pin cannot connect")
    func tlsRejectsWrongPin() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/tls")
        let p12 = try Data(contentsOf: fixtures.appendingPathComponent("test-identity.p12"))
        let identity = try TLSIdentity(p12: p12, password: "capnp-swift-test")
        // A pin that is not the server's certificate (the p12's own header
        // bytes, definitely not a matching leaf).
        let wrongPin = Data([0x30, 0x82, 0x01, 0x02, 0x03, 0x04])

        let listener = try RPCListener(tls: 0, identity: identity, bootstrap: { Greeter.Export(SwiftGreeter()) })
        let port = try await withTimeout(.seconds(5)) { try await listener.start() }
        defer { listener.cancel() }

        await #expect(throws: (any Error).self) {
            _ = try await withTimeout(.seconds(10)) {
                try await RPCConnection.connect(
                    transport: TLSTransport(host: "127.0.0.1", port: port, trust: .pinnedCertificates([wrongPin]), connectTimeout: .seconds(5)))
            }
        }
    }
}
