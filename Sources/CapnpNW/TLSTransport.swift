// Swift↔Swift TLS over TCP (plan §7, M5). capnp-zig's TCP transport has no
// TLS, so this lane is Swift on both ends.
//
// The server presents an identity imported from a PKCS#12 blob
// (`SecPKCS12Import`); `sec_identity_t` is not Sendable, so the conversion
// happens inside the init, on the caller's side (an M0 probe note). The
// client takes a trust policy:
//   - `.pinnedCertificates([Data])`: accept only a server whose leaf
//     certificate equals one of the DER blobs (production pinning)
//   - `.testOnlyTrustThisCertificate`: a pin built from the server's own
//     certificate file (tests; explicit, never silent)
// There is deliberately no skip-verification mode.

import CapnpRPC
import Dispatch
import Foundation
import Network
import Security

public enum TLSError: Error, CustomStringConvertible, Sendable {
    case identityImportFailed(OSStatus)
    case noIdentityInP12
    case rejected(String)

    public var description: String {
        switch self {
        case .identityImportFailed(let status): "PKCS#12 import failed (OSStatus \(status))"
        case .noIdentityInP12: "the PKCS#12 file holds no identity"
        case .rejected(let detail): "TLS rejected the peer: \(detail)"
        }
    }
}

/// The server's TLS identity, imported once from a PKCS#12 blob.
public struct TLSIdentity: @unchecked Sendable {
    let identity: SecIdentity

    /// Import the first identity in `p12Data` (a `.p12` file's bytes).
    public init(p12: Data, password: String) throws {
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(p12 as CFData, options, &imported)
        guard status == errSecSuccess, let items = imported as? [[String: Any]],
              let first = items.first else {
            throw TLSError.identityImportFailed(status)
        }
        guard first[kSecImportItemIdentity as String] != nil else {
            throw TLSError.noIdentityInP12
        }
        let identity = first[kSecImportItemIdentity as String] as! SecIdentity
        self.identity = identity
    }

    /// An identity already in the keychain.
    public init(identity: SecIdentity) {
        self.identity = identity
    }

    /// Build an identity straight from DER bytes: a transient `SecKey`
    /// (PKCS#1) plus its certificate, joined by `SecIdentityCreate`.
    ///
    /// The QUIC transport needs this path: a `SecPKCS12Import` identity
    /// used through the modern `QUIC.TLS.localIdentity` stalls on a
    /// keychain-authorization prompt for the key material — never
    /// resolved under a headless test runner (the handshake hangs, every
    /// channel event stops, and both sides idle-timeout). A transient key
    /// has no ACL and cannot prompt.
    public init(certificateDER: Data, keyDER: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw TLSError.identityImportFailed(errSecUnknownFormat)
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            keyDER as CFData,
            [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
             kSecAttrKeyClass as String: kSecAttrKeyClassPrivate] as CFDictionary,
            &error
        ) else {
            throw error!.takeRetainedValue()
        }
        guard let identity = SecIdentityCreate(nil, certificate, key) else {
            throw TLSError.noIdentityInP12
        }
        self.identity = identity
    }
}

/// The client's trust policy for a TLS connection.
public enum TLSTrust: Sendable {
    /// Accept only a server whose leaf certificate equals one of these DER
    /// blobs (extract with `openssl x509 -outform der`).
    case pinnedCertificates([Data])
    /// A test fixture's own certificate as the single pin.
    case testOnlyTrustThisCertificate(Data)

    var pins: [Data] {
        switch self {
        case .pinnedCertificates(let list): list
        case .testOnlyTrustThisCertificate(let one): [one]
        }
    }

    func verifyBlock() -> @Sendable (sec_trust_t) -> Bool {
        let pins = self.pins
        return { secTrust in
            let unmanaged = sec_trust_copy_ref(secTrust)
            let evaluated = unmanaged.takeUnretainedValue()
            guard let chain = SecTrustCopyCertificateChain(evaluated) as? [SecCertificate],
                  let leaf = chain.first else { return false }
            return pins.contains(SecCertificateCopyData(leaf) as Data)
        }
    }
}

private func tlsOptions(localIdentity: SecIdentity?, trust: TLSTrust?) -> NWProtocolTLS.Options {
    let tls = NWProtocolTLS.Options()
    if let localIdentity, let secIdentity = sec_identity_create(localIdentity) {
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
    }
    if let trust {
        let verify = trust.verifyBlock()
        let queue = DispatchQueue(label: "capnp-swift.tls-verify")
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, secTrust, completion in
            completion(verify(secTrust))
        }, queue)
    }
    return tls
}

extension RPCListener {
    /// Listen with TLS: every accepted connection is TLS-server side using
    /// `identity`.
    public convenience init(
        tls port: UInt16,
        identity: TLSIdentity,
        bootstrap: @escaping @Sendable () -> any ExportHandler,
        options: RPCConnection.Options = .init(),
        serverOptions: Options = .init()
    ) throws {
        let params = NWParameters(tls: tlsOptions(localIdentity: identity.identity, trust: nil))
        let nwListener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.init(nwListener: nwListener, socketPath: nil, lockFD: -1, bootstrap: bootstrap, options: options, serverOptions: serverOptions)
    }
}

/// A TLS client `Transport`.
public final class TLSTransport: Transport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let trust: TLSTrust
    private let connectTimeout: Duration
    private var connection: NWConnection?
    private var queue: DispatchSerialQueue?
    private var delegate: (any TransportDelegate)?
    private var ready = false
    private var closed = false
    private var paused = false
    private var receiving = false
    private var buffered: [([UInt8], @Sendable () -> Void)] = []
    private var opening: CheckedContinuation<Void, any Error>?
    private var timeoutWork: DispatchWorkItem?

    public init(host: String, port: UInt16, trust: TLSTrust, connectTimeout: Duration = .seconds(10)) {
        self.host = host
        self.port = port
        self.trust = trust
        self.connectTimeout = connectTimeout
    }

    public func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        self.queue = queue
        self.delegate = delegate
        let nw = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: tlsOptions(localIdentity: nil, trust: trust)))
        connection = nw
        scheduleTimeout()
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !ready, !closed else { return }
                ready = true
                cancelTimeout()
                let pending = buffered
                buffered.removeAll()
                for (bytes, completion) in pending { send(bytes, completion: completion) }
                if let opening {
                    self.opening = nil
                    opening.resume()
                }
                receiveLoop()
            case .failed(let error):
                cancelTimeout()
                fail(TCPTransport.ConnectError.failed("\(error)"))
            case .cancelled:
                cancelTimeout()
                fail(TCPTransport.ConnectError.cancelled)
            default:
                break
            }
        }
        nw.start(queue: queue)
    }

    public func open() async throws {
        guard let queue else { throw TCPTransport.ConnectError.cancelled }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else { return continuation.resume(throwing: TCPTransport.ConnectError.cancelled) }
                if self.ready { return continuation.resume() }
                if self.closed { return continuation.resume(throwing: TCPTransport.ConnectError.cancelled) }
                self.opening = continuation
            }
        }
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !(ready || closed) else { return }
            connection?.cancel()
        }
        timeoutWork = work
        queue?.asyncAfter(deadline: .now() + Double(connectTimeout.components.seconds), execute: work)
    }

    private func cancelTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }

    private func fail(_ error: any Error) {
        guard !closed else { return }
        closed = true
        cancelTimeout()
        if let opening {
            self.opening = nil
            opening.resume(throwing: error)
        }
        delegate?.transportDidClose(error: error)
    }

    public func send(_ bytes: [UInt8], completion: @escaping @Sendable () -> Void) {
        guard ready, !closed else {
            completion()
            return
        }
        if paused {
            buffered.append((bytes, completion))
            return
        }
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in completion() })
    }

    public func pauseReceiving() {
        paused = true
    }

    public func resumeReceiving() {
        paused = false
        let held = buffered
        buffered = []
        for (bytes, completion) in held {
            send(bytes, completion: completion)
        }
        receiveLoop()
    }

    private func receiveLoop() {
        guard ready, !closed, !paused, !receiving else { return }
        receiving = true
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            receiving = false
            if let data, !data.isEmpty {
                delegate?.transportDidReceive(Array(data))
            }
            if let error {
                fail(TCPTransport.ConnectError.failed("\(error)"))
                return
            }
            if isComplete {
                fail(TCPTransport.ConnectError.cancelled)
                return
            }
            receiveLoop()
        }
    }

    public func cancel() {
        guard !closed else { return }
        closed = true
        cancelTimeout()
        connection?.cancel()
        delegate?.transportDidClose(error: nil)
    }
}
