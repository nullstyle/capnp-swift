// Hand-written Swift bindings for interop/schemas/mvp.capnp (plan §8, M1 d).
//
// Shapes come from the schema (and match the Zig bindings capnp-zig generated
// from the same file, interop/zig-peer/gen/mvp.zig):
//   Listener.notify @0 (msg :Text) -> ()          params: 0 data words, 1 pointer
//   Greeter.greet @0 (name :Text, listener :Listener) -> (reply :Text)
//                                                 params: 0 data words, 2 pointers
//                                                 results: 0 data words, 1 pointer
// M3's capnpc-swift generates this file's successors.

import Capnp
import CapnpRPC

/// Runs `body`, turning a `CapnpError` into `RPCError.malformed`.
func decoding<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as CapnpError {
        throw RPCError.malformed("\(error)")
    }
}

public enum Listener {
    public static let interfaceID: UInt64 = 0x9999_1402_f007_d9a7

    public enum Method: UInt16 {
        case notify = 0
    }

    /// What a Swift object serving `Listener` implements.
    public protocol Server: Sendable {
        func notify(_ msg: String) async throws
    }

    /// A remote `Listener`.
    public struct Client: Sendable {
        public let cap: CapRef
        public let connection: RPCConnection

        public init(cap: CapRef, connection: RPCConnection) {
            self.cap = cap
            self.connection = connection
        }

        public func notify(_ msg: String) async throws {
            let mb = MessageBuilder()
            let root = mb.initRoot(dataWords: 0, pointerWords: 1)
            root.setText(0, msg)
            _ = try await connection.call(cap, interface: Listener.interfaceID, method: Method.notify.rawValue, params: mb.toBytes())
        }
    }

    /// Serves a `Server` on a connection (pass it in `CapSlot.export`).
    public struct Export: ExportHandler {
        public let server: any Server

        public init(_ server: any Server) {
            self.server = server
        }

        public func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
            guard call.interfaceID == Listener.interfaceID, call.methodID == Method.notify.rawValue else {
                throw RPCError.unimplemented(reason: "Listener: no such method")
            }
            let msg = try decoding { try Message(bytes: call.params).rootStruct().readText(0) }
            try await server.notify(msg)
            return CallResponse(message: MessageBuilder.emptyStruct())
        }
    }
}

public enum Greeter {
    public static let interfaceID: UInt64 = 0xf303_1bb5_a947_06bb

    public enum Method: UInt16 {
        case greet = 0
    }

    public protocol Server: Sendable {
        func greet(name: String, listener: Listener.Client) async throws -> String
    }

    public struct Client: Sendable {
        public let cap: CapRef
        public let connection: RPCConnection

        public init(cap: CapRef, connection: RPCConnection) {
            self.cap = cap
            self.connection = connection
        }

        /// `greet(name, listener)`: `listener` is exported on the connection
        /// for the duration the remote holds it.
        public func greet(name: String, listener: any Listener.Server) async throws -> String {
            let mb = MessageBuilder()
            let root = mb.initRoot(dataWords: 0, pointerWords: 2)
            root.setText(0, name)
            root.setCapability(1, capIndex: 0)
            let result = try await connection.call(
                cap, interface: Greeter.interfaceID, method: Method.greet.rawValue,
                params: mb.toBytes(), caps: [.export(Listener.Export(listener))])
            return try decoding { try Message(bytes: result.message).rootStruct().readText(0) }
        }
    }

    public struct Export: ExportHandler {
        public let server: any Server

        public init(_ server: any Server) {
            self.server = server
        }

        public func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
            guard call.interfaceID == Greeter.interfaceID, call.methodID == Method.greet.rawValue else {
                throw RPCError.unimplemented(reason: "Greeter: no such method")
            }
            let (name, listenerIndex) = try decoding {
                let params = try Message(bytes: call.params).rootStruct()
                return (try params.readText(0), try params.readCapabilityIndex(1))
            }
            guard let listenerIndex, Int(listenerIndex) < call.caps.count,
                case .imported(let ref) = call.caps[Int(listenerIndex)]
            else {
                throw RPCError.failed(reason: "greet: listener is not a capability")
            }
            let reply = try await server.greet(name: name, listener: Listener.Client(cap: ref, connection: call.connection))
            let mb = MessageBuilder()
            let root = mb.initRoot(dataWords: 0, pointerWords: 1)
            root.setText(0, reply)
            return CallResponse(message: mb.toBytes())
        }
    }
}
