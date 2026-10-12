@_spi(Generated) import Capnp
@_spi(Generated) import CapnpRPC
import CapnpNW
import Dispatch
import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }
private func check(_ condition: Bool, _ name: String) throws {
    guard condition else { throw Failure(description: "CPP_TYPED_RPC_FAIL: " + name) }
    print("PASS: " + name)
}
private struct EchoServer: Child.TypedServer {
    func echo(params: Parent.Typed<CapnpText>.EchoParams<CapnpAnyPointer>.Reader,
              on connection: isolated RPCConnection) async throws -> Parent.Typed<CapnpText>.EchoResults<CapnpAnyPointer>.Value {
        let scope = try params.scope(), value = try params.value()
        return try .init { try $0.setValue(value); try $0.setScope("ack:" + scope) }
    }
}
private struct NamedServer: Named.TypedServer {
    func echo(params: Named.Typed.EchoParams<CapnpAnyPointer>.Reader,
              on connection: isolated RPCConnection) async throws -> Named.Typed.EchoResults<CapnpAnyPointer>.Value {
        let value = try params.value()
        return try .init { try $0.setValue(value) }
    }
}
private struct SwapServer: Swap.TypedServer {
    func swap(params: Swap.Typed.SwapParams<CapnpAnyPointer, CapnpAnyPointer>.Reader,
              on connection: isolated RPCConnection) async throws -> Swap.Typed.SwapResults<CapnpAnyPointer, CapnpAnyPointer>.Value {
        let first = try params.first(), second = try params.second()
        return try .init { try $0.setFirst(second); try $0.setSecond(first) }
    }
}
private struct BatchServer: Batch.TypedServer {
    func gather(params: Batch.Typed.GatherParams<CapnpAnyPointer>.Reader,
                on connection: isolated RPCConnection) async throws -> Batch.Typed.GatherResults<CapnpAnyPointer>.Value {
        let values = try params.values()
        return try .init { builder in
            let output = builder.initValues(values.count)
            for i in values.indices { try output[i].setValue(values[i].value()) }
        }
    }
}

@main struct CppRPCMain {
    static func client(kind: String, port: UInt16) async throws {
        var options = RPCConnection.Options()
        options.callTimeout = .seconds(5)
        let connection = try await RPCConnection.connect(
            transport: TCPTransport(host: "127.0.0.1", port: port), options: options)
        do {
            let cap = try await connection.bootstrap()
            switch kind {
            case "child":
                let child = try Child.Typed.Client(cap: cap, connection: connection)
                let parent = child.parent
                let text = try await parent.echo(as: CapnpText.self) { try $0.setScope("text"); try $0.setValue("hello") }
                try check(try text.value() == "hello" && text.scope() == "ack:text", "method text and outer binding")
                let data = try await parent.echo(as: CapnpData.self) { try $0.setScope("data"); try $0.setValue([0, 1, 255]) }
                try check(try data.value() == [0, 1, 255] && data.scope() == "ack:data", "method data and outer binding")
                let numbers = try await parent.echo(as: CapnpList<UInt16>.self) { try $0.setScope("numbers"); try $0.setValue([7, 65535, 9]) }
                try check(try numbers.value() == [7, 65535, 9], "method integer list")
                let boxed = try Box.Typed<CapnpText>.Value { try $0.setValue("inside") }
                let nested = try await parent.echo(as: Box.Typed<CapnpText>.self) { try $0.setScope("box"); try $0.setValue(boxed) }
                try check(try nested.value().value() == "inside", "method nested generic struct")
                let one = try Box.Typed<CapnpText>.Value { try $0.setValue("one") }
                let two = try Box.Typed<CapnpText>.Value { try $0.setValue("two") }
                let boxes = try await parent.echo(as: CapnpList<Box.Typed<CapnpText>>.self) { try $0.setScope("boxes"); try $0.setValue([one, two]) }
                let values = try boxes.value()
                try check(try values.count == 2 && values[0].value() == "one" && values[1].value() == "two", "method struct list")
                let returned: Child.Typed.Client = try await {
                    let result = try await parent.echo(as: Child.Typed.self) { try $0.setScope("cap"); try $0.setValue(child) }
                    guard let returned = try result.value() else { throw Failure(description: "method capability remains callable") }
                    return returned
                }()
                let callback = try await returned.parent.echo(as: CapnpText.self) { try $0.setScope("callback"); try $0.setValue("retained") }
                try check(try callback.value() == "retained" && callback.scope() == "ack:callback", "method capability remains callable")
            case "named":
                let named = try Named.Typed.Client(cap: cap, connection: connection)
                let text = try await named.echo(as: CapnpText.self) { try $0.setValue("named") }
                try check(try text.value() == "named", "named text brand")
                let data = try await named.echo(as: CapnpData.self) { try $0.setValue([9, 0, 8]) }
                try check(try data.value() == [9, 0, 8], "named data brand")
                let boxed = try Box.Typed<CapnpText>.Value { try $0.setValue("nested") }
                let nested = try await named.echo(as: Box.Typed<CapnpText>.self) { try $0.setValue(boxed) }
                try check(try nested.value().value() == "nested", "named nested brand")
            case "swap":
                let swap = try Swap.Typed.Client(cap: cap, connection: connection)
                let result = try await swap.swap(as: CapnpText.self, as1: CapnpData.self) { try $0.setFirst("first"); try $0.setSecond([4, 5]) }
                try check(try result.first() == [4, 5] && result.second() == "first", "reversed method arguments")
            case "batch":
                let batch = try Batch.Typed.Client(cap: cap, connection: connection)
                let one = try Box.Typed<CapnpText>.Value { try $0.setValue("one") }
                let two = try Box.Typed<CapnpText>.Value { try $0.setValue("two") }
                let result = try await batch.gather(as: CapnpText.self) { try $0.setValues([one, two]) }
                let values = try result.values()
                try check(try values.count == 2 && values[0].value() == "one" && values[1].value() == "two", "method arguments in list elements")
            default: throw Failure(description: "unknown interface")
            }
        } catch { await connection.close(); throw error }
        await connection.close()
    }
    static func server(kind: String) async throws {
        let handler: any ExportHandler
        switch kind {
        case "child": handler = Child.Typed.Export(EchoServer())
        case "named": handler = Named.Typed.Export(NamedServer())
        case "swap": handler = Swap.Typed.Export(SwapServer())
        case "batch": handler = Batch.Typed.Export(BatchServer())
        default: throw Failure(description: "unknown interface")
        }
        let listener = try RPCListener(port: 0, bootstrap: { handler })
        let port = try await listener.start()
        FileHandle.standardOutput.write(Data("PORT \(port)\n".utf8))
        while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
        listener.cancel()
    }
    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            FileHandle.standardError.write(Data("CPP_TYPED_RPC_FAIL: watchdog expired\n".utf8))
            exit(2)
        }
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2 else { throw Failure(description: "usage: server kind | client kind port") }
            if args[0] == "server" { try await server(kind: args[1]) }
            else if args[0] == "client", args.count == 3, let port = UInt16(args[2]) { try await client(kind: args[1], port: port) }
            else { throw Failure(description: "invalid peer command") }
        } catch {
            FileHandle.standardError.write(Data("CPP_TYPED_RPC_FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
