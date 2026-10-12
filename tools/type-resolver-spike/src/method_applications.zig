//! Explicit, closed call-site bindings. No wire type inference or resolver internals.
const std = @import("std");
const capnp = @import("capnp");
const schema = capnp.schema;
const resolver = capnp.type_resolver;

pub const Case = struct { name: []const u8, arguments: []const schema.TypeExpression };
pub const Profile = struct { interface_id: schema.Id, ordinal: u16, cases: []const Case };
pub const Environment = struct {
    interface_id: schema.Id,
    ordinal: u16,
    method: schema.Method,
    param_scope: ?schema.Id,
    result_scope: ?schema.Id,

    pub fn init(nodes: []const schema.Node, interface_id: schema.Id, ordinal: u16, method: schema.Method) !Environment {
        const params = try node(nodes, method.param_struct_type);
        const results = try node(nodes, method.result_struct_type);
        return .{ .interface_id = interface_id, .ordinal = ordinal, .method = method, .param_scope = if (params.scope_id == 0) params.id else null, .result_scope = if (results.scope_id == 0) results.id else null };
    }

    /// Anonymous payloads declare scoped parameters; named payloads refer to
    /// implicit method parameters. Both denote the same method argument index.
    pub fn parameter(self: Environment, value: resolver.Type) !?u16 {
        if (!value.unbound or value.expression.metadata != .any_pointer) return null;
        const index = switch (value.expression.metadata.any_pointer) {
            .implicit_method_parameter => |p| p.parameter_index,
            .parameter => |p| if (p.scope_id == self.param_scope or p.scope_id == self.result_scope) p.parameter_index else return null,
            else => return null,
        };
        if (index >= self.method.implicit_parameters.len) return error.InvalidMethodApplication;
        return index;
    }
};

/// JSON arguments name fields of the selected root. Materialize each argument
/// into a closed expression via the public facade before using it in another
/// Context, so inherited brands cannot borrow the root's caller frames.
pub fn parse(allocator: std.mem.Allocator, nodes: []const schema.Node, root_id: schema.Id, json: []const u8) ![]const Profile {
    const InputCase = struct { name: []const u8, arguments: []const []const u8 };
    const Input = struct { interface: []const u8, method: []const u8, cases: []const InputCase };
    const parsed = try std.json.parseFromSlice([]const Input, allocator, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const root = try node(nodes, root_id);
    const context = try resolver.Context.init(nodes, root, .{});
    var profiles: std.ArrayList(Profile) = .empty;
    var total: usize = 0;
    for (parsed.value) |input| {
        var iface: ?*const schema.Node = null;
        for (nodes) |*candidate| if (std.mem.endsWith(u8, candidate.display_name, input.interface)) {
            if (iface != null) return error.InvalidMethodApplication;
            iface = candidate;
        };
        const owner = iface orelse return error.InvalidMethodApplication;
        const definition = owner.interface_node orelse return error.InvalidMethodApplication;
        var ordinal: ?u16 = null;
        for (definition.methods, 0..) |method, index| if (std.mem.eql(u8, method.name, input.method)) {
            if (index > std.math.maxInt(u16)) return error.InvalidMethodApplication;
            ordinal = @intCast(index);
        };
        const method_id = ordinal orelse return error.InvalidMethodApplication;
        const method = definition.methods[method_id];
        if (method.implicit_parameters.len == 0 or input.cases.len == 0) return error.InvalidMethodApplication;
        for (profiles.items) |profile| if (profile.interface_id == owner.id and profile.ordinal == method_id) return error.InvalidMethodApplication;
        var cases: std.ArrayList(Case) = .empty;
        for (input.cases) |call_case| {
            total += 1;
            if (total > 64) return error.MethodApplicationLimit;
            try checkLabel(call_case.name);
            for (cases.items) |existing| if (std.mem.eql(u8, existing.name, call_case.name)) return error.InvalidMethodApplication;
            if (call_case.arguments.len != method.implicit_parameters.len) return error.InvalidMethodApplication;
            var arguments: std.ArrayList(schema.TypeExpression) = .empty;
            for (call_case.arguments) |field_name| {
                var expression: ?schema.TypeExpression = null;
                for ((root.struct_node orelse return error.InvalidMethodApplication).fields) |field| {
                    if (!std.mem.eql(u8, field.name, field_name)) continue;
                    const slot = field.slot orelse return error.InvalidMethodApplication;
                    expression = .{ .type = slot.type, .metadata = slot.type_metadata };
                }
                const argument = expression orelse return error.InvalidMethodApplication;
                try context.validate(argument);
                try arguments.append(allocator, try close(allocator, nodes, &context, try context.resolve(argument), 0));
            }
            try cases.append(allocator, .{ .name = try allocator.dupe(u8, call_case.name), .arguments = try arguments.toOwnedSlice(allocator) });
        }
        try profiles.append(allocator, .{ .interface_id = owner.id, .ordinal = method_id, .cases = try cases.toOwnedSlice(allocator) });
    }
    return profiles.toOwnedSlice(allocator);
}

fn close(allocator: std.mem.Allocator, nodes: []const schema.Node, context: *const resolver.Context, value: resolver.Type, depth: usize) anyerror!schema.TypeExpression {
    if (depth >= resolver.max_depth or value.unbound) return error.InvalidMethodApplication;
    var result = value.expression;
    switch (result.type) {
        .text, .data => {},
        .list => {
            const element = try close(allocator, nodes, context, try context.listElement(value), depth + 1);
            const t = try allocator.create(schema.Type);
            t.* = element.type;
            const metadata = try allocator.create(schema.TypeMetadata);
            metadata.* = element.metadata;
            result = .{ .type = .{ .list = .{ .element_type = t } }, .metadata = .{ .list = metadata } };
        },
        inline .@"struct", .interface => |named| {
            const entered = try context.enter(value);
            var scope = try node(nodes, named.type_id);
            var scopes: std.ArrayList(schema.Brand.Scope) = .empty;
            var count: usize = 0;
            while (true) : (count += 1) {
                if (count >= resolver.max_depth) return error.InvalidMethodApplication;
                if (scope.parameters.len > 0) {
                    var bindings: std.ArrayList(schema.Brand.Binding) = .empty;
                    for (scope.parameters, 0..) |_, index| {
                        const parameter = schema.TypeExpression{ .type = .any_pointer, .metadata = .{ .any_pointer = .{ .parameter = .{ .scope_id = scope.id, .parameter_index = @intCast(index) } } } };
                        const closed = try allocator.create(schema.TypeExpression);
                        closed.* = try close(allocator, nodes, &entered, try entered.resolve(parameter), depth + 1);
                        try bindings.append(allocator, .{ .type = closed });
                    }
                    try scopes.append(allocator, .{ .scope_id = scope.id, .binding = .{ .bind = try bindings.toOwnedSlice(allocator) } });
                }
                if (scope.scope_id == 0) break;
                scope = try node(nodes, scope.scope_id);
            }
            result.metadata = .{ .named = .{ .scopes = try scopes.toOwnedSlice(allocator) } };
        },
        // Integer list elements are legal; scalar method arguments are not.
        .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => if (depth == 0) return error.InvalidMethodApplication,
        else => return error.InvalidMethodApplication,
    }
    return result;
}

/// Bind an anonymous payload's declared parameters and substitute implicit
/// references in a named payload brand. The parsed schema is never mutated.
pub fn payloadBrand(allocator: std.mem.Allocator, payload: *const schema.Node, brand: schema.Brand, arguments: []const schema.TypeExpression) !schema.Brand {
    const rewritten = try rewriteBrand(allocator, brand, arguments, 0);
    if (payload.scope_id != 0 or payload.parameters.len == 0) return rewritten;
    if (payload.parameters.len != arguments.len) return error.InvalidMethodApplication;
    var scopes: std.ArrayList(schema.Brand.Scope) = .empty;
    for (rewritten.scopes) |scope| if (scope.scope_id != payload.id) try scopes.append(allocator, scope);
    const bindings = try allocator.alloc(schema.Brand.Binding, arguments.len);
    for (arguments, bindings) |argument, *binding| {
        const expression = try allocator.create(schema.TypeExpression);
        expression.* = argument;
        binding.* = .{ .type = expression };
    }
    try scopes.append(allocator, .{ .scope_id = payload.id, .binding = .{ .bind = bindings } });
    return .{ .scopes = try scopes.toOwnedSlice(allocator) };
}

fn rewriteBrand(allocator: std.mem.Allocator, brand: schema.Brand, arguments: []const schema.TypeExpression, depth: usize) anyerror!schema.Brand {
    if (depth >= resolver.max_depth) return error.InvalidMethodApplication;
    const scopes = try allocator.dupe(schema.Brand.Scope, brand.scopes);
    for (scopes) |*scope| if (scope.binding == .bind) {
        const bindings = try allocator.dupe(schema.Brand.Binding, scope.binding.bind);
        for (bindings) |*binding| if (binding.* == .type) {
            const expression = try allocator.create(schema.TypeExpression);
            expression.* = try rewrite(allocator, binding.type.*, arguments, depth + 1);
            binding.* = .{ .type = expression };
        };
        scope.binding = .{ .bind = bindings };
    };
    return .{ .scopes = scopes };
}

fn rewrite(allocator: std.mem.Allocator, expression: schema.TypeExpression, arguments: []const schema.TypeExpression, depth: usize) anyerror!schema.TypeExpression {
    if (depth >= resolver.max_depth) return error.InvalidMethodApplication;
    if (expression.metadata == .any_pointer and expression.metadata.any_pointer == .implicit_method_parameter) {
        const index = expression.metadata.any_pointer.implicit_method_parameter.parameter_index;
        if (index >= arguments.len) return error.InvalidMethodApplication;
        return arguments[index];
    }
    var result = expression;
    switch (expression.metadata) {
        .named => |brand| result.metadata = .{ .named = try rewriteBrand(allocator, brand, arguments, depth + 1) },
        .list => |metadata| {
            if (expression.type != .list) return error.InvalidMethodApplication;
            const element = try rewrite(allocator, .{ .type = expression.type.list.element_type.*, .metadata = metadata.* }, arguments, depth + 1);
            const t = try allocator.create(schema.Type);
            t.* = element.type;
            const m = try allocator.create(schema.TypeMetadata);
            m.* = element.metadata;
            result = .{ .type = .{ .list = .{ .element_type = t } }, .metadata = .{ .list = m } };
        },
        else => {},
    }
    return result;
}

fn node(nodes: []const schema.Node, id: schema.Id) !*const schema.Node {
    for (nodes) |*n| if (n.id == id) return n;
    return error.InvalidMethodApplication;
}

fn checkLabel(name: []const u8) !void {
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return error.InvalidMethodApplication;
    for (name) |c| if (!std.ascii.isAlphanumeric(c)) return error.InvalidMethodApplication;
}
