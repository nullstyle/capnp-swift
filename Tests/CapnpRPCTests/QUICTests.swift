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

    @Test("a QUIC listener serves a QUIC client over the baseline wire")
    @available(macOS 26.0, iOS 26.0, *)
    func roundTrip() async throws {
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
