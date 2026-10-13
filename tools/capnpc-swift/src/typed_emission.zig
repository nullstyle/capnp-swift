//! Opt-in open schema applications. Existing erased declarations are unchanged.
//! Resolver contexts borrow the request and never escape source generation.
const std = @import("std");
const capnp = @import("capnp");
const schema = capnp.schema;
const resolver = capnp.type_resolver;
const Generator = @import("generator.zig").Generator;
const rpc = @import("typed_rpc_emission.zig");

pub fn emitFile(gen: *Generator, w: *std.Io.Writer, file: *schema.Node) !void {
    const previous_mode = gen.typed_reference_mode;
    defer gen.typed_reference_mode = previous_mode;
    gen.typed_reference_mode = true;
    try w.writeAll("#if canImport(CapnpRPC)\n@_spi(Generated) import CapnpRPC\n#endif\n\n");
    try w.writeAll("// Open typed schema applications (opt-in --typed).\n\n");
    for (file.nested_nodes) |nested| if (gen.typed_name_overrides.get(nested.id)) |alias| {
        const node = gen.getNode(nested.id) orelse return error.MissingNode;
        try w.print("public typealias {s} = {s}\n", .{ alias, gen.swiftTypeName(node) });
    };
    for (file.nested_nodes) |nested| try emitServerDeclarations(gen, w, gen.getNode(nested.id) orelse return error.MissingNode, 0);
    for (file.nested_nodes) |nested| try rpc.emitPipelineConformances(gen, w, gen.getNode(nested.id) orelse return error.MissingNode);
    for (file.nested_nodes) |nested| {
        const node = gen.getNode(nested.id) orelse return error.MissingNode;
        if (node.kind != .@"struct" and node.kind != .interface) continue;
        if (node.struct_node) |s| if (s.is_group) continue;
        const context = try resolver.Context.init(gen.nodes, node, .{});
        try w.print("extension {s} {{\n", .{gen.swiftTypeName(node)});
        try emitDeclaration(gen, w, node, &context, "Typed", 1);
        try w.writeAll("}\n\n");
    }
}

fn padding(indent: usize) []const u8 {
    const spaces = "                                                                                                                                ";
    return spaces[0..@min(indent * 4, spaces.len)];
}

pub fn parameterName(gen: *Generator, scope: schema.Id, index: usize) ![]const u8 {
    for (gen.typed_parameter_aliases) |alias| if (alias.scope_id == scope and alias.index == index) return alias.name;
    const node = gen.getNode(scope) orelse return error.MissingNode;
    if (index >= node.parameters.len) return error.InvalidSchema;
    const start = if (std.mem.lastIndexOfScalar(u8, node.display_name, ':')) |colon| colon + 1 else 0;
    const readable = try std.fmt.allocPrint(gen.scratch(), "{s}_{s}_{x}_{d}", .{ node.display_name[start..], node.parameters[index].name, scope, index });
    return gen.swiftIdentifierAlloc(readable);
}

pub fn declarationName(gen: *Generator, node: *schema.Node) ![]const u8 {
    const parent = gen.getNode(node.scope_id) orelse return gen.swiftTypeName(node);
    if (parent.kind == .file) return gen.swiftTypeName(node);
    for (parent.nested_nodes) |nested| if (nested.id == node.id) {
        return nestedDeclarationName(gen, try gen.swiftIdentifierAlloc(nested.name), node.id, parent.kind == .interface);
    };
    return error.MissingDeclarationName;
}

fn nestedDeclarationName(gen: *Generator, name: []const u8, id: schema.Id, interface_parent: bool) ![]const u8 {
    // These names belong to the generated schema codec and pipeline views.
    // A node ID gives the schema child one spelling across files and brands.
    for ([_][]const u8{ "Reader", "Builder", "Value", "Pipeline" }) |reserved| {
        if (std.mem.eql(u8, gen.unescaped(name), reserved)) {
            return std.fmt.allocPrint(gen.scratch(), "{s}_Node{x}", .{ gen.unescaped(name), id });
        }
    }
    if (interface_parent) {
        for ([_][]const u8{ "Client", "Export" }) |reserved| {
            if (std.mem.eql(u8, gen.unescaped(name), reserved)) {
                return std.fmt.allocPrint(gen.scratch(), "{s}_Node{x}", .{ gen.unescaped(name), id });
            }
        }
    }
    return name;
}

pub fn groupDeclarationName(gen: *Generator, field: schema.Field) ![]const u8 {
    const group = field.group orelse return error.MissingGroup;
    return nestedDeclarationName(gen, try gen.groupTypeName(field), group.type_id, false);
}

fn genericParameters(gen: *Generator, node: *schema.Node, constraints: bool) ![]const u8 {
    if (node.parameters.len == 0) return "";
    var result: std.Io.Writer.Allocating = .init(gen.scratch());
    try result.writer.writeByte('<');
    for (node.parameters, 0..) |_, i| {
        if (i != 0) try result.writer.writeAll(", ");
        try result.writer.writeAll(try parameterName(gen, node.id, i));
        if (constraints) try result.writer.writeAll(": CapnpPointerSchema");
    }
    try result.writer.writeByte('>');
    return result.written();
}

fn emitServerDeclarations(gen: *Generator, w: *std.Io.Writer, node: *schema.Node, depth: usize) anyerror!void {
    if (depth >= resolver.max_depth) return error.ScopeTooDeep;
    if (node.kind == .@"enum") {
        try w.print("extension {s}: RawRepresentable {{}}\n\n", .{gen.swiftRef(node)});
        return;
    }
    if (node.kind == .interface) {
        const context = try resolver.Context.init(gen.nodes, node, .{});
        try w.print("extension {s} {{\n", .{gen.swiftRef(node)});
        try rpc.emitServer(gen, w, node, &context, 1);
        try w.writeAll("}\n\n");
    }
    for (node.nested_nodes) |nested| {
        const child = gen.getNode(nested.id) orelse return error.MissingNode;
        if (child.scope_id == node.id and (child.kind == .@"struct" or child.kind == .interface or child.kind == .@"enum")) try emitServerDeclarations(gen, w, child, depth + 1);
    }
}

pub fn emitMethodPayload(gen: *Generator, w: *std.Io.Writer, owner: *const resolver.Context, owner_node: *schema.Node, payload: *schema.Node, brand: schema.Brand, name: []const u8, method_args: []const []const u8, indent: usize) anyerror!void {
    const old_args = gen.typed_method_parameters;
    const old_aliases = gen.typed_parameter_aliases;
    defer {
        gen.typed_method_parameters = old_args;
        gen.typed_parameter_aliases = old_aliases;
    }
    gen.typed_method_parameters = method_args;
    const expression = schema.TypeExpression{ .type = .{ .@"struct" = .{ .type_id = payload.id } }, .metadata = .{ .named = brand } };
    try owner.validate(expression);
    if (payload.scope_id != 0) {
        // A named child already has this declaration in Typed. Method calls
        // reference its fully branded codec directly; repeating a convenience
        // alias would redeclare the type, including generic child declarations.
        if (payload.scope_id == owner_node.id and std.mem.eql(u8, name, try declarationName(gen, payload))) return;
        try w.print("{s}public typealias {s}", .{ padding(indent), name });
        if (method_args.len != 0) {
            try w.writeByte('<');
            for (method_args, 0..) |arg, i| {
                if (i != 0) try w.writeAll(", ");
                try w.print("{s}: CapnpPointerSchema", .{arg});
            }
            try w.writeByte('>');
        }
        try w.print(" = {s}\n", .{try codec(gen, owner, try owner.resolve(expression), 0)});
        return;
    }
    if (payload.parameters.len != method_args.len) return error.InvalidMethodParameters;
    const aliases = try gen.scratch().alloc(Generator.TypedParameterAlias, old_aliases.len + method_args.len);
    @memcpy(aliases[0..old_aliases.len], old_aliases);
    for (method_args, 0..) |arg, index| aliases[old_aliases.len + index] = .{ .scope_id = payload.id, .index = index, .name = arg };
    gen.typed_parameter_aliases = aliases;
    const context = try owner.enter(try owner.resolve(expression));
    try emitDeclaration(gen, w, payload, &context, name, indent);
}

pub fn methodCodec(gen: *Generator, owner: *const resolver.Context, payload: *schema.Node, brand: schema.Brand, method_args: []const []const u8) anyerror![]const u8 {
    if (payload.scope_id == 0) return error.AnonymousPayloadNeedsMethodName;
    const old_args = gen.typed_method_parameters;
    defer gen.typed_method_parameters = old_args;
    gen.typed_method_parameters = method_args;
    const expression = schema.TypeExpression{ .type = .{ .@"struct" = .{ .type_id = payload.id } }, .metadata = .{ .named = brand } };
    try owner.validate(expression);
    return codec(gen, owner, try owner.resolve(expression), 0);
}

pub fn emitDeclaration(gen: *Generator, w: *std.Io.Writer, node: *schema.Node, context: *const resolver.Context, name: []const u8, indent: usize) anyerror!void {
    if (indent > 32) return error.ScopeTooDeep;
    const pad = padding(indent);
    const structure = node.struct_node;
    const previous_scopes = gen.typed_parameter_scopes;
    defer gen.typed_parameter_scopes = previous_scopes;
    if (node.parameters.len != 0) {
        const scopes = try gen.scratch().alloc(schema.Id, previous_scopes.len + 1);
        @memcpy(scopes[0..previous_scopes.len], previous_scopes);
        scopes[previous_scopes.len] = node.id;
        gen.typed_parameter_scopes = scopes;
    }
    try w.print("{s}public enum {s}{s}{s} {{\n", .{ pad, name, try genericParameters(gen, node, true), if (structure != null) ": CapnpStructSchema" else if (node.kind == .interface) ": CapnpPointerSchema" else "" });
    for (node.nested_nodes) |nested| {
        const child = gen.getNode(nested.id) orelse return error.MissingNode;
        if (child.scope_id != node.id) continue;
        if (child.kind != .@"struct" and child.kind != .interface) continue;
        if (child.struct_node) |s| if (s.is_group) continue;
        const child_expression = schema.TypeExpression{ .type = if (child.kind == .interface) .{ .interface = .{ .type_id = child.id } } else .{ .@"struct" = .{ .type_id = child.id } } };
        try context.validate(child_expression);
        const child_context = try context.enter(try context.resolve(child_expression));
        try emitDeclaration(gen, w, child, &child_context, try declarationName(gen, child), indent + 1);
    }
    if (node.kind == .interface) try rpc.emitInterface(gen, w, node, context, indent + 1);
    if (structure) |s| {
        // Groups are views over this struct's allocation and lexical bindings.
        for (s.fields) |field| if (field.group) |group| {
            const child = gen.getNode(group.type_id) orelse return error.MissingNode;
            const child_context = try resolver.Context.init(gen.nodes, child, .{});
            try emitDeclaration(gen, w, child, &child_context, try groupDeclarationName(gen, field), indent + 1);
        };
        try emitStruct(gen, w, node, context, indent + 1);
    }
    try w.print("{s}}}\n", .{pad});
}

pub fn codec(gen: *Generator, context: *const resolver.Context, value: resolver.Type, depth: usize) anyerror![]const u8 {
    if (depth >= resolver.max_depth) return error.TypeDepthLimit;
    if (value.unbound) {
        if (value.expression.metadata == .any_pointer and value.expression.metadata.any_pointer == .implicit_method_parameter) {
            const index = value.expression.metadata.any_pointer.implicit_method_parameter.parameter_index;
            if (index >= gen.typed_method_parameters.len) return error.UnsupportedImplicitParameter;
            return gen.typed_method_parameters[index];
        }
        const parameter = value.parameter() orelse return error.UnsupportedImplicitParameter;
        const scope = gen.getNode(parameter.scope_id) orelse return error.MissingNode;
        if (parameter.parameter_index >= scope.parameters.len) return error.InvalidSchema;
        for (gen.typed_parameter_aliases) |alias| if (alias.scope_id == parameter.scope_id and alias.index == parameter.parameter_index) return alias.name;
        for (gen.typed_parameter_scopes) |bound_scope| if (bound_scope == parameter.scope_id) return parameterName(gen, parameter.scope_id, parameter.parameter_index);
        return "CapnpAnyPointer";
    }
    return switch (value.expression.type) {
        .text => "CapnpText",
        .data => "CapnpData",
        .any_pointer => "CapnpAnyPointer",
        .@"struct", .interface => try namedCodec(gen, context, value, depth + 1),
        .list => blk: {
            const element = try context.listElement(value);
            const element_type = element.expression.type;
            break :blk switch (element_type) {
                .bool => "CapnpList<Bool>",
                .float32 => "CapnpList<Float>",
                .float64 => "CapnpList<Double>",
                .int8 => "CapnpList<Int8>",
                .int16 => "CapnpList<Int16>",
                .int32 => "CapnpList<Int32>",
                .int64 => "CapnpList<Int64>",
                .uint8 => "CapnpList<UInt8>",
                .uint16 => "CapnpList<UInt16>",
                .@"enum" => |e| try std.fmt.allocPrint(gen.scratch(), "CapnpList<CapnpEnum<{s}>>", .{try namespaceReference(gen, gen.getNode(e.type_id) orelse return error.MissingEnumNode)}),
                .uint32 => "CapnpList<UInt32>",
                .uint64 => "CapnpList<UInt64>",
                .@"struct" => try std.fmt.allocPrint(gen.scratch(), "CapnpList<{s}>", .{try codec(gen, context, element, depth + 1)}),
                .text, .data, .interface, .any_pointer, .list => try std.fmt.allocPrint(gen.scratch(), "CapnpList<{s}>", .{try codec(gen, context, element, depth + 1)}),
                .void => "CapnpList<CapnpVoid>",
            };
        },
        else => error.InvalidGenericArgument,
    };
}

pub fn namedCodec(gen: *Generator, context: *const resolver.Context, value: resolver.Type, depth: usize) anyerror![]const u8 {
    const id = switch (value.expression.type) {
        .@"struct" => |n| n.type_id,
        .interface => |n| n.type_id,
        else => return error.InvalidSchema,
    };
    const target = gen.getNode(id) orelse return error.MissingNode;
    const entered = try context.enter(value);
    var chain: [resolver.max_depth]*schema.Node = undefined;
    var count: usize = 0;
    var scope = target;
    while (scope.kind != .file) {
        if (count == chain.len) return error.ScopeTooDeep;
        chain[count] = scope;
        count += 1;
        if (scope.scope_id == 0) return error.UnsupportedAnonymousReference;
        scope = gen.getNode(scope.scope_id) orelse return error.MissingNode;
    }
    if (count == 0) return error.InvalidSchema;
    // swiftRef supplies collision renames and records cross-module imports.
    const outer_reference = try namespaceReference(gen, chain[count - 1]);
    var result: std.Io.Writer.Allocating = .init(gen.scratch());
    for (0..count) |position| {
        const declaration = chain[count - 1 - position];
        if (position == 0) {
            try result.writer.print("{s}.Typed", .{outer_reference});
        } else {
            try result.writer.print(".{s}", .{try declarationName(gen, declaration)});
        }
        if (declaration.parameters.len != 0) {
            try result.writer.writeByte('<');
            for (declaration.parameters, 0..) |_, i| {
                if (i != 0) try result.writer.writeAll(", ");
                const expression = schema.TypeExpression{ .type = .any_pointer, .metadata = .{ .any_pointer = .{ .parameter = .{ .scope_id = declaration.id, .parameter_index = @intCast(i) } } } };
                try result.writer.writeAll(try codec(gen, &entered, try entered.resolve(expression), depth + 1));
            }
            try result.writer.writeByte('>');
        }
    }
    return result.written();
}

pub fn namespaceReference(gen: *Generator, node: *schema.Node) anyerror![]const u8 {
    const parent = gen.getNode(node.scope_id) orelse return gen.swiftQualifiedTypeName(node);
    if (parent.kind != .file) return erasedReference(gen, node);
    // Discover imports through the legacy resolver, then replace the root
    // declaration's spelling with its always-present, immutable node alias.
    const erased = try gen.swiftQualifiedTypeName(node);
    const start = if (std.mem.lastIndexOfScalar(u8, node.display_name, ':')) |colon| colon + 1 else 0;
    const raw_name = try gen.swiftIdentifierAlloc(node.display_name[start..]);
    const alias = try std.fmt.allocPrint(gen.scratch(), "{s}_Node{x}", .{ gen.unescaped(raw_name), node.id });
    if (std.mem.lastIndexOfScalar(u8, erased, '.')) |dot| return std.fmt.allocPrint(gen.scratch(), "{s}.{s}", .{ erased[0..dot], alias });
    return alias;
}

pub fn erasedReference(gen: *Generator, node: *schema.Node) ![]const u8 {
    var chain: [resolver.max_depth]*schema.Node = undefined;
    var count: usize = 0;
    var scope = node;
    while (scope.kind != .file) {
        if (count == chain.len) return error.ScopeTooDeep;
        chain[count] = scope;
        count += 1;
        if (scope.scope_id == 0) return gen.swiftQualifiedTypeName(node);
        scope = gen.getNode(scope.scope_id) orelse return error.MissingNode;
    }
    if (count == 0) return error.InvalidSchema;
    var result: std.Io.Writer.Allocating = .init(gen.scratch());
    try result.writer.writeAll(try namespaceReference(gen, chain[count - 1]));
    var index = count - 1;
    while (index > 0) {
        index -= 1;
        try result.writer.print(".{s}", .{gen.swiftTypeName(chain[index])});
    }
    return result.written();
}

fn emitStruct(gen: *Generator, w: *std.Io.Writer, node: *schema.Node, context: *const resolver.Context, indent: usize) !void {
    const s = node.struct_node.?;
    const pad = padding(indent);
    if (s.discriminant_count != 0) try gen.emitWhichEnum(w, &s, indent);
    try w.print("{s}public static var dataWords: UInt16 {{ {d} }}\n{s}public static var pointerWords: UInt16 {{ {d} }}\n", .{ pad, s.data_word_count, pad, s.pointer_count });
    try w.print("{s}public static func read(from pointer: PointerReader) throws -> Reader {{\n{s}    Reader(try pointer.readStruct(), pointer: pointer)\n{s}}}\n", .{ pad, pad, pad });
    try w.print("{s}public static func write(_ value: Value, to pointer: PointerBuilder) throws {{ try CapnpAnyPointer.write(value.pointer, to: pointer) }}\n", .{pad});
    try w.print("{s}public static func initialize(at pointer: PointerBuilder) -> Builder {{\n{s}    Builder(pointer.initializeStruct(dataWords: dataWords, pointerWords: pointerWords), pointer: pointer)\n{s}}}\n", .{ pad, pad, pad });
    try w.print("{s}public static func initRoot(_ message: MessageBuilder) -> Builder {{ initialize(at: PointerBuilder(message: message)) }}\n", .{pad});
    try w.print("{s}public struct Value: Sendable {{\n{s}    public let pointer: PointerReader\n{s}    public init(_ build: (Builder) throws -> Void = {{ _ in }}) throws {{\n{s}        let pointer = PointerBuilder(message: MessageBuilder())\n{s}        try build(initialize(at: pointer))\n{s}        self.pointer = try pointer.freeze()\n{s}    }}\n{s}    public init(copying reader: Reader) throws {{\n{s}        let pointer = PointerBuilder(message: MessageBuilder())\n{s}        try CapnpAnyPointer.write(reader.pointer, to: pointer)\n{s}        self.pointer = try pointer.freeze()\n{s}    }}\n{s}}}\n", .{ pad, pad, pad, pad, pad, pad, pad, pad, pad, pad, pad, pad, pad });
    try w.print("{s}public struct Reader: Sendable {{\n{s}    private let root: StructReader\n{s}    public let pointer: PointerReader\n{s}    fileprivate init(_ root: StructReader, pointer: PointerReader) {{ self.root = root; self.pointer = pointer }}\n", .{ pad, pad, pad, pad });
    if (s.discriminant_count != 0) try w.print("{s}    public var which: Which {{ Which(discriminant: root.readUInt16(at: {d})) }}\n", .{ pad, s.discriminant_offset * 2 });
    if (!s.is_group and node.scope_id != 0) try w.print("{s}    public var erased: {s}.Reader {{ {s}.Reader(root) }}\n", .{ pad, gen.swiftRef(node), gen.swiftRef(node) });
    for (s.fields, 0..) |field, i| try emitReaderField(gen, w, node, context, field, i, indent + 1);
    try w.print("{s}}}\n{s}public struct Builder {{\n{s}    private let root: StructBuilder\n{s}    public let pointer: PointerBuilder\n{s}    fileprivate init(_ root: StructBuilder, pointer: PointerBuilder) {{ self.root = root; self.pointer = pointer }}\n", .{ pad, pad, pad, pad, pad });
    if (s.discriminant_count != 0) try w.print("{s}    public var which: Which {{ Which(discriminant: root.readUInt16(at: {d})) }}\n", .{ pad, s.discriminant_offset * 2 });
    for (s.fields, 0..) |field, i| try emitBuilderField(gen, w, node, context, field, i, indent + 1);
    try w.print("{s}}}\n", .{pad});
    try rpc.emitStructPipeline(gen, w, node, context, indent);
}

fn renamedField(gen: *Generator, field: schema.Field) !schema.Field {
    var result = field;
    if (std.mem.eql(u8, field.name, "pointer") or std.mem.eql(u8, field.name, "root") or std.mem.eql(u8, field.name, "erased")) result.name = try std.fmt.allocPrint(gen.scratch(), "{s}_", .{field.name});
    return result;
}

pub fn accessorName(gen: *Generator, node: *schema.Node, field: schema.Field) ![]const u8 {
    return gen.fieldAccessorName(node, try renamedField(gen, field));
}

fn scalarOrPrimitiveList(t: schema.Type) bool {
    return switch (t) {
        .@"struct", .interface, .any_pointer => false,
        .list => false,
        else => true,
    };
}

fn defaultMessageLiteral(gen: *Generator, segment: []const u8) ![]const u8 {
    return gen.swiftByteArrayLiteral(try gen.framedPointerDefault(segment));
}

fn emitReaderField(gen: *Generator, w: *std.Io.Writer, node: *schema.Node, context: *const resolver.Context, field: schema.Field, ordinal: usize, indent: usize) !void {
    const pad = padding(indent);
    _ = ordinal;
    const name = try accessorName(gen, node, field);
    if (field.group != null) {
        const group = try groupDeclarationName(gen, field);
        try w.print("{s}public var {s}: {s}.Reader {{ {s}.Reader(root, pointer: pointer) }}\n", .{ pad, name, group, group });
        return;
    }
    const slot = field.slot orelse return;
    const expression = schema.TypeExpression{ .type = slot.type, .metadata = slot.type_metadata };
    try context.validate(expression);
    const value = try context.resolve(expression);
    if (scalarOrPrimitiveList(value.expression.type)) return gen.emitFieldReader(w, node, try renamedField(gen, field), indent);
    const type_name = try codec(gen, context, value, 0);
    try w.print("{s}public func {s}() throws -> {s}.Reader {{\n", .{ pad, name, type_name });
    if (slot.default_value) |dv| if (dv == .@"struct" and dv.@"struct".message_bytes.len > 0) {
        try w.print("{s}    if root.isPointerNull({d}) {{ return try {s}.read(from: Message(bytes: {s}).rootPointer()) }}\n", .{ pad, slot.offset, type_name, try defaultMessageLiteral(gen, dv.@"struct".message_bytes) });
    };
    if (slot.default_value) |dv| if (dv == .list and dv.list.message_bytes.len > 0) {
        try w.print("{s}    if root.isPointerNull({d}) {{ return try {s}.read(from: Message(bytes: {s}).rootPointer()) }}\n", .{ pad, slot.offset, type_name, try defaultMessageLiteral(gen, dv.list.message_bytes) });
    };
    try w.print("{s}    return try {s}.read(from: pointer.field(root, index: {d}))\n{s}}}\n", .{ pad, type_name, slot.offset, pad });
}

fn unionSelect(w: *std.Io.Writer, node: *schema.Node, field: schema.Field, pad: []const u8) !void {
    if (field.discriminant_value != 0xffff) try w.print("{s}root.setUInt16(at: {d}, {d})\n", .{ pad, node.struct_node.?.discriminant_offset * 2, field.discriminant_value });
}

fn emitLegacyBuilder(gen: *Generator, w: *std.Io.Writer, node: *schema.Node, field: schema.Field, indent: usize) !void {
    const slot = field.slot orelse return;
    var emitted: std.Io.Writer.Allocating = .init(gen.scratch());
    try gen.emitFieldBuilder(&emitted.writer, node, try renamedField(gen, field), indent, false);
    var text = emitted.written();
    if (field.discriminant_value != 0xffff and slot.type != .void and slot.type != .text and slot.type != .data) {
        const selection = try std.fmt.allocPrint(gen.scratch(), "root.setUInt16(at: {d}, {d}); ", .{ node.struct_node.?.discriminant_offset * 2, field.discriminant_value });
        const needle = if (slot.type == .list) "{ root." else "set { root.";
        const replacement = if (slot.type == .list) try std.fmt.allocPrint(gen.scratch(), "{{ {s}return root.", .{selection}) else try std.fmt.allocPrint(gen.scratch(), "set {{ {s}root.", .{selection});
        const start = std.mem.indexOf(u8, text, needle) orelse return error.UnsupportedUnionSetter;
        text = try std.fmt.allocPrint(gen.scratch(), "{s}{s}{s}", .{ text[0..start], replacement, text[start + needle.len ..] });
    }
    // The wrappers mutate shared message storage rather than replacing themselves.
    const needle = "    set {";
    if (std.mem.indexOf(u8, text, needle)) |start| {
        try w.writeAll(text[0..start]);
        try w.writeAll("    nonmutating set {");
        try w.writeAll(text[start + needle.len ..]);
    } else try w.writeAll(text);
}

fn emitBuilderField(gen: *Generator, w: *std.Io.Writer, node: *schema.Node, context: *const resolver.Context, field: schema.Field, ordinal: usize, indent: usize) !void {
    const pad = padding(indent);
    const name = try accessorName(gen, node, field);
    if (field.group != null) {
        const group = try groupDeclarationName(gen, field);
        try w.print("{s}public var {s}: {s}.Builder {{ {s}.Builder(root, pointer: pointer) }}\n", .{ pad, name, group, group });
        return;
    }
    const slot = field.slot orelse return;
    const value = try context.resolve(.{ .type = slot.type, .metadata = slot.type_metadata });
    if (scalarOrPrimitiveList(value.expression.type)) {
        if (value.expression.type == .@"enum") {
            const enum_node = gen.getNode(value.expression.type.@"enum".type_id) orelse return error.MissingEnumNode;
            const enum_name = gen.swiftRef(enum_node);
            const default: u16 = if (slot.default_value) |dv| if (dv == .@"enum") dv.@"enum" else 0 else 0;
            try w.print("{s}public var {s}: {s} {{\n{s}    get {{ {s}(rawValue: root.readUInt16(at: {d}) ^ {d}) }}\n{s}    nonmutating set {{\n", .{ pad, name, enum_name, pad, enum_name, slot.offset * 2, default, pad });
            try unionSelect(w, node, field, padding(indent + 2));
            try w.print("{s}        root.setEnum16(at: {d}, newValue.rawValue ^ {d})\n{s}    }}\n{s}}}\n", .{ pad, slot.offset * 2, default, pad, pad });
            return;
        }
        return emitLegacyBuilder(gen, w, node, field, indent);
    }
    const cap = try gen.capitalized(name);
    if (value.expression.type == .list) {
        const element = try context.listElement(value);
        if (element.expression.type == .@"struct") {
            const element_codec = try codec(gen, context, element, 0);
            try w.print("{s}public struct List{d} {{\n{s}    private let raw: StructListBuilder\n{s}    private let owner: PointerBuilder\n{s}    fileprivate init(_ raw: StructListBuilder, owner: PointerBuilder) {{ self.raw = raw; self.owner = owner }}\n{s}    public var count: Int {{ raw.count }}\n{s}    public subscript(index: Int) -> {s}.Builder {{ {s}.initialize(at: owner.element(raw[index])) }}\n{s}}}\n{s}public func init{s}(_ count: Int) -> List{d} {{\n", .{ pad, ordinal, pad, pad, pad, pad, pad, element_codec, element_codec, pad, pad, cap, ordinal });
            try unionSelect(w, node, field, padding(indent + 1));
            try w.print("{s}    return List{d}(root.initStructList({d}, dataWords: {s}.dataWords, pointerWords: {s}.pointerWords, count: count), owner: pointer)\n{s}}}\n", .{ pad, ordinal, slot.offset, element_codec, element_codec, pad });
        } else if (element.expression.type == .void) {
            try w.print("{s}public func init{s}(_ count: Int) throws {{\n", .{ pad, cap });
            try unionSelect(w, node, field, padding(indent + 1));
            try w.print("{s}    try pointer.field(root, index: {d}).setVoidList(count: count)\n{s}}}\n", .{ pad, slot.offset, pad });
        } else {
            try emitLegacyBuilder(gen, w, node, field, indent);
        }
    }
    const type_name = try codec(gen, context, value, 0);
    try w.print("{s}public func set{s}(_ value: {s}.Value) throws {{\n", .{ pad, cap, type_name });
    try unionSelect(w, node, field, padding(indent + 1));
    try w.print("{s}    try {s}.write(value, to: pointer.field(root, index: {d}))\n{s}}}\n", .{ pad, type_name, slot.offset, pad });
    if (value.expression.type == .@"struct") {
        try w.print("{s}public func init{s}() -> {s}.Builder {{\n", .{ pad, cap, type_name });
        try unionSelect(w, node, field, padding(indent + 1));
        try w.print("{s}    return {s}.initialize(at: pointer.field(root, index: {d}))\n{s}}}\n", .{ pad, type_name, slot.offset, pad });
    } else if (value.unbound) {
        try w.print("{s}public func init{s}() -> {s}.Builder where {s}: CapnpStructSchema {{\n", .{ pad, cap, type_name, type_name });
        try unionSelect(w, node, field, padding(indent + 1));
        try w.print("{s}    return {s}.initialize(at: pointer.field(root, index: {d}))\n{s}}}\n", .{ pad, type_name, slot.offset, pad });
    }
}
