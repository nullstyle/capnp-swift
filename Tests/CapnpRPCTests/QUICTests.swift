// M6 QUIC tests (plan §8): Swift↔Swift over the baseline wire (ALPN
// capnp-rpc/1, stream 0, u32 LE framing), with the TLS fixture identity.
// macOS 26+ only (NetworkConnection<QUIC>); skipped elsewhere.

import CapnpMVP
import CapnpNW
import CapnpRPC
import Foundation
import Testing

@Suite("QUIC")
struct QUICTests {
    @available(macOS 26.0, iOS 26.0, *)
    static func fixtures() throws -> (TLSIdentity, Data) {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/tls")
        let cert = try Data(contentsOf: dir.appendingPathComponent("test-cert.der"))
        let key = try Data(contentsOf: dir.appendingPathComponent("test-key.der"))
        // Raw-DER identity, not the p12: a SecPKCS12Import identity stalls
        // the modern QUIC TLS handshake on a keychain-authorization prompt
        // (never answered under a test runner).
        return (try TLSIdentity(certificateDER: cert, keyDER: key), cert)
    }

    @Test("parallel QUIC connections complete and close over the baseline wire", arguments: 0..<16)
    @available(macOS 26.0, iOS 26.0, *)
    func roundTrip(_ iteration: Int) async throws {
        let (identity, cert) = try Self.fixtures()
        let listener = QUICListener(port: 0, identity: identity, bootstrap: { Greeter.Export(SwiftGreeter()) })
        let port = try await withTimeout(.seconds(10)) { try await listener.start() }
        #expect(port != 0)

        var clientOptions = RPCConnection.Options()
        clientOptions.framing = .u32LE
        let client = try await RPCConnection.connect(
            transport: QUICTransport(host: "127.0.0.1", port: port, trust: .testOnlyTrustThisCertificate(cert), connectTimeout: .seconds(10)),
            options: clientOptions)
        let greeter = Greeter.Client(cap: try await client.bootstrap(), connection: client)
        let name = "QUIC-\(iteration)"
        let reply = try await withTimeout(.seconds(10)) { try await greeter.greet(name: name, listener: NoopListener()) }
        #expect(reply == "Hello, \(name)!")
        await client.close()
        _ = await client.waitClosed()
        listener.cancel()
        // Keep the test process alive for pending SDK teardown callbacks.
        // Returning immediately masked a Network.framework trap that the
        // longer full suite exposed under ASan and on the iOS runner.
        try await Task.sleep(for: .seconds(1))
    }

    @Test("the core reads the frozen ALPN and the framing option maps")
    func constants() throws {
        #expect(capnpQUICALPN == "capnp-rpc/1")
        #expect(QUICCloseCode.protocolError == 0x434e_5002)
        #expect(QUICCloseCode.normal == 0)
    }
}

// A heavy workload apart from the QUIC suite: 4 x 1000 calls in parallel
// with the 16 parallel round trips starved one round trip past its 10 s
// limit on the hosted iOS simulator (nightly 39189320930). Serialized, and
// the nightly runs this suite in its own simulator process.
@Suite("QUIC order", .serialized)
struct QUICOrderTests {
    @Test("E-order over QUIC: 1000 calls on one capability start in send order", arguments: 0..<4)
    @available(macOS 26.0, iOS 26.0, *)
    func eOrder(_ iteration: Int) async throws {
        let (identity, cert) = try QUICTests.fixtures()
        let counter = Counter.Export()
        let listener = QUICListener(port: 0, identity: identity, bootstrap: { counter })
        let port = try await withTimeout(.seconds(10)) { try await listener.start() }

        var clientOptions = RPCConnection.Options()
        clientOptions.framing = .u32LE
        let client = try await RPCConnection.connect(
            transport: QUICTransport(host: "127.0.0.1", port: port, trust: .testOnlyTrustThisCertificate(cert), connectTimeout: .seconds(10)),
            options: clientOptions)
        let hits = Counter.Client(cap: try await client.bootstrap(), connection: client)
        var promises: [RemotePromise] = []
        for seq in 0..<1000 {
            promises.append(try await hits.hit(UInt64(seq)))
        }
        let sent = promises
        try await withTimeout(.seconds(30)) {
            for promise in sent { _ = try await promise.result() }
        }
        let order = counter.order.withLock { $0 }
        #expect(order.count == 1000)
        #expect(order == order.sorted())
        await client.close()
        _ = await client.waitClosed()
        listener.cancel()
        try await Task.sleep(for: .seconds(1))
    }
}
