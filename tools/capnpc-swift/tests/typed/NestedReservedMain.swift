@_spi(Generated) import Capnp
import CapnpRPC

private func require(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    let valid: Bool
    do { valid = try condition() }
    catch { preconditionFailure("TYPED_NAMING_FAIL: \(name): \(error)") }
    precondition(valid, "TYPED_NAMING_FAIL: \(name)")
    print("PASS: \(name)")
}

private typealias ReaderChild = ReaderHost.Typed<CapnpText>.Reader_Nodee71122aabbcc0101
private typealias BuilderChild = BuilderHost.Typed<CapnpData>.Builder_Nodee71122aabbcc0102
private typealias ValueChild = ValueHost.Typed<CapnpText>.Value_Nodee71122aabbcc0103
private typealias PipelineChild = PipelineHost.Typed<CapnpText>.Pipeline_Nodee71122aabbcc0104
private typealias TypedChild = TypedHost.Typed<CapnpText>.Typed
private typealias InterfaceClientChild = RpcHost.Typed.Client_Nodee71122aabbcc0106
private typealias InterfaceExportChild = RpcHost.Typed.Export_Nodee71122aabbcc0107

// Compile the pipeline references too; these projections need no wire call.
private func pipelineReferences(_ projection: RPCPointerPipeline) {
    _ = ReaderHost.Typed<CapnpText>.pipeline(projection).child
    _ = BuilderHost.Typed<CapnpData>.pipeline(projection).child
    _ = ValueHost.Typed<CapnpText>.pipeline(projection).child
    _ = PipelineHost.Typed<CapnpText>.pipeline(projection).child
    _ = TypedHost.Typed<CapnpText>.pipeline(projection).child
    _ = Groups.Typed.pipeline(projection).value
    _ = Groups.Typed.pipeline(projection).pipeline
    _ = PlainNames.Typed.pipeline(projection).client
    _ = PlainNames.Typed.pipeline(projection).exported
}

@main struct NestedReservedMain {
    static func main() throws {
        let readerChild = try ReaderChild.Value { $0.number = 11 }
        let reader = try ReaderHost.Typed<CapnpText>.Value {
            try $0.setPayload("reader")
            try $0.setChild(readerChild)
        }
        let readerView = try ReaderHost.Typed<CapnpText>.read(from: reader.pointer)
        require(try readerView.payload() == "reader" && readerView.child().number == 11,
                "reserved Reader declaration and references")

        let builderChild = try BuilderChild.Value { $0.number = 22 }
        let builder = try BuilderHost.Typed<CapnpData>.Value {
            try $0.setPayload([2])
            try $0.setChild(builderChild)
        }
        let builderView = try BuilderHost.Typed<CapnpData>.read(from: builder.pointer)
        require(try builderView.payload() == [2] && builderView.child().number == 22,
                "reserved Builder declaration and references")

        let valueChild = try ValueChild.Value { $0.number = 33 }
        let value = try ValueHost.Typed<CapnpText>.Value {
            try $0.setPayload("value")
            try $0.setChild(valueChild)
        }
        let valueView = try ValueHost.Typed<CapnpText>.read(from: value.pointer)
        require(try valueView.payload() == "value" && valueView.child().number == 33,
                "reserved Value declaration and references")

        let pipelineChild = try PipelineChild.Value { $0.number = 44 }
        let pipeline = try PipelineHost.Typed<CapnpText>.Value {
            try $0.setPayload("pipeline")
            try $0.setChild(pipelineChild)
        }
        let pipelineView = try PipelineHost.Typed<CapnpText>.read(from: pipeline.pointer)
        require(try pipelineView.payload() == "pipeline" && pipelineView.child().number == 44,
                "reserved Pipeline declaration and references")

        let typedChild = try TypedChild.Value { $0.number = 55 }
        let typed = try TypedHost.Typed<CapnpText>.Value { try $0.setChild(typedChild) }
        require(try TypedHost.Typed<CapnpText>.read(from: typed.pointer).child().number == 55,
                "nested Typed keeps its schema name")

        let groups = try Groups.Typed.Value {
            $0.value.number = 66
            $0.pipeline.enabled = true
        }
        let groupView = try Groups.Typed.read(from: groups.pointer)
        require(groupView.value.number == 66 && groupView.pipeline.enabled,
                "reserved group declarations and references")

        let interfaceClient = try InterfaceClientChild.Value { $0.number = 77 }
        require(try InterfaceClientChild.read(from: interfaceClient.pointer).number == 77,
                "reserved interface Client declaration and references")
        let interfaceExport = try InterfaceExportChild.Value { $0.number = 88 }
        require(try InterfaceExportChild.read(from: interfaceExport.pointer).number == 88,
                "reserved interface Export declaration and references")
        let plain = try PlainNames.Typed.Value {
            try $0.setClient(PlainNames.Typed.Client.Value { $0.number = 99 })
            try $0.setExported(PlainNames.Typed.Export.Value { $0.number = 100 })
        }
        let plainView = try PlainNames.Typed.read(from: plain.pointer)
        require(try plainView.client().number == 99 && plainView.exported().number == 100,
                "Client and Export stay unchanged outside interfaces")

        let uses = try Uses.Typed.Value {
            try $0.setReader(readerChild)
            try $0.setBuilder(builderChild)
            try $0.setValue(valueChild)
            try $0.setPipeline(pipelineChild)
            try $0.setTyped(typedChild)
            try $0.setRpcClient(interfaceClient)
            try $0.setRpcExport(interfaceExport)
        }
        let usesView = try Uses.Typed.read(from: uses.pointer)
        require(try [usesView.reader().number, usesView.builder().number, usesView.value().number,
                     usesView.pipeline().number, usesView.typed().number, usesView.rpcClient().number,
                     usesView.rpcExport().number] == [11, 22, 33, 44, 55, 77, 88],
                "branded nested references share declaration spelling")

        let erased = ReaderHost.Reader(try reader.pointer.readStruct())
        require(erased.child.number == 11, "root and erased names remain compatible")
    }
}
