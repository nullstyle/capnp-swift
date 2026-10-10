//! Consumer-side probes through capnp.type_resolver's public facade only.
//! The parsed request must outlive every Context and resolved Type.
const std = @import("std");
const capnp = @import("capnp");
const schema = capnp.schema;
const resolver = capnp.type_resolver;
const allocator = std.testing.allocator;

const Fixture = struct {
    bytes: []u8,
    request: schema.CodeGeneratorRequest,

    fn load(comptime name: []const u8) !Fixture {
        return loadFrom(@import("fixtures").root, name);
    }

    fn loadFrom(comptime directory: []const u8, comptime name: []const u8) !Fixture {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, directory ++ "/" ++ name ++ ".request.bin", allocator, .limited(64 * 1024 * 1024));
        errdefer allocator.free(bytes);
        return .{ .bytes = bytes, .request = try capnp.request.parseCodeGeneratorRequest(allocator, bytes) };
    }

    fn deinit(self: Fixture) void {
        capnp.request.freeCodeGeneratorRequest(allocator, self.request);
        allocator.free(self.bytes);
    }

    fn node(self: *const Fixture, suffix: []const u8) !*const schema.Node {
        for (self.request.nodes) |*n| {
            if (std.mem.endsWith(u8, n.display_name, suffix)) return n;
        }
        return error.MissingNode;
    }

    fn nodeId(self: *const Fixture, id: schema.Id) !*const schema.Node {
        for (self.request.nodes) |*n| if (n.id == id) return n;
        return error.MissingNode;
    }
};

fn slot(node: *const schema.Node, name: []const u8) !schema.FieldSlot {
    for ((node.struct_node orelse return error.NotStruct).fields) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition.slot orelse error.NotSlot;
    }
    return error.MissingField;
}

fn field(context: *const resolver.Context, node: *const schema.Node, name: []const u8) !resolver.Type {
    const value = try slot(node, name);
    const expression = schema.TypeExpression{ .type = value.type, .metadata = value.type_metadata };
    try context.validate(expression);
    return context.resolve(expression);
}

fn expectTag(comptime tag: std.meta.Tag(schema.Type), value: resolver.Type) !void {
    try std.testing.expectEqual(tag, std.meta.activeTag(value.expression.type));
    try std.testing.expect(!value.unbound);
}

fn superclass(context: *const resolver.Context, node: *const schema.Node, index: usize) !resolver.Context {
    const interface = node.interface_node orelse return error.NotInterface;
    const expression = schema.TypeExpression{
        .type = .{ .interface = .{ .type_id = interface.superclasses[index] } },
        .metadata = .{ .named = interface.superclass_brands[index] },
    };
    try context.validate(expression);
    return context.enter(try context.resolve(expression));
}

fn methodStruct(context: *const resolver.Context, id: schema.Id, brand: schema.Brand) !resolver.Context {
    const expression = schema.TypeExpression{ .type = .{ .@"struct" = .{ .type_id = id } }, .metadata = .{ .named = brand } };
    try context.validate(expression);
    return context.enter(try context.resolve(expression));
}

test "list application and unbound declaration preserve different views" {
    var f = try Fixture.load("generic_collections");
    defer f.deinit();
    const root = try f.node(":Root");
    const box = try f.node(":Box");
    const context = try resolver.Context.init(f.request.nodes, root, .{});
    const element = try context.listElement(try field(&context, root, "boxes"));
    const box_context = try context.enter(element);
    try expectTag(.text, try field(&box_context, box, "value"));
    const declaration = try resolver.Context.init(f.request.nodes, box, .{});
    const unbound = try field(&declaration, box, "value");
    try std.testing.expect(unbound.unbound);
    try std.testing.expectEqual(box.id, unbound.parameter().?.scope_id);
    try std.testing.expectEqual(@as(u16, 0), unbound.parameter().?.parameter_index);
}

test "recursive next and list elements retain the Text binding" {
    var f = try Fixture.load("generic_recursive");
    defer f.deinit();
    const root = try f.node(":Root");
    const link = try f.node(":Link");
    const context = try resolver.Context.init(f.request.nodes, root, .{});
    const head = try context.enter(try field(&context, root, "head"));
    const next = try head.enter(try field(&head, link, "next"));
    try expectTag(.text, try field(&next, link, "value"));
    const children = try next.listElement(try field(&next, link, "children"));
    const child = try next.enter(children);
    try expectTag(.text, try field(&child, link, "value"));
}

test "lexical and nested brands retain separate application contexts" {
    var f = try Fixture.load("brand_pointer_fidelity");
    defer f.deinit();
    const root = try f.node(":Fidelity");
    const inner = try f.node(":Outer.Inner");
    const box = try f.node(":Box");
    const context = try resolver.Context.init(f.request.nodes, root, .{});
    const lexical = try context.enter(try field(&context, root, "lexicalBox"));
    try expectTag(.text, try field(&lexical, inner, "outer"));
    try expectTag(.data, try field(&lexical, inner, "inner"));
    const outer_box = try context.enter(try field(&context, root, "nestedBox"));
    const inner_box = try outer_box.enter(try field(&outer_box, box, "value"));
    try expectTag(.text, try field(&inner_box, box, "value"));
}

test "list and capability bindings keep their pointer shape" {
    var f = try Fixture.load("brand_pointer_fidelity");
    defer f.deinit();
    const root = try f.node(":Fidelity");
    const box = try f.node(":Box");
    const context = try resolver.Context.init(f.request.nodes, root, .{});
    const deep = try context.enter(try field(&context, root, "deepListBox"));
    const list = try field(&deep, box, "value");
    const nested_list = try deep.listElement(list);
    try expectTag(.uint16, try deep.listElement(nested_list));
    const service = try context.enter(try field(&context, root, "serviceBox"));
    try expectTag(.interface, try field(&service, box, "value"));
    const unconstrained = try field(&context, root, "anyStruct");
    try std.testing.expect(!unconstrained.unbound);
    try std.testing.expectEqual(schema.TypeMetadata.AnyPointer.Unconstrained.@"struct", unconstrained.expression.metadata.any_pointer.unconstrained);
}

test "inherited RPC params and results substitute through anonymous method structs" {
    var f = try Fixture.load("generic_rpc");
    defer f.deinit();
    const child = try f.node(":TextChild");
    const middle = try f.node(":Middle");
    const parent = try f.node(":Parent");
    const context = try resolver.Context.init(f.request.nodes, child, .{});
    const middle_context = try superclass(&context, child, 0);
    const parent_context = try superclass(&middle_context, middle, 0);
    const method = parent.interface_node.?.methods[0];
    const params = try methodStruct(&parent_context, method.param_struct_type, method.param_brand);
    const results = try methodStruct(&parent_context, method.result_struct_type, method.result_brand);
    const params_node = try f.nodeId(method.param_struct_type);
    try std.testing.expectEqual(@as(schema.Id, 0), params_node.scope_id);
    try expectTag(.text, try field(&params, params_node, "value"));
    try expectTag(.text, try field(&results, try f.nodeId(method.result_struct_type), "value"));
}

test "method generics stay unbound for anonymous and named parameter structs" {
    var f = try Fixture.load("generic_rpc");
    defer f.deinit();
    const factory = try f.node(":Factory");
    const context = try resolver.Context.init(f.request.nodes, factory, .{});
    const method = factory.interface_node.?.methods[1];
    try std.testing.expectEqual(@as(usize, 1), method.implicit_parameters.len);
    const params = try methodStruct(&context, method.param_struct_type, method.param_brand);
    const value = try field(&params, try f.nodeId(method.param_struct_type), "value");
    try std.testing.expect(value.unbound);
    // The compiler declares T on the anonymous payload node itself.
    try std.testing.expectEqual(method.param_struct_type, value.parameter().?.scope_id);

    // Named payloads instead bind Box(T) to an implicit method parameter.
    const named = try f.node(":NamedMethods");
    const named_context = try resolver.Context.init(f.request.nodes, named, .{});
    const named_method = named.interface_node.?.methods[0];
    const named_params = try methodStruct(&named_context, named_method.param_struct_type, named_method.param_brand);
    const named_value = try field(&named_params, try f.nodeId(named_method.param_struct_type), "value");
    try std.testing.expect(named_value.unbound);
    try std.testing.expect(named_value.parameter() == null);
    try std.testing.expectEqual(@as(u16, 0), named_value.expression.metadata.any_pointer.implicit_method_parameter.parameter_index);
}

test "validate rejects a malformed named application that resolve leaves shallow" {
    var f = try Fixture.load("generic_collections");
    defer f.deinit();
    const root = try f.node(":Root");
    const box = try f.node(":Box");
    const context = try resolver.Context.init(f.request.nodes, root, .{});
    var scopes = [_]schema.Brand.Scope{.{ .scope_id = box.id, .binding = .{ .bind = &.{} } }};
    const malformed = schema.TypeExpression{ .type = .{ .@"struct" = .{ .type_id = box.id } }, .metadata = .{ .named = .{ .scopes = &scopes } } };
    try expectTag(.@"struct", try context.resolve(malformed));
    try std.testing.expectError(error.InvalidSchema, context.validate(malformed));
    try std.testing.expectError(error.InvalidSchema, context.enter(try context.resolve(malformed)));
}

fn lookup(raw: ?*anyopaque, id: schema.Id) ?*const schema.Node {
    const fixture: *const Fixture = @ptrCast(@alignCast(raw orelse return null));
    return fixture.nodeId(id) catch null;
}

test "lookup-only mode loses the outer scope of an anonymous nested RPC payload" {
    var f = try Fixture.loadFrom(@import("fixtures").local, "lexical_rpc");
    defer f.deinit();
    const root = try f.node(":Root");
    const inner = try f.node(":Outer.Inner");
    const method = inner.interface_node.?.methods[0];
    const context = try resolver.Context.init(f.request.nodes, root, .{});
    const inner_context = try context.enter(try field(&context, root, "service"));
    const params = try methodStruct(&inner_context, method.param_struct_type, method.param_brand);
    try expectTag(.text, try field(&params, try f.nodeId(method.param_struct_type), "value"));

    const indexed = try resolver.Context.initWithLookup(root, .{}, lookup, &f);
    const indexed_inner = try indexed.enter(try field(&indexed, root, "service"));
    // A plain node-ID lookup cannot recover the method owner's lexical parent.
    try std.testing.expectError(error.InvalidSchema, methodStruct(&indexed_inner, method.param_struct_type, method.param_brand));
}

test "concrete generation rejects an erased parameter" {
    var f = try Fixture.loadFrom(@import("fixtures").local, "specializations");
    defer f.deinit();
    try std.testing.expectError(error.UnboundType, @import("specialization.zig").generate(allocator, f.request.nodes, (try f.node(":UnboundRoot")).id, .{}));
}

test "concrete generation refuses an unsupported pointer shape" {
    var f = try Fixture.loadFrom(@import("fixtures").local, "specializations");
    defer f.deinit();
    try std.testing.expectError(error.UnsupportedType, @import("specialization.zig").generate(allocator, f.request.nodes, (try f.node(":UnsupportedRoot")).id, .{}));
}

test "concrete generation refuses a nonempty schema default" {
    var f = try Fixture.loadFrom(@import("fixtures").local, "specializations");
    defer f.deinit();
    try std.testing.expectError(error.UnsupportedDefault, @import("specialization.zig").generate(allocator, f.request.nodes, (try f.node(":DefaultRoot")).id, .{}));
}

test "expanding applications stop at the consumer budget" {
    var f = try Fixture.loadFrom(@import("fixtures").local, "specializations");
    defer f.deinit();
    try std.testing.expectError(error.ApplicationLimit, @import("specialization.zig").generate(allocator, f.request.nodes, (try f.node(":ExpandingRoot")).id, .{ .max_applications = 8 }));
}
