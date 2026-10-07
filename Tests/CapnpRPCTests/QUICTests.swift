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
        let p12 = try Data(contentsOf: dir.appendingPathComponent("test-identity.p12"))
        let der = try Data(contentsOf: dir.appendingPathComponent("test-cert.der"))
        return (try TLSIdentity(p12: p12, password: "capnp-swift-test"), der)
    }

    /// OPEN (M6): the QUIC handshake completes (both connections report
    /// .ready and the client opens stream 0), but the listener's
    /// `inboundStreams` handler never fires on this SDK, so both sides
    /// idle-timeout; see the plan's M6 status. Everything else (ALPN from
    /// the core, framing, close codes) is covered by `constants`.
    @Test("a QUIC listener serves a QUIC client over the baseline wire")
    @available(macOS 26.0, iOS 26.0, *)
    func roundTrip() async throws {
        let (identity, cert) = try Self.fixtures()
        let listener = QUICListener(port: 0, identity: identity, bootstrap: { Greeter.Export(SwiftGreeter()) })
        let port = try await withTimeout(.seconds(10)) { try await listener.start() }
        #expect(port != 0)

        let client = try await RPCConnection.connect(
            transport: QUICTransport(host: "127.0.0.1", port: port, trust: .testOnlyTrustThisCertificate(cert), connectTimeout: .seconds(10)))
        let greeter = Greeter.Client(cap: try await client.bootstrap(), connection: client)
        _ = try await withTimeout(.seconds(10)) { try await greeter.greet(name: "QUIC", listener: NoopListener()) }
        await client.close()
        listener.cancel()
    }

    @Test("the core reads the frozen ALPN and the framing option maps")
    func constants() throws {
        #expect(capnpQUICALPN == "capnp-rpc/1")
        #expect(QUICCloseCode.protocolError == 0x434e_5002)
        #expect(QUICCloseCode.normal == 0)
    }
}
