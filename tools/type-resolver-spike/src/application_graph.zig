//! Finite concrete applications, with public-resolver contexts kept private.
const std = @import("std");
const capnp = @import("capnp");
const schema = capnp.schema;
const resolver = capnp.type_resolver;

pub const Limits = struct { max_applications: usize = 256 };
pub const Shape = union(enum) { text, data, structure: usize, integers: []const u8, structures: usize, capability: usize };
pub const Field = struct { name: []const u8, offset: u32, shape: Shape };
pub const Method = struct { name: []const u8, ordinal: u16, params: usize, results: usize };
pub const Application = struct {
    key: []const u8,
    node: *const schema.Node,
    fields: []const Field = &.{},
    parents: []const usize = &.{},
    methods: []const Method = &.{},
    closure: []const usize = &.{},
};

/// All returned storage uses allocator; nodes remain borrowed. Caller uses an
/// arena so partially built graphs and temporary keys share one cleanup point.
pub fn build(allocator: std.mem.Allocator, nodes: []const schema.Node, root_id: schema.Id, limits: Limits) ![]const Application {
    var graph = Graph{ .allocator = allocator, .nodes = nodes, .limits = limits };
    const root = try graph.node(root_id);
    const context = try resolver.Context.init(nodes, root, .{});
    const expression = schema.TypeExpression{ .type = switch (root.kind) {
        .@"struct" => .{ .@"struct" = .{ .type_id = root_id } },
        .interface => .{ .interface = .{ .type_id = root_id } },
        else => return error.UnsupportedType,
    } };
    try context.validate(expression);
    _ = try graph.register(&context, try context.resolve(expression), &.{});
    for (0..graph.applications.items.len) |index| {
        if (graph.applications.items[index].node.kind == .interface) {
            graph.applications.items[index].closure = try graph.interfaceClosure(index);
        }
    }
    return graph.applications.items;
}

const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: []const schema.Node,
    limits: Limits,
    applications: std.ArrayList(Application) = .empty,

    fn node(self: *const Graph, id: schema.Id) !*const schema.Node {
        for (self.nodes) |*n| if (n.id == id) return n;
        return error.MissingNode;
    }

    fn logicalParent(self: *const Graph, n: *const schema.Node) !?*const schema.Node {
        if (n.scope_id != 0) return try self.node(n.scope_id);
        // Anonymous method payloads have zero wire scope, but their owning
        // interface's parameters participate in their application identity.
        if (n.kind == .@"struct") for (self.nodes) |*candidate| {
            const iface = candidate.interface_node orelse continue;
            for (iface.methods) |method| {
                if (method.param_struct_type == n.id or method.result_struct_type == n.id) return candidate;
            }
        };
        return null;
    }

    fn register(self: *Graph, parent: *const resolver.Context, value: resolver.Type, inheritance_path: []const schema.Id) anyerror!usize {
        const id = switch (value.expression.type) {
            .@"struct" => |s| s.type_id,
            .interface => |s| s.type_id,
            else => return error.UnsupportedType,
        };
        if (inheritance_path.len >= resolver.max_depth) return error.InheritanceCycle;
        for (inheritance_path) |ancestor| if (ancestor == id) return error.InheritanceCycle;
        var key: std.Io.Writer.Allocating = .init(self.allocator);
        try self.appendKey(&key.writer, parent, value, 0);
        for (self.applications.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing.key, key.written())) return index;
        }
        if (self.applications.items.len >= self.limits.max_applications) return error.ApplicationLimit;
        const n = try self.node(id);
        const context = try parent.enter(value);
        const index = self.applications.items.len;
        try self.applications.append(self.allocator, .{ .key = key.written(), .node = n });
        if (n.interface_node) |iface| {
            var path: [resolver.max_depth]schema.Id = undefined;
            @memcpy(path[0..inheritance_path.len], inheritance_path);
            path[inheritance_path.len] = id;
            var parents: std.ArrayList(usize) = .empty;
            for (iface.superclasses, 0..) |super_id, ordinal| {
                const expression = schema.TypeExpression{ .type = .{ .interface = .{ .type_id = super_id } }, .metadata = .{ .named = if (ordinal < iface.superclass_brands.len) iface.superclass_brands[ordinal] else .{} } };
                try context.validate(expression);
                try parents.append(self.allocator, try self.register(&context, try context.resolve(expression), path[0 .. inheritance_path.len + 1]));
            }
            self.applications.items[index].parents = try parents.toOwnedSlice(self.allocator);
            var methods: std.ArrayList(Method) = .empty;
            for (iface.methods, 0..) |method, ordinal| {
                try checkName(method.name);
                if (method.implicit_parameters.len != 0) return error.UnsupportedMethodGenerics;
                if (method.isStreaming()) return error.UnsupportedStreaming;
                try methods.append(self.allocator, .{
                    .name = method.name,
                    .ordinal = @intCast(ordinal),
                    .params = try self.methodPayload(&context, method.param_struct_type, method.param_brand),
                    .results = try self.methodPayload(&context, method.result_struct_type, method.result_brand),
                });
            }
            self.applications.items[index].methods = try methods.toOwnedSlice(self.allocator);
            return index;
        }
        const structure = n.struct_node orelse return error.UnsupportedType;
        if (structure.is_group or structure.discriminant_count != 0 or structure.data_word_count != 0) return error.UnsupportedStruct;
        var fields: std.ArrayList(Field) = .empty;
        for (structure.fields) |definition| {
            try checkName(definition.name);
            const slot = definition.slot orelse return error.UnsupportedGroup;
            if (slot.offset >= structure.pointer_count) return error.InvalidSchema;
            if (slot.default_value) |default| switch (default) {
                .text, .data => |bytes| if (bytes.len != 0) return error.UnsupportedDefault,
                .interface => {},
                else => return error.UnsupportedDefault,
            };
            const expression = schema.TypeExpression{ .type = slot.type, .metadata = slot.type_metadata };
            try context.validate(expression);
            const resolved = try context.resolve(expression);
            try fields.append(self.allocator, .{ .name = definition.name, .offset = slot.offset, .shape = try self.shape(&context, resolved) });
        }
        self.applications.items[index].fields = try fields.toOwnedSlice(self.allocator);
        return index;
    }

    fn methodPayload(self: *Graph, context: *const resolver.Context, id: schema.Id, brand: schema.Brand) !usize {
        const expression = schema.TypeExpression{ .type = .{ .@"struct" = .{ .type_id = id } }, .metadata = .{ .named = brand } };
        try context.validate(expression);
        return self.register(context, try context.resolve(expression), &.{});
    }

    fn interfaceClosure(self: *const Graph, root: usize) ![]const usize {
        var result: std.ArrayList(usize) = .empty;
        try result.append(self.allocator, root);
        var cursor: usize = 0;
        while (cursor < result.items.len) : (cursor += 1) {
            for (self.applications.items[result.items[cursor]].parents) |parent| {
                var seen = false;
                for (result.items) |existing| {
                    if (existing == parent) {
                        seen = true;
                        break;
                    }
                    if (self.applications.items[existing].node.id == self.applications.items[parent].node.id) return error.ConflictingInheritedApplication;
                }
                if (!seen) try result.append(self.allocator, parent);
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn shape(self: *Graph, context: *const resolver.Context, value: resolver.Type) anyerror!Shape {
        if (value.unbound) return error.UnboundType;
        return switch (value.expression.type) {
            .text => .text,
            .data => .data,
            .@"struct" => .{ .structure = try self.register(context, value, &.{}) },
            .interface => .{ .capability = try self.register(context, value, &.{}) },
            .list => blk: {
                const element = try context.listElement(value);
                if (element.unbound) return error.UnboundType;
                if (integerName(element.expression.type)) |name| break :blk .{ .integers = name };
                if (element.expression.type == .@"struct") break :blk .{ .structures = try self.register(context, element, &.{}) };
                return error.UnsupportedList;
            },
            else => error.UnsupportedType,
        };
    }

    fn appendKey(self: *const Graph, w: *std.Io.Writer, context: *const resolver.Context, value: resolver.Type, depth: usize) anyerror!void {
        if (depth >= resolver.max_depth) return error.TypeKeyLimit;
        if (value.unbound) return error.UnboundType;
        switch (value.expression.type) {
            .list => {
                try w.writeAll("list(");
                try self.appendKey(w, context, try context.listElement(value), depth + 1);
                try w.writeByte(')');
            },
            inline .@"struct", .interface => |named| {
                try w.print("{s}:{x}[", .{ @tagName(value.expression.type), named.type_id });
                const entered = try context.enter(value);
                var scope = try self.node(named.type_id);
                var scopes: usize = 0;
                while (true) : (scopes += 1) {
                    if (scopes >= resolver.max_depth) return error.InvalidSchema;
                    for (scope.parameters, 0..) |_, parameter_index| {
                        try w.print("{x}:{d}=", .{ scope.id, parameter_index });
                        const parameter = schema.TypeExpression{ .type = .any_pointer, .metadata = .{ .any_pointer = .{ .parameter = .{ .scope_id = scope.id, .parameter_index = @intCast(parameter_index) } } } };
                        try self.appendKey(w, &entered, try entered.resolve(parameter), depth + 1);
                        try w.writeByte(';');
                    }
                    scope = (try self.logicalParent(scope)) orelse break;
                }
                try w.writeByte(']');
            },
            .@"enum" => |named| try w.print("enum:{x}", .{named.type_id}),
            .any_pointer => return error.UnsupportedType,
            else => try w.writeAll(@tagName(value.expression.type)),
        }
        if (w.end > 16 * 1024) return error.TypeKeyLimit;
    }
};

fn integerName(value: schema.Type) ?[]const u8 {
    return switch (value) {
        .int8 => "Int8",
        .int16 => "Int16",
        .int32 => "Int32",
        .int64 => "Int64",
        .uint8 => "UInt8",
        .uint16 => "UInt16",
        .uint32 => "UInt32",
        .uint64 => "UInt64",
        else => null,
    };
}

fn checkName(name: []const u8) !void {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return error.UnsupportedFieldName;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.UnsupportedFieldName;
    const reserved = [_][]const u8{ "target", "connection", "init", "capSlots", "caps", "Reader", "Builder", "Value" };
    for (reserved) |word| if (std.mem.eql(u8, name, word)) return error.UnsupportedFieldName;
    if (std.mem.startsWith(u8, name, "super")) {
        const tail = name[5..];
        if (tail.len > 0 and std.ascii.isDigit(tail[0])) return error.UnsupportedFieldName;
    }
}
