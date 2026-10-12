//! Open typed RPC applications; ordinary method-local handlers remain erased.
const std = @import("std");
const capnp = @import("capnp");
const schema = capnp.schema;
const resolver = capnp.type_resolver;
const Generator = @import("generator.zig").Generator;
const typed = @import("typed_emission.zig");

const Parameter = struct { scope: schema.Id, index: usize, name: []const u8 };
const Application = struct { node: *schema.Node, context: resolver.Context, codec: []const u8 };

fn pad(indent: usize) []const u8 {
    const spaces = "                                                                                                                                ";
    return spaces[0..@min(indent * 4, spaces.len)];
}

fn parameters(gen: *Generator, node: *schema.Node) ![]const Parameter {
    var scopes: std.ArrayList(*schema.Node) = .empty;
    var current = node;
    while (current.kind != .file) {
        if (scopes.items.len >= resolver.max_depth) return error.ScopeTooDeep;
        try scopes.append(gen.scratch(), current);
        current = gen.getNode(current.scope_id) orelse return error.MissingNode;
    }
    var result: std.ArrayList(Parameter) = .empty;
    var index = scopes.items.len;
    while (index > 0) {
        index -= 1;
        const scope = scopes.items[index];
        for (scope.parameters, 0..) |_, ordinal| try result.append(gen.scratch(), .{ .scope = scope.id, .index = ordinal, .name = try typed.parameterName(gen, scope.id, ordinal) });
    }
    return result.toOwnedSlice(gen.scratch());
}

fn parameterList(gen: *Generator, values: []const []const u8, constraint: bool) ![]const u8 {
    if (values.len == 0) return "";
    var result: std.Io.Writer.Allocating = .init(gen.scratch());
    try result.writer.writeByte('<');
    for (values, 0..) |value, index| {
        if (index != 0) try result.writer.writeAll(", ");
        try result.writer.writeAll(value);
        if (constraint) try result.writer.writeAll(": CapnpPointerSchema");
    }
    try result.writer.writeByte('>');
    return result.written();
}

fn methodArguments(gen: *Generator, method: schema.Method, erased: bool) ![]const []const u8 {
    const args = try gen.scratch().alloc([]const u8, method.implicit_parameters.len);
    for (args, 0..) |*arg, index| arg.* = if (erased) "CapnpAnyPointer" else try std.fmt.allocPrint(gen.scratch(), "M_{d}", .{index});
    return args;
}

fn namedApplication(gen: *Generator, context: *const resolver.Context, node: *schema.Node) ![]const u8 {
    return typed.codec(gen, context, try context.resolve(.{ .type = .{ .interface = .{ .type_id = node.id } } }), 0);
}

fn inherited(gen: *Generator, owner: Application, index: usize) !Application {
    const interface = owner.node.interface_node.?;
    const node = gen.getNode(interface.superclasses[index]) orelse return error.MissingNode;
    const expression = schema.TypeExpression{ .type = .{ .interface = .{ .type_id = node.id } }, .metadata = .{ .named = if (index < interface.superclass_brands.len) interface.superclass_brands[index] else .{} } };
    try owner.context.validate(expression);
    const value = try owner.context.resolve(expression);
    return .{ .node = node, .context = try owner.context.enter(value), .codec = try typed.codec(gen, &owner.context, value, 0) };
}

fn collect(gen: *Generator, application: Application, path: []const schema.Id, result: *std.ArrayList(Application)) anyerror!void {
    if (path.len >= resolver.max_depth) return error.InheritanceCycle;
    if (application.codec.len > 16_384) return error.ApplicationKeyLimit;
    for (path) |id| if (id == application.node.id) return error.InheritanceCycle;
    for (result.items) |existing| if (existing.node.id == application.node.id) {
        if (!std.mem.eql(u8, existing.codec, application.codec)) return error.ConflictingInheritedApplication;
        return;
    };
    if (result.items.len >= 256) return error.ApplicationLimit;
    try result.append(gen.scratch(), application);
    const next_path = try gen.scratch().alloc(schema.Id, path.len + 1);
    @memcpy(next_path[0..path.len], path);
    next_path[path.len] = application.node.id;
    for (application.node.interface_node.?.superclasses, 0..) |_, index| try collect(gen, try inherited(gen, application, index), next_path, result);
}

fn closure(gen: *Generator, node: *schema.Node, context: *const resolver.Context) ![]const Application {
    var result: std.ArrayList(Application) = .empty;
    try collect(gen, .{ .node = node, .context = context.*, .codec = try namedApplication(gen, context, node) }, &.{}, &result);
    return result.toOwnedSlice(gen.scratch());
}

fn payloadReference(gen: *Generator, application: Application, method: schema.Method, result: bool, args: []const []const u8) ![]const u8 {
    const node = gen.getNode(if (result) method.result_struct_type else method.param_struct_type) orelse return error.MissingNode;
    if (node.scope_id != 0) return typed.methodCodec(gen, &application.context, node, if (result) method.result_brand else method.param_brand, args);
    const method_name = try gen.capitalized(try gen.swiftMemberName(method.name));
    return std.fmt.allocPrint(gen.scratch(), "{s}.{s}{s}{s}", .{ application.codec, method_name, if (result) "Results" else "Params", try parameterList(gen, args, false) });
}

fn serverReference(gen: *Generator, node: *schema.Node, args: ?[]const Parameter) ![]const u8 {
    const name = try std.fmt.allocPrint(gen.scratch(), "{s}.TypedServer", .{try typed.namespaceReference(gen, node)});
    const values = args orelse return name;
    const names = try gen.scratch().alloc([]const u8, values.len);
    for (values, names) |value, *target| target.* = value.name;
    return std.fmt.allocPrint(gen.scratch(), "{s}{s}", .{ name, try parameterList(gen, names, false) });
}

fn emitValueConveniences(gen: *Generator, w: *std.Io.Writer, owner: Application, method: schema.Method, indent: usize) !void {
    if (method.implicit_parameters.len != 1) return;
    const payload = gen.getNode(method.param_struct_type) orelse return error.MissingNode;
    const structure = payload.struct_node orelse return error.InvalidSchema;
    if (structure.fields.len == 0 or structure.discriminant_count != 0) return;
    for (structure.fields) |field| if (std.mem.eql(u8, field.name, "isolation") or std.mem.eql(u8, field.name, "params")) return;
    for (structure.fields) |field| if (field.slot == null or switch (field.slot.?.type) {
        .text, .data, .any_pointer, .@"struct", .interface, .list => false,
        else => true,
    }) return;
    const old_aliases = gen.typed_parameter_aliases;
    const old_args = gen.typed_method_parameters;
    defer {
        gen.typed_parameter_aliases = old_aliases;
        gen.typed_method_parameters = old_args;
    }
    const context = try owner.context.enter(try owner.context.resolve(.{ .type = .{ .@"struct" = .{ .type_id = payload.id } }, .metadata = .{ .named = method.param_brand } }));
    const bindings = [_][]const u8{ "CapnpText", "CapnpData" };
    var field_types: [2][]const []const u8 = undefined;
    for (bindings, 0..) |binding, binding_index| {
        gen.typed_method_parameters = &.{binding};
        if (payload.scope_id == 0) {
            const aliases = try gen.scratch().alloc(Generator.TypedParameterAlias, old_aliases.len + 1);
            @memcpy(aliases[0..old_aliases.len], old_aliases);
            aliases[old_aliases.len] = .{ .scope_id = payload.id, .index = 0, .name = binding };
            gen.typed_parameter_aliases = aliases;
        }
        const names = try gen.scratch().alloc([]const u8, structure.fields.len);
        for (structure.fields, names) |field, *name| {
            const slot = field.slot.?;
            name.* = try typed.codec(gen, &context, try context.resolve(.{ .type = slot.type, .metadata = slot.type_metadata }), 0);
        }
        field_types[binding_index] = names;
    }
    var useful = false;
    for (field_types[0], field_types[1]) |text, data| if (!std.mem.eql(u8, text, data)) {
        useful = true;
        break;
    };
    if (!useful) return;
    for (bindings, field_types) |binding, types| {
        gen.typed_method_parameters = &.{binding};
        try w.print("{s}public func {s}(", .{ pad(indent), try gen.swiftMemberName(method.name) });
        for (structure.fields, types, 0..) |field, type_name, index| {
            if (index != 0) try w.writeAll(", ");
            try w.print("{s}: {s}.Value", .{ try typed.accessorName(gen, payload, field), type_name });
        }
        try w.print(", isolation: isolated (any Actor)? = #isolation) async throws -> {s}.Reader {{\n{s}    try await {s}(as: {s}.self, isolation: isolation) {{ params in\n", .{ try payloadReference(gen, owner, method, true, &.{binding}), pad(indent), try gen.swiftMemberName(method.name), binding });
        for (structure.fields) |field| {
            const slot = field.slot.?;
            const name = try typed.accessorName(gen, payload, field);
            try w.print("{s}        {s}params.set{s}({s})\n", .{ pad(indent), if (slot.type == .text or slot.type == .data) "" else "try ", try gen.capitalized(name), name });
        }
        try w.print("{s}    }}\n{s}}}\n", .{ pad(indent), pad(indent) });
    }
}

pub fn emitServer(gen: *Generator, w: *std.Io.Writer, node: *schema.Node, context: *const resolver.Context, indent: usize) anyerror!void {
    const previous = gen.typed_parameter_scopes;
    defer gen.typed_parameter_scopes = previous;
    const own_parameters = try parameters(gen, node);
    const scopes = try gen.scratch().alloc(schema.Id, own_parameters.len);
    for (own_parameters, scopes) |parameter, *scope| scope.* = parameter.scope;
    gen.typed_parameter_scopes = scopes;
    const applications = try closure(gen, node, context);
    const owner = applications[0];
    const names = try gen.scratch().alloc([]const u8, own_parameters.len);
    for (own_parameters, names) |parameter, *name| name.* = parameter.name;
    try w.print("{s}public protocol TypedServer{s}: Sendable", .{ pad(indent), try parameterList(gen, names, false) });
    const interface = node.interface_node.?;
    for (interface.superclasses, 0..) |_, index| try w.print(", {s}", .{try serverReference(gen, (try inherited(gen, owner, index)).node, null)});
    var constraints: std.ArrayList([]const u8) = .empty;
    for (interface.superclasses, 0..) |_, index| {
        const parent = try inherited(gen, owner, index);
        for (try parameters(gen, parent.node)) |parameter| {
            const resolved = try parent.context.resolve(.{ .type = .any_pointer, .metadata = .{ .any_pointer = .{ .parameter = .{ .scope_id = parameter.scope, .parameter_index = @intCast(parameter.index) } } } });
            const binding = try typed.codec(gen, &parent.context, resolved, 0);
            if (!std.mem.eql(u8, parameter.name, binding)) try constraints.append(gen.scratch(), try std.fmt.allocPrint(gen.scratch(), "{s} == {s}", .{ parameter.name, binding }));
        }
    }
    for (constraints.items, 0..) |constraint, index| try w.print("{s}{s}", .{ if (index == 0) " where " else ", ", constraint });
    try w.writeAll(" {\n");
    for (own_parameters) |parameter| try w.print("{s}associatedtype {s}: CapnpPointerSchema\n", .{ pad(indent + 1), parameter.name });
    for (interface.methods) |method| {
        if (method.isStreaming()) return error.UnsupportedTypedStreaming;
        const args = try methodArguments(gen, method, true);
        try w.print("{s}func {s}(params: {s}.Reader, on connection: isolated RPCConnection) async throws -> {s}.Value\n", .{ pad(indent + 1), try gen.swiftMemberName(method.name), try payloadReference(gen, owner, method, false, args), try payloadReference(gen, owner, method, true, args) });
    }
    try w.print("{s}}}\n", .{pad(indent)});
}

pub fn emitInterface(gen: *Generator, w: *std.Io.Writer, node: *schema.Node, context: *const resolver.Context, indent: usize) anyerror!void {
    const applications = try closure(gen, node, context);
    const owner = applications[0];
    const interface = node.interface_node.?;
    try w.print("{s}public static var interfaceID: UInt64 {{ 0x{x} }}\n", .{ pad(indent), node.id });
    for (interface.methods) |method| {
        if (method.isStreaming()) return error.UnsupportedTypedStreaming;
        const args = try methodArguments(gen, method, false);
        const name = try gen.capitalized(try gen.swiftMemberName(method.name));
        try typed.emitMethodPayload(gen, w, context, node, gen.getNode(method.param_struct_type) orelse return error.MissingNode, method.param_brand, try std.fmt.allocPrint(gen.scratch(), "{s}Params", .{name}), args, indent);
        try typed.emitMethodPayload(gen, w, context, node, gen.getNode(method.result_struct_type) orelse return error.MissingNode, method.result_brand, try std.fmt.allocPrint(gen.scratch(), "{s}Results", .{name}), args, indent);
    }
    try w.print("{s}public typealias Reader = Client?\n{s}public typealias Value = Client?\n", .{ pad(indent), pad(indent) });
    try w.print("{s}public static func read(from pointer: PointerReader) throws -> Reader {{\n{s}    guard let capability = try RPCPointerCapability.read(from: pointer) else {{ return nil }}\n{s}    return Client(capability: capability)\n{s}}}\n", .{ pad(indent), pad(indent), pad(indent), pad(indent) });
    try w.print("{s}public static func write(_ value: Value, to pointer: PointerBuilder) throws {{\n{s}    if let value {{ try value.capability.write(to: pointer) }} else {{ try pointer.setNull() }}\n{s}}}\n", .{ pad(indent), pad(indent), pad(indent) });
    try w.print("{s}public struct Client: Sendable {{\n{s}    public let capability: RPCPointerCapability\n{s}    public var connection: RPCConnection {{ capability.connection }}\n{s}    public init(capability: RPCPointerCapability) {{ self.capability = capability }}\n{s}    public init(cap: CapRef, connection: RPCConnection) throws {{ capability = try RPCPointerCapability(cap: cap, connection: connection) }}\n{s}    public init(pipelined: PipelinedCap, connection: RPCConnection) throws {{ capability = try RPCPointerCapability(pipelined: pipelined, connection: connection) }}\n", .{ pad(indent), pad(indent), pad(indent), pad(indent), pad(indent), pad(indent) });
    const server = try serverReference(gen, node, try parameters(gen, node));
    try w.print("{s}    public init(server: any {s}, connection: RPCConnection) {{ capability = RPCPointerCapability(server: Export(server), connection: connection) }}\n", .{ pad(indent), server });
    var used_names: std.ArrayList([]const u8) = .empty;
    try used_names.appendSlice(gen.scratch(), &.{ "connection", "capability" });
    for (interface.superclasses, 0..) |_, index| {
        const parent = try inherited(gen, owner, index);
        const plain = try gen.swiftMemberName(try gen.lowerFirst(try typed.declarationName(gen, parent.node)));
        var name = plain;
        var suffix: usize = 2;
        while (blk: {
            for (used_names.items) |used| if (std.mem.eql(u8, used, name)) break :blk true;
            break :blk false;
        }) : (suffix += 1) name = try std.fmt.allocPrint(gen.scratch(), "{s}{d}", .{ gen.unescaped(plain), suffix });
        try used_names.append(gen.scratch(), name);
        try w.print("{s}    public var {s}: {s}.Client {{ {s}.Client(capability: capability) }}\n", .{ pad(indent), name, parent.codec, parent.codec });
    }
    for (interface.methods, 0..) |method, ordinal| {
        if (ordinal > std.math.maxInt(u16)) return error.InvalidSchema;
        const args = try methodArguments(gen, method, false);
        const params = try payloadReference(gen, owner, method, false, args);
        const results = try payloadReference(gen, owner, method, true, args);
        try w.print("{s}    public func {s}{s}(", .{ pad(indent), try gen.swiftMemberName(method.name), try parameterList(gen, args, true) });
        for (args, 0..) |arg, index| try w.print("{s}{s}: {s}.Type, ", .{ if (index == 0) "as " else "as", if (index == 0) "schema" else try std.fmt.allocPrint(gen.scratch(), "{d}", .{index}), arg });
        try w.print("isolation: isolated (any Actor)? = #isolation, _ build: ({s}.Builder) throws -> Void = {{ _ in }}) async throws -> {s}.Reader {{\n", .{ params, results });
        try w.print("{s}        let params = try {s}.Value(build)\n{s}        let result = try await capability.call(interface: 0x{x}, method: {d}, params: params.pointer)\n{s}        return try {s}.read(from: result)\n{s}    }}\n", .{ pad(indent), params, pad(indent), node.id, ordinal, pad(indent), results, pad(indent) });
        try emitValueConveniences(gen, w, owner, method, indent + 1);
    }
    try w.print("{s}}}\n{s}public struct Export: ExportHandler {{\n{s}    public let server: any {s}\n{s}    public init(_ server: any {s}) {{ self.server = server }}\n{s}    public func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {{\n{s}        do {{\n{s}            switch call.interfaceID {{\n", .{ pad(indent), pad(indent), pad(indent), server, pad(indent), server, pad(indent), pad(indent), pad(indent) });
    for (applications) |application| {
        try w.print("{s}            case 0x{x}:\n{s}                switch call.methodID {{\n", .{ pad(indent), application.node.id, pad(indent) });
        for (application.node.interface_node.?.methods, 0..) |method, ordinal| {
            const args = try methodArguments(gen, method, true);
            const params = try payloadReference(gen, application, method, false, args);
            try w.print("{s}                case {d}:\n{s}                    let params = try {s}.read(from: connection.pointerPayload(call: call))\n{s}                    let results = try await server.{s}(params: params, on: connection)\n{s}                    let payload = try results.pointer.serialized()\n{s}                    return CallResponse(message: payload.bytes, caps: try connection.pointerSlots(payload.capabilities))\n", .{ pad(indent), ordinal, pad(indent), params, pad(indent), try gen.swiftMemberName(method.name), pad(indent), pad(indent) });
        }
        try w.print("{s}                default: throw RPCError.unimplemented(reason: \"unknown typed method\")\n{s}                }}\n", .{ pad(indent), pad(indent) });
    }
    try w.print("{s}            default: throw RPCError.unimplemented(reason: \"unknown typed interface\")\n{s}            }}\n{s}        }} catch let error as CapnpError {{ throw RPCError.malformed(\"\\(error)\") }}\n{s}    }}\n{s}}}\n", .{ pad(indent), pad(indent), pad(indent), pad(indent), pad(indent) });
}

test "typed inheritance cycles refuse complete source generation" {
    var nested = [_]schema.Node.NestedNode{.{ .name = "Cycle", .id = 0x8000_0000_0000_0002 }};
    var parents = [_]schema.Id{0x8000_0000_0000_0002};
    const file_id: schema.Id = 0x8000_0000_0000_0001;
    var nodes = [_]schema.Node{
        .{ .id = file_id, .display_name = "cycle.capnp", .display_name_prefix_length = 0, .scope_id = 0, .nested_nodes = &nested, .annotations = &.{}, .kind = .file, .struct_node = null, .enum_node = null, .interface_node = null, .const_node = null, .annotation_node = null },
        .{ .id = parents[0], .display_name = "cycle.capnp:Cycle", .display_name_prefix_length = 12, .scope_id = file_id, .nested_nodes = &.{}, .annotations = &.{}, .kind = .interface, .struct_node = null, .enum_node = null, .interface_node = .{ .methods = &.{}, .superclasses = &parents }, .const_node = null, .annotation_node = null },
    };
    var gen = try Generator.init(std.testing.allocator, &nodes);
    defer gen.deinit();
    gen.typed_generics = true;
    try std.testing.expectError(error.InheritanceCycle, gen.generateFile(.{ .id = file_id, .filename = "cycle.capnp", .imports = &.{} }));
}
