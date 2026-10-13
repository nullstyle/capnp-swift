import Capnp
import CapnpNW
import CapnpRPC
import Dispatch
import Foundation
import Synchronization
import WorkbenchRPC

public enum WorkbenchMode: String, CaseIterable, Codable, Sendable {
    case tcp = "TCP"
    case tls = "Sample TLS"
    public var defaultPort: UInt16 { self == .tcp ? 41011 : 41012 }
}

public struct WorkbenchEndpoint: Sendable {
    public var host: String
    public var port: UInt16
    public var mode: WorkbenchMode
    public init(host: String, port: UInt16, mode: WorkbenchMode) {
        self.host = host; self.port = port; self.mode = mode
    }

    public func connect(wrongPin: Bool = false) async throws -> WorkbenchPeer {
        let transport: any Transport
        switch mode {
        case .tcp:
            transport = TCPTransport(host: host, port: port, connectTimeout: .seconds(5))
        case .tls:
            let pin = wrongPin ? Data([0, 1, 2]) : try WorkbenchCertificates.certificate()
            transport = TLSTransport(host: host, port: port,
                trust: .testOnlyTrustThisCertificate(pin), connectTimeout: .seconds(5))
        }
        let observed = WorkbenchTransport(transport)
        var options = RPCConnection.Options()
        options.callTimeout = .seconds(5)
        options.shutdownDrainTimeout = .milliseconds(250)
        options.streamWindowMaxCalls = 2
        options.streamWindowMaxBytes = 4096
        let connection = try await RPCConnection.connect(transport: observed, options: options)
        return WorkbenchPeer(connection: connection, wire: observed)
    }
}

public struct WorkbenchPeer: Sendable {
    public let connection: RPCConnection
    let wire: WorkbenchTransport
}

public enum WorkbenchCertificates {
    public static func certificate() throws -> Data { try resource("test-cert") }
    static func identity() throws -> TLSIdentity {
        try TLSIdentity(certificateDER: certificate(), keyDER: resource("test-key"))
    }
    private static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Certificates") else {
            throw WorkbenchFailure("sample certificate resource is missing")
        }
        return try Data(contentsOf: url)
    }
}

public final class WorkbenchHost: Sendable {
    private let tcp: RPCListener
    private let tls: RPCListener
    public let tcpPort: UInt16
    public let tlsPort: UInt16

    private init(tcp: RPCListener, tls: RPCListener, tcpPort: UInt16, tlsPort: UInt16) {
        self.tcp = tcp; self.tls = tls; self.tcpPort = tcpPort; self.tlsPort = tlsPort
    }

    public static func start(tcpPort: UInt16 = 41011, tlsPort: UInt16 = 41012) async throws -> WorkbenchHost {
        var options = RPCConnection.Options()
        options.callTimeout = .seconds(5)
        options.shutdownDrainTimeout = .milliseconds(250)
        let tcp = try RPCListener(port: tcpPort, bootstrap: { Workbench.Typed.Export(WorkbenchService()) }, options: options)
        let tls = try RPCListener(tls: tlsPort, identity: WorkbenchCertificates.identity(),
            bootstrap: { Workbench.Typed.Export(WorkbenchService()) }, options: options)
        do {
            let boundTCP = try await tcp.start()
            let boundTLS = try await tls.start()
            return WorkbenchHost(tcp: tcp, tls: tls, tcpPort: boundTCP, tlsPort: boundTLS)
        } catch {
            tcp.cancel(); tls.cancel(); throw error
        }
    }
    public func stop() { tcp.cancel(); tls.cancel() }
}

// Observe actual protocol frames through public interfaces. The runtime still
// owns framing, transport scheduling, capability dispatch and connection state.
final class WorkbenchTransport: Transport, Sendable {
    struct Counts: Sendable { var calls = 0; var returns = 0 }
    private final class Receiver: TransportDelegate, @unchecked Sendable {
        weak var delegate: (any TransportDelegate)?
        init(delegate: any TransportDelegate) { self.delegate = delegate }
        func transportDidReceive(_ bytes: [UInt8]) {
            // TCP callbacks may split/coalesce frames. Only outgoing frames
            // are used as message observations; incoming bytes go untouched.
            delegate?.transportDidReceive(bytes)
        }
        func transportDidClose(error: (any Error)?) { delegate?.transportDidClose(error: error) }
    }
    let base: any Transport
    private let outgoing = Mutex(Counts())
    private let receiver = Mutex<Receiver?>(nil)
    init(_ base: any Transport) { self.base = base }
    var callsSent: Int { outgoing.withLock { $0.calls } }
    func start(queue: DispatchSerialQueue, delegate: any TransportDelegate) {
        let proxy = Receiver(delegate: delegate)
        receiver.withLock { $0 = proxy }
        base.start(queue: queue, delegate: proxy)
    }
    func open() async throws { try await base.open() }
    func send(_ bytes: [UInt8], completion: @escaping @Sendable () -> Void) {
        if let tag = try? Message(bytes: bytes).rootStruct().readUInt16(at: 0) {
            outgoing.withLock { if tag == 2 { $0.calls += 1 }; if tag == 3 { $0.returns += 1 } }
        }
        base.send(bytes, completion: completion)
    }
    func pauseReceiving() { base.pauseReceiving() }
    func resumeReceiving() { base.resumeReceiving() }
    func cancel() { base.cancel() }
}
