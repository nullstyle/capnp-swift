//! Optional concrete RPC glue: one Swift type per effective application.
const std = @import("std");
const graph = @import("application_graph.zig");

pub fn emitStruct(w: *std.Io.Writer, app: graph.Application, index: usize, applications: []const graph.Application, method_generics: bool) !void {
    const structure = app.node.struct_node.?;
    try w.print("// {s}\npublic enum App{d} {{\n", .{ app.key, index });
    for (app.fields) |field| if (field.shape == .capability) {
        try w.print("    public typealias {c}{s}Capability = App{d}\n", .{ std.ascii.toUpper(field.name[0]), field.name[1..], field.shape.capability });
    };
    try w.print("    public static func initRoot(_ message: MessageBuilder) -> Builder {{ Builder(message.initRoot(dataWords: {d}, pointerWords: {d})) }}\n", .{ structure.data_word_count, structure.pointer_count });
    try w.writeAll(
        \\    public struct Value: Sendable {
        \\        public let bytes: [UInt8]
        \\        public let caps: [CapSlot]
    );
    if (method_generics) try w.writeAll("\n        public init(_ body: (Builder) throws -> Void = { _ in }) rethrows {\n") else try w.writeAll("\n        public init(_ body: (Builder) -> Void = { _ in }) {\n");
    try w.writeAll(
        \\            let message = MessageBuilder()
        \\            let builder = initRoot(message)
    );
    if (method_generics) try w.writeAll("\n            try body(builder)\n") else try w.writeAll("\n            body(builder)\n");
    try w.writeAll(
        \\            bytes = message.toBytes()
        \\            caps = builder.capSlots
        \\        }
        \\    }
        \\    public struct Reader: Sendable {
        \\        private let _raw: StructReader
        \\        public let caps: [CapTableEntry]
        \\        public init(_ raw: StructReader, caps: [CapTableEntry] = []) { _raw = raw; self.caps = caps }
        \\
    );
    for (app.fields, 0..) |field, ordinal| switch (field.shape) {
        .@"opaque" => try w.print("        public func `{s}`() -> SpecializedPointer {{ SpecializedPointer(pointer: _raw.probePointer({d}), caps: caps) }}\n", .{ field.name, field.offset }),
        .text => try w.print("        public func `{s}`() throws -> String {{ try _raw.readTextOrDefault({d}) }}\n", .{ field.name, field.offset }),
        .data => try w.print("        public func `{s}`() throws -> [UInt8] {{ try _raw.readDataOrDefault({d}) }}\n", .{ field.name, field.offset }),
        .structure => |target| try w.print("        public func `{s}`() -> App{d}.Reader {{ App{d}.Reader(_raw.readStructOrDefault({d}), caps: caps) }}\n", .{ field.name, target, target, field.offset }),
        .integers => |name| try w.print("        public func `{s}`() throws -> FixedSizeListReader<{s}>? {{ try _raw.readFixedSizeListOrDefault({d}, as: {s}.self) }}\n", .{ field.name, name, field.offset, name }),
        .structures => |target| {
            try w.print("        public struct List{d}: Sendable {{\n            fileprivate let _raw: StructListReader\n            fileprivate let caps: [CapTableEntry]\n            public var count: Int {{ _raw.count }}\n            public var indices: Range<Int> {{ _raw.indices }}\n            public subscript(index: Int) -> App{d}.Reader {{ App{d}.Reader(_raw[index], caps: caps) }}\n        }}\n", .{ ordinal, target, target });
            try w.print("        public func `{s}`() throws -> List{d}? {{ try _raw.readStructListOrDefault({d}).map {{ List{d}(_raw: $0, caps: caps) }} }}\n", .{ field.name, ordinal, field.offset, ordinal });
        },
        .capability => |target| {
            try w.print("        public func `{s}`(on connection: RPCConnection) throws -> App{d}.Client? {{\n            guard let index = try _raw.readCapabilityIndex({d}) else {{ return nil }}\n            guard Int(index) < caps.count else {{ throw RPCError.malformed(\"capability index outside payload table\") }}\n            switch caps[Int(index)] {{\n            case .none: return nil\n            case .imported(let cap): return App{d}.Client(cap: cap, connection: connection)\n            case .exported: throw RPCError.unimplemented(reason: \"local capability views are outside the specialization probe\")\n            }}\n        }}\n", .{ field.name, target, field.offset, target });
        },
    };
    try w.writeAll(
        \\    }
        \\    public struct Builder {
        \\        private let _raw: StructBuilder
        \\        fileprivate let _caps: SpecializedCapSlots
        \\        public var capSlots: [CapSlot] { _caps.slots }
        \\        public init(_ raw: StructBuilder) { _raw = raw; _caps = SpecializedCapSlots() }
        \\        fileprivate init(_ raw: StructBuilder, caps: SpecializedCapSlots) { _raw = raw; _caps = caps }
        \\
    );
    for (app.fields, 0..) |field, ordinal| {
        const initial = std.ascii.toUpper(field.name[0]);
        const rest = field.name[1..];
        switch (field.shape) {
            .@"opaque" => try w.print("        public func set{c}{s}(_ value: SpecializedPointer) throws {{ try value.copy(into: _raw, index: {d}, slots: _caps) }}\n", .{ initial, rest, field.offset }),
            .text => try w.print("        public func set{c}{s}(_ value: String) {{ _raw.setText({d}, value) }}\n", .{ initial, rest, field.offset }),
            .data => try w.print("        public func set{c}{s}(_ value: [UInt8]) {{ _raw.setData({d}, value) }}\n", .{ initial, rest, field.offset }),
            .structure => |target| {
                const shape = applications[target].node.struct_node.?;
                try w.print("        public func init{c}{s}() -> App{d}.Builder {{ App{d}.Builder(_raw.initStruct({d}, dataWords: {d}, pointerWords: {d}), caps: _caps) }}\n", .{ initial, rest, target, target, field.offset, shape.data_word_count, shape.pointer_count });
            },
            .integers => |name| try w.print("        public func init{c}{s}(_ count: Int) -> FixedSizeListBuilder<{s}> {{ _raw.initFixedSizeList({d}, count: count, as: {s}.self) }}\n", .{ initial, rest, name, field.offset, name }),
            .structures => |target| {
                const shape = applications[target].node.struct_node.?;
                try w.print("        public struct List{d} {{\n            fileprivate let _raw: StructListBuilder\n            fileprivate let _caps: SpecializedCapSlots\n            public var count: Int {{ _raw.count }}\n            public subscript(index: Int) -> App{d}.Builder {{ App{d}.Builder(_raw[index], caps: _caps) }}\n        }}\n", .{ ordinal, target, target });
                try w.print("        public func init{c}{s}(_ count: Int) -> List{d} {{ List{d}(_raw: _raw.initStructList({d}, dataWords: {d}, pointerWords: {d}, count: count), _caps: _caps) }}\n", .{ initial, rest, ordinal, ordinal, field.offset, shape.data_word_count, shape.pointer_count });
            },
            .capability => |target| {
                try w.print("        public func set{c}{s}(_ server: any App{d}.Server) {{\n            _raw.setCapability({d}, capIndex: UInt32(_caps.slots.count))\n            _caps.slots.append(.export(App{d}.Export(server)))\n        }}\n", .{ initial, rest, target, field.offset, target });
                try w.print("        public func set{c}{s}(_ client: App{d}.Client) {{\n            _raw.setCapability({d}, capIndex: UInt32(_caps.slots.count))\n            switch client.target {{\n            case .cap(let cap): _caps.slots.append(.imported(cap))\n            case .pipelined(let cap): _caps.slots.append(.pipelined(cap))\n            }}\n        }}\n", .{ initial, rest, target, field.offset });
            },
        }
    }
    try w.writeAll("    }\n}\n");
}

pub fn emitInterface(w: *std.Io.Writer, app: graph.Application, index: usize, applications: []const graph.Application, method_generics: bool) !void {
    try w.print("// {s}\npublic enum App{d} {{\n    public static let interfaceID: UInt64 = 0x{x}\n", .{ app.key, index, app.node.id });
    for (app.parents, 0..) |parent, ordinal| try w.print("    public typealias Super{d} = App{d}\n", .{ ordinal, parent });
    for (app.methods) |method| {
        try w.print("    public typealias {c}{s}Params = App{d}\n    public typealias {c}{s}Results = App{d}\n", .{ std.ascii.toUpper(method.name[0]), method.name[1..], method.params, std.ascii.toUpper(method.name[0]), method.name[1..], method.results });
    }
    for (app.methods) |method| for (method.cases) |call_case| {
        try w.print("    public typealias {c}{s}Params = App{d}\n    public typealias {c}{s}Results = App{d}\n", .{ std.ascii.toUpper(call_case.name[0]), call_case.name[1..], call_case.params, std.ascii.toUpper(call_case.name[0]), call_case.name[1..], call_case.results });
    };
    try w.writeAll("    public protocol Server: Sendable");
    for (app.parents) |parent| try w.print(", App{d}.Server", .{parent});
    try w.writeAll(" {\n");
    for (app.methods) |method| try w.print("        func `{s}`(params: App{d}.Reader, on connection: RPCConnection) async throws -> App{d}.Value\n", .{ method.name, method.params, method.results });
    try w.writeAll(
        \\    }
        \\    public struct Client: Sendable {
        \\        public let target: CallTarget
        \\        public let connection: RPCConnection
        \\        public init(cap: CapRef, connection: RPCConnection) { target = .cap(cap); self.connection = connection }
        \\        public init(pipelined: PipelinedCap, connection: RPCConnection) { target = .pipelined(pipelined); self.connection = connection }
        \\        fileprivate init(target: CallTarget, connection: RPCConnection) { self.target = target; self.connection = connection }
        \\
    );
    for (app.parents, 0..) |parent, ordinal| try w.print("        public var super{d}: App{d}.Client {{ App{d}.Client(target: target, connection: connection) }}\n", .{ ordinal, parent, parent });
    for (app.methods) |method| {
        try emitCall(w, method.name, method.params, method.results, method.ordinal, index, method_generics);
        for (method.cases) |call_case| try emitCall(w, call_case.name, call_case.params, call_case.results, method.ordinal, index, method_generics);
    }
    try w.writeAll(
        \\    }
        \\    public struct Export: ExportHandler {
        \\        public let server: any Server
        \\        public init(_ server: any Server) { self.server = server }
        \\        public func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {
        \\            do {
        \\                switch call.interfaceID {
        \\
    );
    for (app.closure) |ancestor| {
        try w.print("                case App{d}.interfaceID:\n                    switch call.methodID {{\n", .{ancestor});
        for (applications[ancestor].methods) |method| {
            try w.print("                    case {d}:\n                        let params = try App{d}.Reader(Message(bytes: call.params).rootStruct(), caps: call.caps)\n                        let result: App{d}.Value = try await server.`{s}`(params: params, on: connection)\n                        return CallResponse(message: result.bytes, caps: result.caps)\n", .{ method.ordinal, method.params, method.results, method.name });
        }
        try w.writeAll("                    default: throw RPCError.unimplemented(reason: \"unknown method\")\n                    }\n");
    }
    try w.writeAll(
        \\                default: throw RPCError.unimplemented(reason: "unknown interface")
        \\                }
        \\            } catch let error as CapnpError { throw RPCError.malformed("\(error)") }
        \\        }
        \\    }
        \\}
        \\
    );
}

fn emitCall(w: *std.Io.Writer, name: []const u8, params: usize, results: usize, ordinal: u16, interface: usize, method_generics: bool) !void {
    try w.print("        public func `{s}`(_ body: (App{d}.Builder)", .{ name, params });
    if (method_generics) try w.writeAll(" throws");
    try w.print(" -> Void = {{ _ in }}) async throws -> App{d}.Reader {{\n            let params = ", .{results});
    if (method_generics) try w.writeAll("try ");
    try w.print("App{d}.Value(body)\n            let result = try await connection.call(target, interface: App{d}.interfaceID, method: {d}, params: params.bytes, caps: params.caps)\n            do {{ return try App{d}.Reader(Message(bytes: result.message).rootStruct(), caps: result.caps) }}\n            catch let error as CapnpError {{ throw RPCError.malformed(\"\\(error)\") }}\n        }}\n", .{ params, interface, ordinal, results });
}

pub fn emitPointerSupport(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\// Erased server values retain their message and capability table.
        \\public struct SpecializedPointer: Sendable {
        \\    public let pointer: ProbePointer
        \\    public let caps: [CapTableEntry]
        \\    fileprivate func copy(into builder: StructBuilder, index: Int, slots: SpecializedCapSlots) throws {
        \\        var mapped: [UInt32: UInt32] = [:]
        \\        try pointer.copy(into: builder, index: index) { source in
        \\            if let index = mapped[source] { return index }
        \\            guard Int(source) < caps.count else { throw RPCError.malformed("generic pointer capability index out of range") }
        \\            let slot: CapSlot
        \\            switch caps[Int(source)] {
        \\            case .none: slot = .none
        \\            case .imported(let cap): slot = .imported(cap)
        \\            case .exported: throw RPCError.unimplemented(reason: "local capability copying is outside the method-generics probe")
        \\            }
        \\            let index = UInt32(slots.slots.count)
        \\            slots.slots.append(slot)
        \\            mapped[source] = index
        \\            return index
        \\        }
        \\    }
        \\}
        \\
    );
    try w.writeByte('\n');
}
