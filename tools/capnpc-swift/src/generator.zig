//! capnpc-swift's Swift emitter.
//!
//! Input: the parsed CodeGeneratorRequest model from capnp-zig's Stable
//! `schema`/`request` modules. Output: one Swift source text per requested
//! schema file, ready for `swift build` with no post-processing (the
//! golden gate diffs it against a committed file).
//!
//! Emission rules (plan §6):
//!   - enums: RawRepresentable structs with static members; an unknown raw
//!     value stays itself (never traps)
//!   - unions: `Which` enums with `.unknownDiscriminant(UInt16)`
//!   - a wrong pointer kind reads as the field default; Text stays strict
//!   - scalar defaults apply when the struct's data section does not cover
//!     the field (schema evolution); pointer defaults when the pointer is
//!     null (embedded default message bytes)
//!   - no force unwraps in generated code (grep gate)
//!
//! v1 scope: structs (slots, groups, unions), enums, per-field list types.
//! Interfaces (Client/Server/Export), consts, `swift.capnp` annotations and
//! cross-file imports follow in M3-d/e.

const std = @import("std");
const capnp = @import("capnp");
const schema = capnp.schema;

const no_discriminant: u16 = 0xffff;

pub const Generator = struct {
    allocator: std.mem.Allocator,
    /// Names, literals and formatted snippets live here; freed wholesale.
    arena: std.heap.ArenaAllocator,
    /// Every schema node in the request, by id (the request outlives the
    /// generator; pointers into it are stable).
    node_map: std.AutoHashMapUnmanaged(schema.Id, *schema.Node) = .{},
    /// While emitting a method-params struct: add the cap setters (Builder)
    /// and Client getters (Reader).
    in_params_struct: bool = false,
    /// The file node being emitted, and every file id in the request: a
    /// reference to another requested file stays unprefixed (one module);
    /// anything else is foreign and gets its module name (plan §6).
    current_file: ?*schema.Node = null,
    requested_file_ids: std.AutoHashMapUnmanaged(schema.Id, void) = .{},
    /// Top-level names that collide across the requested files (one Swift
    /// module): the later declarations are renamed with their module stem.
    name_overrides: std.AutoHashMapUnmanaged(schema.Id, []const u8) = .{},
    /// Foreign modules referenced during emission (imports are printed for
    /// these only, not for every schema import).
    referenced_modules: std.ArrayList([]const u8) = .empty,

    pub fn setRequestedFiles(self: *Generator, allocator: std.mem.Allocator, files: []const schema.RequestedFile) !void {
        self.requested_file_ids.deinit(allocator);
        self.requested_file_ids = .{};
        self.name_overrides.deinit(allocator);
        self.name_overrides = .{};
        try self.requested_file_ids.ensureTotalCapacity(allocator, @intCast(files.len));
        for (files) |f| {
            self.requested_file_ids.put(allocator, f.id, {}) catch {};
        }
        // Two requested files may declare the same top-level name (one Swift
        // module): keep the first verbatim, rename later ones with the
        // module stem (`First` in a second file -> `First_External`).
        var seen: std.StringHashMapUnmanaged(void) = .{};
        defer seen.deinit(self.scratch());
        for (files) |f| {
            const file_node = self.getNode(f.id) orelse continue;
            for (file_node.nested_nodes) |nested| {
                const child = self.getNode(nested.id) orelse continue;
                switch (child.kind) {
                    .@"struct", .@"enum", .interface => {},
                    else => continue,
                }
                const plain = self.swiftIdentifierAlloc(lastSegment(child.display_name)) catch continue;
                if (seen.contains(plain)) {
                    const module = self.moduleName(file_node);
                    const renamed = std.fmt.allocPrint(self.scratch(), "{s}_{s}", .{ self.unescaped(plain), self.unescaped(module) }) catch continue;
                    self.name_overrides.put(allocator, child.id, renamed) catch {};
                } else {
                    seen.put(self.scratch(), plain, {}) catch {};
                }
            }
        }
    }

    /// The module a schema file's types live in: `$Swift.module` when
    /// annotated, else the file stem in PascalCase.
    fn moduleName(self: *Generator, file_node: *schema.Node) []const u8 {
        const swift_module_annotation: schema.Id = 0x87972259171bec98;
        for (file_node.annotations) |use| {
            if (use.id == swift_module_annotation) {
                switch (use.value) {
                    .text => |t| return t,
                    else => {},
                }
            }
        }
        const stem = fileStem(file_node);
        const pascal = pascalCase(self, stem) catch return "ForeignModule";
        // A valid Swift identifier: drop anything else (c++.capnp -> C).
        var buf: std.ArrayList(u8) = .empty;
        for (pascal) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') buf.append(self.scratch(), c) catch {};
        }
        if (buf.items.len == 0) return "ForeignModule";
        return buf.items;
    }

    fn fileStem(file_node: *schema.Node) []const u8 {
        var name = file_node.display_name;
        if (std.mem.lastIndexOfScalar(u8, name, ':')) |i| name = name[0..i];
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name = name[i + 1 ..];
        if (name.len >= 6 and std.mem.endsWith(u8, name, ".capnp")) {
            name = name[0 .. name.len - 6];
        }
        return name;
    }

    fn pascalCase(self: *Generator, stem: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.scratch());
        var upper_next = true;
        for (stem) |c| {
            if (c == '_' or c == '-' or c == '.') {
                upper_next = true;
            } else if (upper_next) {
                try buf.append(self.scratch(), std.ascii.toUpper(c));
                upper_next = false;
            } else {
                try buf.append(self.scratch(), c);
            }
        }
        return buf.toOwnedSlice(self.scratch());
    }

    /// Import lines for schema imports that leave the requested file set.
    fn foreignImportModules(self: *Generator, requested_file: schema.RequestedFile) []const []const u8 {
        var modules: std.ArrayList([]const u8) = .empty;
        for (requested_file.imports) |import| {
            const node = self.getNode(import.id) orelse continue;
            if (node.kind != .file) continue;
            if (self.requested_file_ids.contains(import.id)) continue;
            const module = self.moduleName(node);
            var dup = false;
            for (modules.items) |m| {
                if (std.mem.eql(u8, m, module)) dup = true;
            }
            if (!dup) modules.append(self.scratch(), module) catch {};
        }
        return modules.items;
    }

    pub fn init(allocator: std.mem.Allocator, nodes: []schema.Node) !Generator {
        var self = Generator{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
        try self.node_map.ensureTotalCapacity(allocator, @intCast(nodes.len));
        for (nodes) |*node| {
            self.node_map.put(allocator, node.id, node) catch {};
        }
        return self;
    }

    pub fn deinit(self: *Generator) void {
        self.node_map.deinit(self.allocator);
        self.requested_file_ids.deinit(self.allocator);
        self.name_overrides.deinit(self.allocator);
        self.arena.deinit();
    }

    /// The arena allocator: everything the emitters allocate.
    fn scratch(self: *Generator) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn getNode(self: *Generator, id: schema.Id) ?*schema.Node {
        return self.node_map.get(id);
    }

    /// The node for `id`'s file: the outermost enclosing scope (a node whose
    /// own scope is 0).
    pub fn getFileNode(self: *Generator, id: schema.Id) ?*schema.Node {
        var node = self.getNode(id) orelse return null;
        while (node.scope_id != 0) {
            node = self.getNode(node.scope_id) orelse return null;
        }
        return node;
    }

    pub fn generateFile(self: *Generator, requested_file: schema.RequestedFile) ![]u8 {
        self.current_file = self.getNode(requested_file.id);
        defer self.current_file = null;
        // The returned text is owned by `allocator` (the caller frees it);
        // interior scratch lives in the arena.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        const file_node = self.getNode(requested_file.id) orelse return error.MissingFileNode;
        try w.print("// Generated by capnpc-swift from {s}. DO NOT EDIT.\n\n", .{requested_file.filename});
        var has_interfaces = false;
        for (file_node.nested_nodes) |nested| {
            const node = self.getNode(nested.id) orelse continue;
            if (node.kind == .interface) has_interfaces = true;
        }
        try w.writeAll("import Capnp\n");
        if (has_interfaces) try w.writeAll("import CapnpRPC\n");
        try w.writeAll("\n");

        for (file_node.nested_nodes) |nested| {
            const node = self.getNode(nested.id) orelse continue;
            switch (node.kind) {
                .@"struct" => try self.emitStruct(w, node, 0),
                .@"enum" => try self.emitEnum(w, node, 0),
                .interface => try self.emitInterface(w, node, 0),
                .@"const", .annotation, .file => {},
            }
        }
        // Imports go on top: the emission above recorded which foreign
        // modules were actually referenced.
        const body = aw.written();
        const out = try self.allocator.alloc(u8, 256 + body.len);
        var h = std.Io.Writer.fixed(out);
        try h.print("// Generated by capnpc-swift from {s}. DO NOT EDIT.\n\n", .{requested_file.filename});
        try h.writeAll("import Capnp\n");
        if (has_interfaces) try h.writeAll("import CapnpRPC\n");
        for (self.referenced_modules.items) |module| {
            try h.print("import {s}\n", .{module});
        }
        try h.writeAll("\n");
        try h.writeAll(body);
        aw.deinit();
        const final = try self.allocator.realloc(out, h.end);
        return final;
    }

    // ------------------------------------------------ enums

    fn emitEnum(self: *Generator, w: *std.Io.Writer, node: *schema.Node, indent: usize) !void {
        const enum_node = node.enum_node orelse return;
        const name = self.swiftTypeName(node);
        const pad = indentation(indent);
        try w.print("{s}public struct {s}: Hashable, Sendable {{\n", .{ pad, name });
        try w.print("{s}    public typealias RawValue = UInt16\n", .{pad});
        try w.print("{s}    public var rawValue: UInt16\n", .{pad});
        try w.print("{s}    public init(rawValue: UInt16) {{ self.rawValue = rawValue }}\n", .{pad});
        for (enum_node.enumerants, 0..) |enumerant, ordinal| {
            const member = try self.swiftMemberName(enumerant.name);
            try w.print("{s}    public static let {s} = {s}(rawValue: {d})\n", .{ pad, member, name, ordinal });
        }
        try w.print("{s}    public var isKnown: Bool {{\n", .{pad});
        try w.print("{s}        switch rawValue {{\n", .{pad});
        var cases: std.ArrayList(u8) = .empty;
        defer cases.deinit(self.scratch());
        for (0..enum_node.enumerants.len) |ordinal| {
            if (ordinal > 0) try cases.appendSlice(self.scratch(), ", ");
            var buf: [16]u8 = undefined;
            try cases.appendSlice(self.scratch(), std.fmt.bufPrint(&buf, "{d}", .{ordinal}) catch "0");
        }
        try w.print("{s}        case {s}: return true\n", .{ pad, cases.items });
        try w.print("{s}        default: return false\n", .{pad});
        try w.print("{s}        }}\n", .{pad});
        try w.print("{s}    }}\n", .{pad});
        try w.print("{s}}}\n\n", .{pad});
    }

    // ------------------------------------------------ structs

    fn emitStruct(self: *Generator, w: *std.Io.Writer, node: *schema.Node, indent: usize) !void {
        try self.emitStructNamed(w, node, null, indent);
    }

    fn emitStructNamed(self: *Generator, w: *std.Io.Writer, node: *schema.Node, override_name: ?[]const u8, indent: usize) !void {
        const struct_node = node.struct_node orelse return;
        if (indent > 32) return error.ScopeTooDeep;
        const name = override_name orelse self.swiftTypeName(node);
        const pad = indentation(indent);
        const has_union = struct_node.discriminant_count > 0;

        try w.print("{s}public struct {s} {{\n", .{ pad, name });

        // Nested named declarations first (interfaces too: a nested
        // interface must live inside its parent for qualified references).
        // Only LEXICAL children: a brand application's display name is not
        // prefixed by its parent's (v1 erases brands).
        for (node.nested_nodes) |nested| {
            const child = self.getNode(nested.id) orelse continue;
            if (!lexicalChild(node, child)) continue;
            switch (child.kind) {
                .@"struct" => {
                    const child_struct = child.struct_node orelse continue;
                    if (child_struct.is_group) continue; // groups ride on their field
                    try self.emitStructNamed(w, child, null, indent + 1);
                },
                .@"enum" => try self.emitEnum(w, child, indent + 1),
                .interface => try self.emitInterface(w, child, indent + 1),
                else => {},
            }
        }
        // Group fields become nested types over the same storage, named from
        // the field (`foo :group` -> `Foo`).
        for (struct_node.fields) |field| {
            const group = field.group orelse continue;
            const group_node = self.getNode(group.type_id) orelse continue;
            const group_name = try self.groupTypeName(field);
            try self.emitStructNamed(w, group_node, group_name, indent + 1);
        }

        if (has_union) try self.emitWhichEnum(w, &struct_node, indent + 1);

        try self.emitReader(w, node, indent + 1);
        try self.emitBuilder(w, node, indent + 1, false);

        try w.print("{s}}}\n\n", .{pad});
    }

    /// A results struct: the plain emission plus `bytes` and the
    /// build-closure initializer a handler returns.
    fn emitResultsStruct(self: *Generator, w: *std.Io.Writer, node: *schema.Node, name: []const u8, indent: usize) !void {
        const struct_node = node.struct_node orelse return;
        const pad = indentation(indent);
        try w.print("{s}public struct {s} {{\n", .{ pad, name });
        try w.print("{s}    /// The built response bytes (a standalone message).\n", .{pad});
        try w.print("{s}    public let bytes: [UInt8]\n", .{pad});
        try w.print("{s}    /// Capability slots the interface-typed setters collected.\n", .{pad});
        try w.print("{s}    public var caps: [CapSlot] = []\n", .{pad});
        try w.print("{s}    public init(_ body: (inout Builder) -> Void = {{ _ in }}) {{\n", .{pad});
        try w.print("{s}        let mb = MessageBuilder()\n", .{pad});
        try w.print("{s}        var builder = Builder(mb.initRoot(dataWords: {d}, pointerWords: {d}))\n", .{ pad, struct_node.data_word_count, struct_node.pointer_count });
        try w.print("{s}        body(&builder)\n", .{pad});
        try w.print("{s}        self.bytes = mb.toBytes()\n", .{pad});
        try w.print("{s}        self.caps = builder.caps\n", .{pad});
        try w.print("{s}    }}\n\n", .{pad});

        for (struct_node.fields) |field| {
            const group = field.group orelse continue;
            const group_node = self.getNode(group.type_id) orelse continue;
            try self.emitStructNamed(w, group_node, try self.groupTypeName(field), indent + 1);
        }
        if (struct_node.discriminant_count > 0) try self.emitWhichEnum(w, &struct_node, indent + 1);
        try self.emitReader(w, node, indent + 1);
        try self.emitBuilder(w, node, indent + 1, true);
        try w.print("{s}}}\n\n", .{pad});
    }

    fn emitWhichEnum(self: *Generator, w: *std.Io.Writer, struct_node: *const schema.StructNode, indent: usize) !void {
        const pad = indentation(indent);
        try w.print("{s}public enum Which: Equatable, Sendable {{\n", .{pad});
        for (struct_node.fields) |field| {
            if (field.discriminant_value == no_discriminant) continue;
            const member = try self.swiftMemberName(field.name);
            try w.print("{s}    case {s}\n", .{ pad, member });
        }
        try w.print("{s}    case unknownDiscriminant(UInt16)\n", .{pad});
        try w.print("{s}    public init(discriminant: UInt16) {{\n", .{pad});
        try w.print("{s}        switch discriminant {{\n", .{pad});
        for (struct_node.fields) |field| {
            if (field.discriminant_value == no_discriminant) continue;
            const member = try self.swiftMemberName(field.name);
            try w.print("{s}        case {d}: self = .{s}\n", .{ pad, field.discriminant_value, member });
        }
        try w.print("{s}        default: self = .unknownDiscriminant(discriminant)\n", .{pad});
        try w.print("{s}        }}\n", .{pad});
        try w.print("{s}    }}\n", .{pad});
        try w.print("{s}}}\n\n", .{pad});
    }

    fn emitReader(self: *Generator, w: *std.Io.Writer, node: *schema.Node, indent: usize) !void {
        const struct_node = node.struct_node.?;
        const pad = indentation(indent);
        try w.print("{s}public struct Reader: Sendable {{\n", .{pad});
        try w.print("{s}    let root: StructReader\n", .{pad});
        try w.print("{s}    public init(_ root: StructReader) {{ self.root = root }}\n", .{pad});
        if (struct_node.discriminant_count > 0) {
            try w.print("{s}    public var which: Which {{ Which(discriminant: root.readUInt16(at: {d})) }}\n\n", .{ pad, struct_node.discriminant_offset * 2 });
        }
        try self.emitReaderDefaultStatics(w, node, indent + 1);
        for (struct_node.fields) |field| {
            try self.emitFieldReader(w, node, field, indent + 1);
        }
        try w.print("{s}}}\n\n", .{pad});
    }

    fn emitBuilder(self: *Generator, w: *std.Io.Writer, node: *schema.Node, indent: usize, is_results: bool) !void {
        const struct_node = node.struct_node.?;
        const pad = indentation(indent);
        try w.print("{s}public struct Builder {{\n", .{pad});
        try w.print("{s}    let root: StructBuilder\n", .{pad});
        if (self.in_params_struct) {
            try w.print("{s}    /// Capability slots collected by the interface-typed setters.\n", .{pad});
            try w.print("{s}    public var caps: [CapSlot] = []\n", .{pad});
        }
        try w.print("{s}    public init(_ root: StructBuilder) {{ self.root = root }}\n", .{pad});
        if (struct_node.discriminant_count > 0) {
            try w.print("{s}    public var which: Which {{ Which(discriminant: root.readUInt16(at: {d})) }}\n\n", .{ pad, struct_node.discriminant_offset * 2 });
        }
        for (struct_node.fields) |field| {
            try self.emitFieldBuilder(w, node, field, indent + 1, is_results);
        }
        try w.print("{s}}}\n\n", .{pad});
    }

    /// The interface and every transitive superclass (self first). Generic
    /// interfaces (v1 erases brands to any_pointer) get an empty closure:
    /// their dispatch stays single-interface, since branded method structs
    /// have no declared Swift counterpart.
    fn interfaceClosure(self: *Generator, node: *schema.Node) ![]*schema.Node {
        var out: std.ArrayList(*schema.Node) = .empty;
        if (node.is_generic) return out.items;
        try out.append(self.scratch(), node);
        var i: usize = 0;
        while (i < out.items.len) : (i += 1) {
            const iface = out.items[i].interface_node orelse continue;
            for (iface.superclasses) |super_id| {
                const sup = self.getNode(super_id) orelse continue;
                if (sup.is_generic) continue;
                var seen = false;
                for (out.items) |existing| {
                    if (existing.id == sup.id) seen = true;
                }
                if (!seen) try out.append(self.scratch(), sup);
            }
        }
        return out.items;
    }

    fn emitInterface(self: *Generator, w: *std.Io.Writer, node: *schema.Node, indent: usize) anyerror!void {
        const iface = node.interface_node orelse return;
        if (indent > 32) return error.ScopeTooDeep;
        const name = self.swiftTypeName(node);
        const pad = indentation(indent);

        try w.print("{s}public enum {s} {{\n", .{ pad, name });
        try w.print("{s}    public static let interfaceID: UInt64 = 0x{x}\n\n", .{ pad, node.id });

        for (node.nested_nodes) |nested| {
            const child = self.getNode(nested.id) orelse continue;
            switch (child.kind) {
                .@"struct" => {
                    const child_struct = child.struct_node orelse continue;
                    if (child_struct.is_group) continue;
                    try self.emitStruct(w, child, indent + 1);
                },
                .@"enum" => try self.emitEnum(w, child, indent + 1),
                .interface => try self.emitInterface(w, child, indent + 1),
                else => {},
            }
        }

        // Methods enum.
        if (iface.methods.len > 0) {
            try w.print("{s}    public enum Method: UInt16 {{\n", .{pad});
            for (iface.methods, 0..) |method, ordinal| {
                try w.print("{s}        case {s} = {d}\n", .{ pad, try self.swiftMemberName(method.name), ordinal });
            }
            try w.print("{s}    }}\n\n", .{pad});
        }

        // A CapnpError during payload decode becomes RPCError.malformed.
        try w.print("{s}    fileprivate static func decoding<T>(_ body: () throws -> T) throws -> T {{\n", .{pad});
        try w.print("{s}        do {{ return try body() }} catch let error as CapnpError {{ throw RPCError.malformed(\"\\(error)\") }}\n", .{pad});
        try w.print("{s}    }}\n\n", .{pad});

        // Param/result structs (named `<Method>Params` / `<Method>Results`).
        for (iface.methods) |method| {
            const mcap = try self.capitalized(try self.swiftMemberName(method.name));
            if (self.getNode(method.param_struct_type)) |pn| {
                const pname = try self.suffixed(mcap, "Params");
                // Save/restore: nested emissions (a nested interface inside
                // the params struct) run their own params cycles and must
                // not clobber this one.
                const saved = self.in_params_struct;
                self.in_params_struct = true;
                try self.emitStructNamed(w, pn, pname, indent + 1);
                self.in_params_struct = saved;
            }
            if (!method.isStreaming()) {
                if (self.getNode(method.result_struct_type)) |rn| {
                    const rname = try self.suffixed(mcap, "Results");
                    const saved = self.in_params_struct;
                    self.in_params_struct = true;
                    try self.emitResultsStruct(w, rn, rname, indent + 1);
                    self.in_params_struct = saved;
                }
            }
        }

        const iname_q = self.swiftTypeName(node);
        // Server protocol: superclass Server protocols are inherited, so a
        // conforming object implements the ancestors' methods too.
        try w.print("{s}    public protocol Server: Sendable", .{pad});
        for (iface.superclasses) |super_id| {
            const sup = self.getNode(super_id) orelse continue;
            try w.print(", {s}.Server", .{self.swiftRef(sup)});
        }
        try w.writeAll(" {\n");
        for (iface.methods) |method| {
            const mname = try self.swiftMemberName(method.name);
            const mcap = try self.suffixed(try self.capitalized(mname), "Params");
            if (method.isStreaming()) {
                // Streaming methods have no results to build: the runtime
                // answers an empty StreamResult.
                try w.print("{s}        func {s}(params: {s}.{s}.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws\n", .{ pad, mname, iname_q, mcap });
            } else {
                try w.print("{s}        func {s}(params: {s}.{s}.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> {s}.{s}\n", .{ pad, mname, iname_q, mcap, iname_q, try self.suffixed(try self.capitalized(mname), "Results") });
            }
        }
        try w.print("{s}    }}\n\n", .{pad});

        try self.emitClient(w, node, indent + 1);
        try self.emitExport(w, node, indent + 1);
        try w.print("{s}}}\n\n", .{pad});
    }

    fn emitClient(self: *Generator, w: *std.Io.Writer, node: *schema.Node, indent: usize) !void {
        const iface = node.interface_node.?;
        const iname = self.swiftTypeName(node);
        const pad = indentation(indent);

        try w.print("{s}public struct Client: Sendable {{\n", .{pad});
        try w.print("{s}    public let target: CallTarget\n", .{pad});
        try w.print("{s}    public let connection: RPCConnection\n", .{pad});
        try w.print("{s}    public init(cap: CapRef, connection: RPCConnection) {{\n", .{pad});
        try w.print("{s}        self.target = .cap(cap)\n", .{pad});
        try w.print("{s}        self.connection = connection\n", .{pad});
        try w.print("{s}    }}\n\n", .{pad});
        try w.print("{s}    public init(pipelined: PipelinedCap, connection: RPCConnection) {{\n", .{pad});
        try w.print("{s}        self.target = .pipelined(pipelined)\n", .{pad});
        try w.print("{s}        self.connection = connection\n", .{pad});
        try w.print("{s}    }}\n\n", .{pad});
        try w.print("{s}    init(target: CallTarget, connection: RPCConnection) {{\n", .{pad});
        try w.print("{s}        self.target = target\n", .{pad});
        try w.print("{s}        self.connection = connection\n", .{pad});
        try w.print("{s}    }}\n\n", .{pad});

        // Ancestor interfaces callable through the same capability. Two
        // ancestors may share a name (`extends(First, External.First)`):
        // later properties get a numeric suffix.
        var used_props: std.ArrayList([]const u8) = .empty;
        for (iface.superclasses) |super_id| {
            const sup = self.getNode(super_id) orelse continue;
            const sup_ref = self.swiftRef(sup);
            // Lower-cased so it never shadows the interface type itself.
            var prop = try self.swiftMemberName(try self.lowerFirst(lastSegment(sup.display_name)));
            var suffix: usize = 2;
            while (blk: {
                for (used_props.items) |u| {
                    if (std.mem.eql(u8, u, prop)) break :blk true;
                }
                break :blk false;
            }) {
                prop = try std.fmt.allocPrint(self.scratch(), "{s}{d}", .{ prop, suffix });
                suffix += 1;
            }
            try used_props.append(self.scratch(), prop);
            try w.print("{s}    /// Calls on `{s}` through this capability.\n", .{ pad, sup_ref });
            try w.print("{s}    public var {s}: {s}.Client {{ {s}.Client(target: target, connection: connection) }}\n\n", .{ pad, prop, sup_ref, sup_ref });
        }

        for (iface.methods) |method| {
            if (method.isStreaming()) {
                const mname = try self.swiftMemberName(method.name);
                const mcap = try std.fmt.allocPrint(self.scratch(), "{s}.{s}", .{ iname, try self.suffixed(try self.capitalized(mname), "Params") });
                const params_node = self.getNode(method.param_struct_type);
                const dw: usize = if (params_node) |pn| pn.struct_node.?.data_word_count else 0;
                const pw: usize = if (params_node) |pn| pn.struct_node.?.pointer_count else 0;
                try w.print("{s}    /// One streamed call. The connection's stream window suspends the\n", .{pad});
                try w.print("{s}    /// sender above `Options.streamWindowMaxCalls`/`Bytes` in flight (plan S5).\n", .{pad});
                try w.print("{s}    public func {s}(_ body: (inout {s}.Builder) -> Void = {{ _ in }}) async throws {{\n", .{ pad, mname, mcap });
                try w.print("{s}        let mb = MessageBuilder()\n", .{pad});
                try w.print("{s}        var params = {s}.Builder(mb.initRoot(dataWords: {d}, pointerWords: {d}))\n", .{ pad, mcap, dw, pw });
                try w.print("{s}        body(&params)\n", .{pad});
                try w.print("{s}        let bytes = mb.toBytes().count\n", .{pad});
                try w.print("{s}        try await connection.streamWindow.acquire(bytes: bytes)\n", .{pad});
                try w.print("{s}        defer {{ connection.streamWindow.release(bytes: bytes) }}\n", .{pad});
                try w.print("{s}        _ = try await connection.call(target, interface: {s}.interfaceID, method: Method.{s}.rawValue, params: mb.toBytes(), caps: params.caps)\n", .{ pad, iname, mname });
                try w.print("{s}    }}\n\n", .{pad});
                continue;
            }
            const mname = try self.swiftMemberName(method.name);
            const mcap = try self.capitalized(mname);
            const params_name = try std.fmt.allocPrint(self.scratch(), "{s}.{s}", .{ iname, try self.suffixed(mcap, "Params") });
            const results_name = try std.fmt.allocPrint(self.scratch(), "{s}.{s}", .{ iname, try self.suffixed(mcap, "Results") });
            const call_name = try self.suffixed(mcap, "Call");
            const send_name = try self.suffixed("send", mcap);
            const params_node = self.getNode(method.param_struct_type);
            const results_node = self.getNode(method.result_struct_type);
            const dw: usize = if (params_node) |pn| pn.struct_node.?.data_word_count else 0;
            const pw: usize = if (params_node) |pn| pn.struct_node.?.pointer_count else 0;
            try w.print("{s}    public func {s}(_ body: (inout {s}.Builder) -> Void = {{ _ in }}) async throws -> {s}.Reader {{\n", .{ pad, mname, params_name, results_name });
            try w.print("{s}        let mb = MessageBuilder()\n", .{pad});
            try w.print("{s}        var params = {s}.Builder(mb.initRoot(dataWords: {d}, pointerWords: {d}))\n", .{ pad, params_name, dw, pw });
            try w.print("{s}        body(&params)\n", .{pad});
            try w.print("{s}        let result = try await connection.call(target, interface: {s}.interfaceID, method: Method.{s}.rawValue, params: mb.toBytes(), caps: params.caps)\n", .{ pad, iname, mname });
            try w.print("{s}        return try decoding {{ try {s}.Reader(Message(bytes: result.message).rootStruct()) }}\n", .{ pad, results_name });
            try w.print("{s}    }}\n\n", .{pad});

            // Typed promise: sendGreet -> GreetCall (pipeline on result caps).
            try w.print("{s}    public struct {s}: Sendable {{\n", .{ pad, call_name });
            try w.print("{s}        public let question: RemotePromise\n", .{pad});
            try w.print("{s}        public private(set) var resultCaps: [CapTableEntry] = []\n", .{pad});
            try w.print("{s}        public let connection: RPCConnection\n", .{pad});
            try w.print("{s}        public mutating func value() async throws -> {s}.Reader {{\n", .{ pad, results_name });
            try w.print("{s}            let result = try await question.result()\n", .{pad});
            try w.print("{s}            resultCaps = result.caps\n", .{pad});
            try w.print("{s}            return try decoding {{ try {s}.Reader(Message(bytes: result.message).rootStruct()) }}\n", .{ pad, results_name });
            try w.print("{s}        }}\n", .{pad});
            if (results_node) |rn| {
                for (rn.struct_node.?.fields) |field| {
                    const slot = field.slot orelse continue;
                    const it = switch (slot.type) {
                        .interface => |i| i,
                        else => continue,
                    };
                    const inode = self.getNode(it.type_id) orelse continue;
                    const iref = self.swiftRef(inode);
                    const fname = try self.swiftMemberName(field.name);
                    try w.print("{s}        /// Pipelined `{s}`: callable before the RETURN.\n", .{ pad, field.name });
                    try w.print("{s}        public var {s}: {s}.Client {{ {s}.Client(pipelined: question.pipeline([{d}]), connection: connection) }}\n", .{ pad, fname, iref, iref, slot.offset });
                }
            }
            try w.print("{s}    }}\n\n", .{pad});
            try w.print("{s}    public func {s}(_ body: (inout {s}.Builder) -> Void = {{ _ in }}) async throws -> {s} {{\n", .{ pad, send_name, params_name, call_name });
            try w.print("{s}        let mb = MessageBuilder()\n", .{pad});
            try w.print("{s}        var params = {s}.Builder(mb.initRoot(dataWords: {d}, pointerWords: {d}))\n", .{ pad, params_name, dw, pw });
            try w.print("{s}        body(&params)\n", .{pad});
            try w.print("{s}        let promise = try await connection.send(target, interface: {s}.interfaceID, method: Method.{s}.rawValue, params: mb.toBytes(), caps: params.caps)\n", .{ pad, iname, mname });
            try w.print("{s}        return {s}(question: promise, connection: connection)\n", .{ pad, call_name });
            try w.print("{s}    }}\n\n", .{pad});
        }
        try w.print("{s}}}\n\n", .{pad});
    }

    fn emitExport(self: *Generator, w: *std.Io.Writer, node: *schema.Node, indent: usize) !void {
        const iface = node.interface_node.?;
        const iname = self.swiftTypeName(node);
        const pad = indentation(indent);
        const closure = try self.interfaceClosure(node);

        try w.print("{s}/// Serves a `Server` on a connection (pass it in `CapSlot.export`).\n", .{pad});
        try w.print("{s}/// Inherited interfaces dispatch here too (the Server protocol inherits\n", .{pad});
        try w.print("{s}/// their requirements; E-order holds for the whole closure).\n", .{pad});
        try w.print("{s}public struct Export: ExportHandler {{\n", .{pad});
        try w.print("{s}    public let server: any Server\n", .{pad});
        try w.print("{s}    public init(_ server: any Server) {{ self.server = server }}\n", .{pad});
        try w.print("{s}    public func handle(_ call: InboundCall, on connection: isolated RPCConnection) async throws -> CallResponse {{\n", .{pad});
        if (closure.len == 0) {
            try w.print("{s}        guard call.interfaceID == {s}.interfaceID else {{ throw RPCError.unimplemented(reason: \"{s}: wrong interface\") }}\n", .{ pad, iname, iname });
            try w.print("{s}        switch call.methodID {{\n", .{pad});
            for (iface.methods) |method| {
                const mname = try self.swiftMemberName(method.name);
                const mcap = try self.suffixed(try self.capitalized(mname), "Params");
                try w.print("{s}        case Method.{s}.rawValue:\n", .{ pad, mname });
                try w.print("{s}            let params = try decoding {{ try {s}.{s}.Reader(Message(bytes: call.params).rootStruct()) }}\n", .{ pad, iname, mcap });
                if (method.isStreaming()) {
                    try w.print("{s}            try await server.{s}(params: params, caps: call.caps, on: call.connection)\n", .{ pad, mname });
                    try w.print("{s}            return CallResponse(message: MessageBuilder.emptyStruct())\n", .{pad});
                } else {
                    try w.print("{s}            let results = try await server.{s}(params: params, caps: call.caps, on: call.connection)\n", .{ pad, mname });
                    try w.print("{s}            return CallResponse(message: results.bytes)\n", .{pad});
                }
            }
            try w.print("{s}        default:\n", .{pad});
            try w.print("{s}            throw RPCError.unimplemented(reason: \"{s}: no such method\")\n", .{ pad, iname });
            try w.print("{s}        }}\n", .{pad});
            try w.print("{s}    }}\n", .{pad});
            try w.print("{s}}}\n\n", .{pad});
            return;
        }
        try w.print("{s}        switch call.interfaceID {{\n", .{pad});
        for (closure) |ancestor| {
            const a_iface = ancestor.interface_node orelse continue;
            const a_name = self.swiftTypeName(ancestor);
            try w.print("{s}        case {s}.interfaceID:\n", .{ pad, self.swiftRef(ancestor) });
            try w.print("{s}            switch call.methodID {{\n", .{pad});
            for (a_iface.methods) |method| {
                const mname = try self.swiftMemberName(method.name);
                const mcap = try self.suffixed(try self.capitalized(mname), "Params");
                try w.print("{s}            case {s}.Method.{s}.rawValue:\n", .{ pad, self.swiftRef(ancestor), mname });
                try w.print("{s}                let params = try decoding {{ try {s}.{s}.Reader(Message(bytes: call.params).rootStruct()) }}\n", .{ pad, self.swiftRef(ancestor), mcap });
                if (method.isStreaming()) {
                    try w.print("{s}                try await server.{s}(params: params, caps: call.caps, on: call.connection)\n", .{ pad, mname });
                    try w.print("{s}                return CallResponse(message: MessageBuilder.emptyStruct())\n", .{pad});
                } else {
                    try w.print("{s}                let results = try await server.{s}(params: params, caps: call.caps, on: call.connection)\n", .{ pad, mname });
                    try w.print("{s}                return CallResponse(message: results.bytes, caps: results.caps)\n", .{pad});
                }
            }
            try w.print("{s}            default:\n", .{pad});
            try w.print("{s}                throw RPCError.unimplemented(reason: \"{s}: no such method\")\n", .{ pad, a_name });
            try w.print("{s}            }}\n", .{pad});
        }
        try w.print("{s}        default:\n", .{pad});
        try w.print("{s}            throw RPCError.unimplemented(reason: \"{s}: wrong interface\")\n", .{ pad, iname });
        try w.print("{s}        }}\n", .{pad});
        try w.print("{s}    }}\n", .{pad});
        try w.print("{s}}}\n\n", .{pad});
    }

    // ------------------------------------------------ fields

    fn emitFieldReader(self: *Generator, w: *std.Io.Writer, parent: *schema.Node, field: schema.Field, indent: usize) !void {
        const pad = indentation(indent);
        const name = try self.fieldAccessorName(parent, field);
        if (field.group) |group| {
            _ = group;
            const type_name = try self.groupTypeName(field);
            try w.print("{s}public var {s}: {s}.Reader {{ {s}.Reader(root) }}\n\n", .{ pad, name, type_name, type_name });
            return;
        }
        const slot = field.slot orelse return; // void fields carry nothing
        const dv = slot.default_value;
        const off = dataByteOffset(slot);
        switch (slot.type) {
            .void => {},
            .bool => try self.readScalarXor(w, pad, name, "Bool", slot, dv, "readBool", off, "bool"),
            .int8 => try self.readScalarXor(w, pad, name, "Int8", slot, dv, "readInt8", off, "int"),
            .int16 => try self.readScalarXor(w, pad, name, "Int16", slot, dv, "readInt16", off, "int"),
            .int32 => try self.readScalarXor(w, pad, name, "Int32", slot, dv, "readInt32", off, "int"),
            .int64 => try self.readScalarXor(w, pad, name, "Int64", slot, dv, "readInt64", off, "int"),
            .uint8 => try self.readScalarXor(w, pad, name, "UInt8", slot, dv, "readUInt8", off, "int"),
            .uint16 => try self.readScalarXor(w, pad, name, "UInt16", slot, dv, "readUInt16", off, "int"),
            .uint32 => try self.readScalarXor(w, pad, name, "UInt32", slot, dv, "readUInt32", off, "int"),
            .uint64 => try self.readScalarXor(w, pad, name, "UInt64", slot, dv, "readUInt64", off, "int"),
            .float32 => try self.readScalarXor(w, pad, name, "Float32", slot, dv, "readFloat32", off, "float"),
            .float64 => try self.readScalarXor(w, pad, name, "Float64", slot, dv, "readFloat64", off, "float"),
            .@"enum" => |e| {
                const enum_node = self.getNode(e.type_id) orelse return error.MissingEnumNode;
                const type_name = self.swiftRef(enum_node);
                try self.readScalarXor(w, pad, name, type_name, slot, dv, "readUInt16", off, "enum");
            },
            .text => {
                try w.print("{s}public func {s}() throws -> String {{\n", .{ pad, name });
                if (dv) |v| {
                    if (v.text.len > 0) {
                        const literal = try self.swiftStringLiteral(v.text);
                        try w.print("{s}    if root.isPointerNull({d}) {{ return {s} }}\n", .{ pad, slot.offset, literal });
                    }
                }
                try w.print("{s}    return try root.readTextOrDefault({d})\n", .{ pad, slot.offset });
                try w.print("{s}}}\n\n", .{pad});
            },
            .data => {
                try w.print("{s}public func {s}() throws -> [UInt8] {{\n", .{ pad, name });
                if (dv) |v| {
                    if (v.data.len > 0) {
                        const literal = try self.swiftByteArrayLiteral(v.data);
                        try w.print("{s}    if root.isPointerNull({d}) {{ return {s} }}\n", .{ pad, slot.offset, literal });
                    }
                }
                try w.print("{s}    return try root.readDataOrDefault({d})\n", .{ pad, slot.offset });
                try w.print("{s}}}\n\n", .{pad});
            },
            .@"struct" => |s| {
                const target = self.getNode(s.type_id) orelse return error.MissingStructNode;
                const type_name = self.swiftRef(target);
                const static_name = try self.staticDefaultName(name);
                try w.print("{s}public var {s}: {s}.Reader {{\n", .{ pad, name, type_name });
                if (dv) |v| {
                    if (v.@"struct".message_bytes.len > 0) {
                        try w.print("{s}    if root.isPointerNull({d}) {{ return {s}.Reader(Self.{s}.rootStruct()) }}\n", .{ pad, slot.offset, type_name, static_name });
                    }
                }
                try w.print("{s}    return {s}.Reader(root.readStructOrDefault({d}))\n", .{ pad, type_name, slot.offset });
                try w.print("{s}}}\n\n", .{pad});
            },
            .list => |l| try self.emitListReader(w, pad, name, slot, l.element_type),
            .interface => |i| {
                try w.print("{s}/// The capability's index into the payload's cap table (nil when null).\n", .{pad});
                try w.print("{s}public func {s}CapIndex() -> UInt32? {{ (try? root.readCapabilityIndex({d})) ?? nil }}\n\n", .{ pad, name, slot.offset });
                if (self.getNode(i.type_id)) |inode| {
                    {
                        const iref = self.swiftRef(inode);
                        try w.print("{s}/// The capability as a Client, resolved through the payload's cap table.\n", .{pad});
                        try w.print("{s}public func {s}(_ caps: [CapTableEntry], on connection: RPCConnection) -> {s}.Client? {{\n", .{ pad, name, iref });
                        try w.print("{s}    guard let index = {s}CapIndex(), Int(index) < caps.count,\n", .{ pad, name });
                        try w.print("{s}        case .imported(let ref) = caps[Int(index)] else {{ return nil }}\n", .{pad});
                        try w.print("{s}    return {s}.Client(cap: ref, connection: connection)\n", .{ pad, iref });
                        try w.print("{s}}}\n\n", .{pad});
                    }
                }
            },
            .any_pointer => {
                try w.print("{s}public var {s}: Bool {{ root.isPointerNull({d}) }}\n\n", .{ pad, try self.suffixedIdentifier(name, "IsNull"), slot.offset });
            },
        }
    }

    /// `private static let <Field>Default[Bytes]` for every struct field
    /// with a non-empty pointer default, at Reader scope.
    fn emitReaderDefaultStatics(self: *Generator, w: *std.Io.Writer, node: *schema.Node, indent: usize) !void {
        const struct_node = node.struct_node.?;
        const pad = indentation(indent);
        for (struct_node.fields) |field| {
            const slot = field.slot orelse continue;
            const dv = slot.default_value orelse continue;
            switch (slot.type) {
                .@"struct" => {
                    if (dv.@"struct".message_bytes.len == 0) continue;
                    const name = try self.fieldAccessorName(node, field);
                    const static_name = try self.staticDefaultName(name);
                    const bytes = try self.swiftByteArrayLiteral(dv.@"struct".message_bytes);
                    try w.print("{s}static let {s}Bytes = {s}\n", .{ pad, static_name, bytes });
                    try w.print("{s}static let {s} = CapnpDefaultMessage(bytes: {s}Bytes)\n", .{ pad, static_name, static_name });
                },
                else => {},
            }
        }
    }

    /// A data field's byte offset: capnp measures non-bool data offsets in
    /// units of the field's size (schema.capnp Field.slot.offset; capnpc-zig
    /// scales the same way). Bool offsets are bit offsets; pointer offsets
    /// are pointer-section indices (unscaled).
    fn dataByteOffset(slot: schema.FieldSlot) u32 {
        return switch (slot.type) {
            .int16, .uint16, .@"enum" => slot.offset * 2,
            .int32, .uint32, .float32 => slot.offset * 4,
            .int64, .uint64, .float64 => slot.offset * 8,
            else => slot.offset,
        };
    }

    /// Scalar read with capnp's default encoding: the wire stores
    /// `value ^ default`, so a zeroed struct reads as its defaults (and a
    /// truncated one reads zeros, then XORs to the same defaults).
    fn readScalarXor(self: *Generator, w: *std.Io.Writer, pad: []const u8, name: []const u8, swift_type: []const u8, slot: schema.FieldSlot, dv: ?schema.Value, comptime meth: []const u8, off: u32, comptime kind: []const u8) !void {
        _ = slot;
        const read = try self.fmtAt(meth ++ "(at: {d})", off);
        const has_default = switch (dv orelse schema.Value{ .void = {} }) {
            .void => false,
            .bool => |v| v,
            .int8 => |v| v != 0,
            .int16 => |v| v != 0,
            .int32 => |v| v != 0,
            .int64 => |v| v != 0,
            .uint8 => |v| v != 0,
            .uint16 => |v| v != 0,
            .uint32 => |v| v != 0,
            .uint64 => |v| v != 0,
            .float32 => |v| @as(u32, @bitCast(v)) != 0,
            .float64 => |v| @as(u64, @bitCast(v)) != 0,
            .@"enum" => |v| v != 0,
            else => false,
        };
        if (!has_default) {
            if (comptime std.mem.eql(u8, kind, "enum")) {
                try w.print("{s}public var {s}: {s} {{ {s}(rawValue: root.{s}) }}\n\n", .{ pad, name, swift_type, swift_type, read });
            } else {
                try w.print("{s}public var {s}: {s} {{ root.{s} }}\n\n", .{ pad, name, swift_type, read });
            }
            return;
        }
        try w.print("{s}public var {s}: {s} {{\n", .{ pad, name, swift_type });
        if (comptime std.mem.eql(u8, kind, "bool")) {
            if (dv.?.bool) {
                try w.print("{s}    return !root.{s}\n", .{ pad, read });
            } else {
                try w.print("{s}    return root.{s}\n", .{ pad, read });
            }
        } else if (comptime std.mem.eql(u8, kind, "float")) {
            if (std.mem.eql(u8, swift_type, "Float32")) {
                try w.print("{s}    return Float32(bitPattern: root.readUInt32(at: {d}) ^ 0x{x})\n", .{ pad, off, @as(u32, @bitCast(dv.?.float32)) });
            } else {
                try w.print("{s}    return Float64(bitPattern: root.readUInt64(at: {d}) ^ 0x{x})\n", .{ pad, off, @as(u64, @bitCast(dv.?.float64)) });
            }
        } else if (comptime std.mem.eql(u8, kind, "enum")) {
            try w.print("{s}    return {s}(rawValue: root.readUInt16(at: {d}) ^ {d})\n", .{ pad, swift_type, off, dv.?.@"enum" });
        } else {
            const d: i128 = switch (dv.?) {
                .int8 => |v| v,
                .int16 => |v| v,
                .int32 => |v| v,
                .int64 => |v| v,
                .uint8 => |v| v,
                .uint16 => |v| v,
                .uint32 => |v| v,
                .uint64 => |v| v,
                else => 0,
            };
            try w.print("{s}    return root.{s} ^ {d}\n", .{ pad, read, d });
        }
        try w.print("{s}}}\n\n", .{pad});
    }

    fn fmtAt(self: *Generator, comptime fmt: []const u8, offset: u32) ![]const u8 {
        return std.fmt.allocPrint(self.scratch(), fmt, .{offset});
    }

    fn fixedListReader(w: *std.Io.Writer, pad: []const u8, name: []const u8, swift_scalar: []const u8, offset: u32) !void {
        try w.print("{s}public func {s}() throws -> FixedSizeListReader<{s}>? {{ try root.readFixedSizeListOrDefault({d}, as: {s}.self) }}\n\n", .{ pad, name, swift_scalar, offset, swift_scalar });
    }

    fn emitListReader(self: *Generator, w: *std.Io.Writer, pad: []const u8, name: []const u8, slot: schema.FieldSlot, element: *schema.Type) !void {
        switch (element.*) {
            .void, .interface => try w.print("{s}public func {s}() throws -> PointerListReader? {{ try root.readPointerListOrDefault({d}) }}\n\n", .{ pad, name, slot.offset }),
            .bool => try w.print("{s}public func {s}() throws -> BitListReader? {{ try root.readBoolListOrDefault({d}) }}\n\n", .{ pad, name, slot.offset }),
            .int8 => try fixedListReader(w, pad, name, "Int8", slot.offset),
            .int16 => try fixedListReader(w, pad, name, "Int16", slot.offset),
            .int32 => try fixedListReader(w, pad, name, "Int32", slot.offset),
            .int64 => try fixedListReader(w, pad, name, "Int64", slot.offset),
            .uint8 => try fixedListReader(w, pad, name, "UInt8", slot.offset),
            .uint16 => try fixedListReader(w, pad, name, "UInt16", slot.offset),
            .uint32 => try fixedListReader(w, pad, name, "UInt32", slot.offset),
            .uint64 => try fixedListReader(w, pad, name, "UInt64", slot.offset),
            .float32 => try w.print("{s}public func {s}() throws -> Float32ListReader? {{ try root.readFloat32ListOrDefault({d}) }}\n\n", .{ pad, name, slot.offset }),
            .float64 => try w.print("{s}public func {s}() throws -> Float64ListReader? {{ try root.readFloat64ListOrDefault({d}) }}\n\n", .{ pad, name, slot.offset }),
            .@"enum" => |e| {
                const enum_node = self.getNode(e.type_id) orelse return error.MissingEnumNode;
                const type_name = self.swiftRef(enum_node);
                try w.print("{s}public func {s}() throws -> FixedSizeListReader<UInt16>? {{ try root.readFixedSizeListOrDefault({d}, as: UInt16.self) }}\n\n", .{ pad, name, slot.offset });
                try w.print("{s}public func {s}Elements() throws -> [{s}] {{\n", .{ pad, name, type_name });
                try w.print("{s}    guard let list = try {s}() else {{ return [] }}\n", .{ pad, name });
                try w.print("{s}    var out: [{s}] = []\n", .{ pad, type_name });
                try w.print("{s}    out.reserveCapacity(list.count)\n", .{pad});
                try w.print("{s}    for i in list.indices {{ out.append({s}(rawValue: list[i])) }}\n", .{ pad, type_name });
                try w.print("{s}    return out\n", .{pad});
                try w.print("{s}}}\n\n", .{pad});
            },
            .text, .data, .any_pointer, .list => try w.print("{s}public func {s}() throws -> PointerListReader? {{ try root.readPointerListOrDefault({d}) }}\n\n", .{ pad, name, slot.offset }),
            .@"struct" => |s| {
                const element_node = self.getNode(s.type_id) orelse return error.MissingStructNode;
                const element_name = self.swiftRef(element_node);
                const list_type = try self.capitalized(name);
                try w.print("{s}public struct {s}List: Sendable {{\n", .{ pad, list_type });
                try w.print("{s}    public let list: StructListReader\n", .{pad});
                try w.print("{s}    public var count: Int {{ list.count }}\n", .{pad});
                try w.print("{s}    public var indices: Range<Int> {{ list.indices }}\n", .{pad});
                try w.print("{s}    public subscript(index: Int) -> {s}.Reader {{ {s}.Reader(list[index]) }}\n", .{ pad, element_name, element_name });
                try w.print("{s}}}\n\n", .{pad});
                try w.print("{s}public func {s}() throws -> {s}List? {{ (try root.readStructListOrDefault({d})).map({s}List.init) }}\n\n", .{ pad, name, list_type, slot.offset, list_type });
            },
        }
    }

    fn emitFieldBuilder(self: *Generator, w: *std.Io.Writer, parent: *schema.Node, field: schema.Field, indent: usize, is_results: bool) !void {
        const pad = indentation(indent);
        const name = try self.fieldAccessorName(parent, field);
        if (field.group) |group| {
            _ = group;
            const type_name = try self.groupTypeName(field);
            try w.print("{s}public var {s}: {s}.Builder {{ {s}.Builder(root) }}\n\n", .{ pad, name, type_name, type_name });
            return;
        }
        const slot = field.slot orelse return;
        const off = dataByteOffset(slot);
        const dv = slot.default_value;
        switch (slot.type) {
            .void => {
                if (field.discriminant_value != no_discriminant) {
                    // A union member with no payload: setting it only writes
                    // the discriminant.
                    try w.print("{s}public func set{s}() {{ root.setUInt16(at: {d}, {d}) }}\n\n", .{ pad, try self.capitalized(name), parent.struct_node.?.discriminant_offset * 2, field.discriminant_value });
                }
            },
            .bool => try self.buildScalarXor(w, pad, name, "Bool", slot, dv, "setBool", "readBool"),
            .int8 => try self.buildScalarXor(w, pad, name, "Int8", slot, dv, "setInt8", "readInt8"),
            .int16 => try self.buildScalarXor(w, pad, name, "Int16", slot, dv, "setInt16", "readInt16"),
            .int32 => try self.buildScalarXor(w, pad, name, "Int32", slot, dv, "setInt32", "readInt32"),
            .int64 => try self.buildScalarXor(w, pad, name, "Int64", slot, dv, "setInt64", "readInt64"),
            .uint8 => try self.buildScalarXor(w, pad, name, "UInt8", slot, dv, "setUInt8", "readUInt8"),
            .uint16 => try self.buildScalarXor(w, pad, name, "UInt16", slot, dv, "setUInt16", "readUInt16"),
            .uint32 => try self.buildScalarXor(w, pad, name, "UInt32", slot, dv, "setUInt32", "readUInt32"),
            .uint64 => try self.buildScalarXor(w, pad, name, "UInt64", slot, dv, "setUInt64", "readUInt64"),
            .float32 => try self.buildScalarXor(w, pad, name, "Float32", slot, dv, "setFloat32", "readFloat32"),
            .float64 => try self.buildScalarXor(w, pad, name, "Float64", slot, dv, "setFloat64", "readFloat64"),
            .@"enum" => |e| {
                const enum_node = self.getNode(e.type_id) orelse return error.MissingEnumNode;
                const type_name = self.swiftRef(enum_node);
                try w.print("{s}public var {s}: {s} {{\n", .{ pad, name, type_name });
                try w.print("{s}    get {{ {s}(rawValue: root.readUInt16(at: {d})) }}\n", .{ pad, type_name, off });
                try w.print("{s}    set {{ root.setEnum16(at: {d}, newValue.rawValue) }}\n", .{ pad, off });
                try w.print("{s}}}\n\n", .{pad});
            },
            .text => {
                try w.print("{s}public func set{s}(_ v: String) {{", .{ pad, try self.capitalized(name) });
                if (field.discriminant_value != no_discriminant) {
                    try w.print(" root.setUInt16(at: {d}, {d});", .{ parent.struct_node.?.discriminant_offset * 2, field.discriminant_value });
                }
                try w.print(" root.setText({d}, v) }}\n\n", .{slot.offset});
            },
            .data => {
                try w.print("{s}public func set{s}(_ v: [UInt8]) {{", .{ pad, try self.capitalized(name) });
                if (field.discriminant_value != no_discriminant) {
                    try w.print(" root.setUInt16(at: {d}, {d});", .{ parent.struct_node.?.discriminant_offset * 2, field.discriminant_value });
                }
                try w.print(" root.setData({d}, v) }}\n\n", .{slot.offset});
            },
            .@"struct" => |s| {
                const target = self.getNode(s.type_id) orelse return error.MissingStructNode;
                const target_node = target.struct_node.?;
                const type_name = self.swiftRef(target);
                const cap = try self.capitalized(name);
                try w.print("{s}public func init{s}() -> {s}.Builder {{\n", .{ pad, cap, type_name });
                if (field.discriminant_value != no_discriminant) {
                    try w.print("{s}    root.setUInt16(at: {d}, {d})\n", .{ pad, parent.struct_node.?.discriminant_offset * 2, field.discriminant_value });
                }
                try w.print("{s}    return {s}.Builder(root.initStruct({d}, dataWords: {d}, pointerWords: {d}))\n", .{ pad, type_name, slot.offset, target_node.data_word_count, target_node.pointer_count });
                try w.print("{s}}}\n\n", .{pad});
            },
            .list => |l| try self.emitListBuilder(w, pad, name, slot, l.element_type),
            .interface => |i| {
                if (self.in_params_struct) {
                    if (self.getNode(i.type_id)) |inode| {
                        {
                        const iref = self.swiftRef(inode);
                        const cap = try self.capitalized(name);
                        try w.print("{s}/// Export `server` and point the field at it.\n", .{pad});
                        try w.print("{s}public mutating func set{s}(_ server: any {s}.Server) {{\n", .{ pad, cap, iref });
                        try w.print("{s}    root.setCapability({d}, capIndex: UInt32(caps.count))\n", .{ pad, slot.offset });
                        try w.print("{s}    caps.append(.export({s}.Export(server)))\n", .{ pad, iref });
                        try w.print("{s}}}\n\n", .{pad});
                        if (is_results) {
                            try w.print("{s}/// Point the field at an unresolved promise export (resolved later).\n", .{pad});
                            try w.print("{s}public mutating func set{s}(promise: PromiseExport) {{\n", .{ pad, cap });
                            try w.print("{s}    root.setCapability({d}, capIndex: UInt32(caps.count))\n", .{ pad, slot.offset });
                            try w.print("{s}    caps.append(.promise(promise))\n", .{pad});
                            try w.print("{s}}}\n\n", .{pad});
                        }
                        return;
                    }
                    }
                }
                try w.print("{s}public func set{s}(capIndex: UInt32) {{ root.setCapability({d}, capIndex: capIndex) }}\n\n", .{ pad, try self.capitalized(name), slot.offset });
            },
            .any_pointer => {},
        }
    }

    fn buildScalarXor(self: *Generator, w: *std.Io.Writer, pad: []const u8, name: []const u8, swift_type: []const u8, slot: schema.FieldSlot, dv: ?schema.Value, comptime set_meth: []const u8, comptime get_meth: []const u8) !void {
        const off = dataByteOffset(slot);
        const has_default = switch (dv orelse schema.Value{ .void = {} }) {
            .void => false,
            .bool => |v| v,
            .int8 => |v| v != 0,
            .int16 => |v| v != 0,
            .int32 => |v| v != 0,
            .int64 => |v| v != 0,
            .uint8 => |v| v != 0,
            .uint16 => |v| v != 0,
            .uint32 => |v| v != 0,
            .uint64 => |v| v != 0,
            .float32 => |v| @as(u32, @bitCast(v)) != 0,
            .float64 => |v| @as(u64, @bitCast(v)) != 0,
            .@"enum" => |v| v != 0,
            else => false,
        };
        const setter = try std.fmt.allocPrint(self.scratch(), set_meth ++ "(at: {d}, ", .{off});
        const getter = try std.fmt.allocPrint(self.scratch(), get_meth ++ "(at: {d})", .{off});
        if (!has_default) {
            try w.print("{s}public var {s}: {s} {{\n", .{ pad, name, swift_type });
            try w.print("{s}    get {{ root.{s} }}\n", .{ pad, getter });
            try w.print("{s}    set {{ root.{s}newValue) }}\n", .{ pad, setter });
            try w.print("{s}}}\n\n", .{pad});
            return;
        }
        try w.print("{s}public var {s}: {s} {{\n", .{ pad, name, swift_type });
        try w.print("{s}    get {{ ", .{pad});
        switch (dv.?) {
            .bool => |v| {
                if (v) {
                    try w.print(" !root.{s}", .{getter});
                } else {
                    try w.print(" root.{s}", .{getter});
                }
            },
            .float32 => |v| {
                const bits: u32 = @bitCast(v);
                try w.print(" Float32(bitPattern: root.readUInt32(at: {d}) ^ 0x{x})", .{ off, bits });
            },
            .float64 => |v| {
                const bits: u64 = @bitCast(v);
                try w.print(" Float64(bitPattern: root.readUInt64(at: {d}) ^ 0x{x})", .{ off, bits });
            },
            else => {
                const d: i128 = switch (dv.?) {
                    .int8 => |v| v,
                    .int16 => |v| v,
                    .int32 => |v| v,
                    .int64 => |v| v,
                    .uint8 => |v| v,
                    .uint16 => |v| v,
                    .uint32 => |v| v,
                    .uint64 => |v| v,
                    else => 0,
                };
                try w.print(" root.{s} ^ {d}", .{ getter, d });
            },
        }
        try w.print("\n{s}    }}\n", .{pad});
        try w.print("{s}    set {{ root.{s}", .{ pad, setter });
        switch (dv.?) {
            .bool => |v| {
                if (v) {
                    try w.print("!newValue)", .{});
                } else {
                    try w.print("newValue)", .{});
                }
            },
            .float32 => |v| {
                const bits: u32 = @bitCast(v);
                try w.print("Float32(bitPattern: newValue.bitPattern ^ 0x{x}))", .{bits});
            },
            .float64 => |v| {
                const bits: u64 = @bitCast(v);
                try w.print("Float64(bitPattern: newValue.bitPattern ^ 0x{x}))", .{bits});
            },
            else => {
                const d: i128 = switch (dv.?) {
                    .int8 => |v| v,
                    .int16 => |v| v,
                    .int32 => |v| v,
                    .int64 => |v| v,
                    .uint8 => |v| v,
                    .uint16 => |v| v,
                    .uint32 => |v| v,
                    .uint64 => |v| v,
                    else => 0,
                };
                try w.print("newValue ^ {d})", .{d});
            },
        }
        try w.print("{s}    }}\n", .{pad});
        try w.print("{s}}}\n\n", .{pad});
    }

    fn buildScalar(self: *Generator, w: *std.Io.Writer, pad: []const u8, name: []const u8, swift_type: []const u8, slot: schema.FieldSlot, comptime setter_fmt: []const u8, comptime getter_fmt: []const u8) !void {
        const off = dataByteOffset(slot);
        const setter = try std.fmt.allocPrint(self.scratch(), setter_fmt, .{off});
        const getter = try std.fmt.allocPrint(self.scratch(), getter_fmt, .{off});
        try w.print("{s}public var {s}: {s} {{\n", .{ pad, name, swift_type });
        try w.print("{s}    get {{ root.{s} }}\n", .{ pad, getter });
        try w.print("{s}    set {{ root.{s} }}\n", .{ pad, setter });
        try w.print("{s}}}\n\n", .{pad});
    }

    fn emitListBuilder(self: *Generator, w: *std.Io.Writer, pad: []const u8, name: []const u8, slot: schema.FieldSlot, element: *schema.Type) !void {
        const cap = try self.capitalized(name);
        switch (element.*) {
            .void, .interface => try w.print("{s}public func init{s}(_ count: Int) -> PointerListBuilderSlice {{ root.initTextList({d}, count: count) }}\n\n", .{ pad, cap, slot.offset }),
            .bool => try w.print("{s}public func init{s}(_ count: Int) -> BitListBuilder {{ root.initBoolList({d}, count: count) }}\n\n", .{ pad, cap, slot.offset }),
            .int8 => try self.buildList(w, pad, name, slot, "Int8"),
            .int16 => try self.buildList(w, pad, name, slot, "Int16"),
            .int32 => try self.buildList(w, pad, name, slot, "Int32"),
            .int64 => try self.buildList(w, pad, name, slot, "Int64"),
            .uint8 => try self.buildList(w, pad, name, slot, "UInt8"),
            .uint16 => try self.buildList(w, pad, name, slot, "UInt16"),
            .uint32 => try self.buildList(w, pad, name, slot, "UInt32"),
            .uint64 => try self.buildList(w, pad, name, slot, "UInt64"),
            .float32 => try w.print("{s}public func init{s}(_ count: Int) -> FixedSizeListBuilder<UInt32> {{ root.initFloat32List({d}, count: count) }}\n\n", .{ pad, cap, slot.offset }),
            .float64 => try w.print("{s}public func init{s}(_ count: Int) -> FixedSizeListBuilder<UInt64> {{ root.initFloat64List({d}, count: count) }}\n\n", .{ pad, cap, slot.offset }),
            .@"enum" => try self.buildList(w, pad, name, slot, "UInt16"),
            .text, .data, .any_pointer, .list => try w.print("{s}public func init{s}(_ count: Int) -> PointerListBuilderSlice {{ root.initTextList({d}, count: count) }}\n\n", .{ pad, cap, slot.offset }),
            .@"struct" => |s| {
                const target = self.getNode(s.type_id) orelse return error.MissingStructNode;
                const target_node = target.struct_node.?;
                try w.print("{s}public func init{s}(_ count: Int) -> StructListBuilder {{\n", .{ pad, cap });
                try w.print("{s}    root.initStructList({d}, dataWords: {d}, pointerWords: {d}, count: count)\n", .{ pad, slot.offset, target_node.data_word_count, target_node.pointer_count });
                try w.print("{s}}}\n\n", .{pad});
            },
        }
    }

    fn buildList(self: *Generator, w: *std.Io.Writer, pad: []const u8, name: []const u8, slot: schema.FieldSlot, swift_scalar: []const u8) !void {
        const cap = try self.capitalized(name);
        try w.print("{s}public func init{s}(_ count: Int) -> FixedSizeListBuilder<{s}> {{ root.initFixedSizeList({d}, count: count, as: {s}.self) }}\n\n", .{ pad, cap, swift_scalar, slot.offset, swift_scalar });
    }

    // ------------------------------------------------ names

    /// The type name for a node: the last path segment of its display name,
    /// escaped for Swift.
    /// The declaration name: the last display-name segment, escaped. A
    /// top-level node renamed for a cross-file collision keeps its new name.
    fn swiftTypeName(self: *Generator, node: *schema.Node) []const u8 {
        if (self.name_overrides.get(node.id)) |override| {
            return self.swiftIdentifierAlloc(override) catch "BadName";
        }
        return self.swiftIdentifierAlloc(lastSegment(node.display_name)) catch "BadName";
    }

    /// A type reference, qualified from the file root so it resolves from
    /// any scope in the generated file.
    fn swiftRef(self: *Generator, node: *schema.Node) []const u8 {
        return self.swiftQualifiedTypeName(node) catch "BadName";
    }

    /// The node's Swift name qualified from the file root (`Outer.Inner`),
    /// so references resolve from any scope in the generated file.
    /// The node's Swift name qualified from the file root (`Outer.Inner`),
    /// so references resolve from any scope in the generated file. Every
    /// piece is named as declared (collision renames included).
    fn swiftQualifiedTypeName(self: *Generator, node: *schema.Node) ![]const u8 {
        var prefix: []const u8 = "";
        if (self.current_file) |cur| {
            const ref_file = self.getFileNode(node.id) orelse cur;
            if (ref_file.id != cur.id and !self.requested_file_ids.contains(ref_file.id)) {
                prefix = self.moduleName(ref_file);
                var dup = false;
                for (self.referenced_modules.items) |m| {
                    if (std.mem.eql(u8, m, prefix)) dup = true;
                }
                if (!dup) self.referenced_modules.append(self.scratch(), prefix) catch {};
            }
        }
        var chain: [16]*schema.Node = undefined;
        var depth: usize = 0;
        var current: *schema.Node = node;
        while (true) {
            if (depth == chain.len) return error.ScopeTooDeep;
            if (current.kind == .file) break; // the file itself is not a scope
            chain[depth] = current;
            depth += 1;
            if (current.scope_id == 0) break;
            current = self.getNode(current.scope_id) orelse return error.MissingScopeNode;
        }
        var buf: std.ArrayList(u8) = .empty;
        if (prefix.len > 0) {
            try buf.appendSlice(self.scratch(), prefix);
            try buf.append(self.scratch(), '.');
        }
        var i: usize = depth;
        while (i > 0) {
            i -= 1;
            if (i + 1 != depth) try buf.append(self.scratch(), '.');
            try buf.appendSlice(self.scratch(), self.swiftTypeName(chain[i]));
        }
        return buf.toOwnedSlice(self.scratch());
    }

/// A lexical (declaration) child: its display name extends the parent's.
/// Brand applications name their application site instead, so they fail
/// this check (v1 erases brands).
fn lexicalChild(parent: *schema.Node, child: *schema.Node) bool {
    return child.display_name.len > parent.display_name.len + 1
        and std.mem.startsWith(u8, child.display_name, parent.display_name)
        and child.display_name[parent.display_name.len] == '.';
}

fn lastSegment(display_name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, display_name, ':')) |i| {
        return display_name[i + 1 ..];
    }
    return display_name;
}

    fn swiftMemberName(self: *Generator, name: []const u8) ![]const u8 {
        return self.swiftIdentifierAlloc(name);
    }

    fn fieldAccessorName(self: *Generator, parent: *schema.Node, field: schema.Field) ![]const u8 {
        var name = try self.swiftMemberName(field.name);
        // `which` collides with the generated union accessor.
        if (parent.struct_node != null and parent.struct_node.?.discriminant_count > 0 and std.mem.eql(u8, field.name, "which")) {
            name = try self.scratch().dupe(u8, "which_");
        }
        return name;
    }

    /// `foo` -> `fooSuffix`; an escaped name keeps the suffix inside the
    /// backticks (`` `any` + IsNull`` would parse as two identifiers).
    fn suffixedIdentifier(self: *Generator, name: []const u8, suffix: []const u8) ![]const u8 {
        if (name.len > 0 and name[0] == '`') {
            return std.fmt.allocPrint(self.scratch(), "`{s}{s}`", .{ name[1 .. name.len - 1], suffix });
        }
        return std.fmt.allocPrint(self.scratch(), "{s}{s}", .{ name, suffix });
    }

    fn lowerFirst(self: *Generator, name: []const u8) ![]const u8 {
        if (name.len == 0 or !std.ascii.isUpper(name[0])) return name;
        var buf: std.ArrayList(u8) = .empty;
        try buf.append(self.scratch(), std.ascii.toLower(name[0]));
        try buf.appendSlice(self.scratch(), name[1..]);
        return buf.toOwnedSlice(self.scratch());
    }

    fn groupTypeName(self: *Generator, field: schema.Field) ![]const u8 {
        return self.capitalized(try self.swiftMemberName(field.name));
    }

    fn staticDefaultName(self: *Generator, accessor: []const u8) ![]const u8 {
        const cap = try self.capitalized(accessor);
        return std.fmt.allocPrint(self.scratch(), "{s}Default", .{cap});
    }

    /// `fooBar` -> `FooBar`, unescaped (the result is a plain identifier;
    /// keyword-ness is re-checked when the final name is assembled).
    fn capitalized(self: *Generator, name: []const u8) ![]const u8 {
        if (name.len == 0) return name;
        const inner = if (name[0] == '`') name[1 .. name.len - 1] else name;
        if (inner.len == 0) return name;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.scratch());
        try buf.append(self.scratch(), std.ascii.toUpper(inner[0]));
        try buf.appendSlice(self.scratch(), inner[1..]);
        return buf.toOwnedSlice(self.scratch());
    }

    /// A plain (unescaped) base plus a suffix, escaped as a whole if the
    /// assembled name turns out to be a keyword.
    fn suffixed(self: *Generator, base: []const u8, suffix: []const u8) ![]const u8 {
        return self.swiftIdentifierAlloc(try std.fmt.allocPrint(self.scratch(), "{s}{s}", .{ base, suffix }));
    }

    fn unescaped(self: *Generator, name: []const u8) []const u8 {
        _ = self;
        if (name.len > 1 and name[0] == '`') return name[1 .. name.len - 1];
        return name;
    }

    fn swiftIdentifierAlloc(self: *Generator, name: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.scratch());
        for (name) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                try buf.append(self.scratch(), c);
            } else {
                try buf.append(self.scratch(), '_');
            }
        }
        if (buf.items.len == 0 or std.ascii.isDigit(buf.items[0])) {
            try buf.insert(self.scratch(), 0, '_');
        }
        if (isSwiftKeyword(buf.items)) {
            var escaped: std.ArrayList(u8) = .empty;
            errdefer escaped.deinit(self.scratch());
            try escaped.append(self.scratch(), '`');
            try escaped.appendSlice(self.scratch(), buf.items);
            try escaped.append(self.scratch(), '`');
            return escaped.toOwnedSlice(self.scratch());
        }
        return buf.toOwnedSlice(self.scratch());
    }

    fn swiftStringLiteral(self: *Generator, text: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.scratch());
        try buf.append(self.scratch(), '"');
        for (text) |c| {
            switch (c) {
                '"' => try buf.appendSlice(self.scratch(), "\\\""),
                '\\' => try buf.appendSlice(self.scratch(), "\\\\"),
                '\n' => try buf.appendSlice(self.scratch(), "\\n"),
                '\r' => try buf.appendSlice(self.scratch(), "\\r"),
                '\t' => try buf.appendSlice(self.scratch(), "\\t"),
                else => {
                    if (c < 0x20 or c == 0x7f) {
                        var hex: [16]u8 = undefined;
                        const digits = std.fmt.bufPrint(&hex, "{x}", .{c}) catch "0";
                        try buf.appendSlice(self.scratch(), "\\u{");
                        try buf.appendSlice(self.scratch(), digits);
                        try buf.append(self.scratch(), '}');
                    } else {
                        try buf.append(self.scratch(), c);
                    }
                },
            }
        }
        try buf.append(self.scratch(), '"');
        return buf.toOwnedSlice(self.scratch());
    }

    fn swiftByteArrayLiteral(self: *Generator, bytes: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.scratch());
        try buf.appendSlice(self.scratch(), "[UInt8]([");
        for (bytes, 0..) |b, i| {
            if (i > 0) try buf.appendSlice(self.scratch(), ", ");
            var hex: [4]u8 = undefined;
            const digits = std.fmt.bufPrint(&hex, "{x}", .{b}) catch "0";
            try buf.appendSlice(self.scratch(), "0x");
            try buf.appendSlice(self.scratch(), digits);
        }
        try buf.appendSlice(self.scratch(), "])");
        return buf.toOwnedSlice(self.scratch());
    }
};

fn indentation(level: usize) []const u8 {
    // Callers cap recursion well below this; the clamp only bounds padding.
    const spaces = "                                ";
    const clamped: usize = if (level > 8) 8 else level;
    return spaces[0 .. clamped * 4];
}

const swift_keywords = std.StaticStringMap(void).initComptime(.{
    .{"associatedtype"}, .{"class"},      .{"deinit"},        .{"enum"},          .{"extension"},
    .{"fileprivate"},     .{"func"},      .{"import"},        .{"init"},          .{"inout"},
    .{"internal"},        .{"let"},       .{"open"},          .{"operator"},      .{"private"},
    .{"precedencegroup"}, .{"protocol"},  .{"public"},        .{"rethrows"},      .{"static"},
    .{"struct"},          .{"subscript"}, .{"typealias"},     .{"var"},           .{"where"},
    .{"actor"},           .{"any"},       .{"as"},            .{"await"},         .{"async"},
    .{"break"},           .{"case"},      .{"catch"},         .{"continue"},      .{"default"},
    .{"defer"},           .{"do"},        .{"else"},          .{"fallthrough"},   .{"false"},
    .{"for"},             .{"guard"},     .{"if"},            .{"in"},            .{"is"},
    .{"nil"},             .{"repeat"},    .{"return"},        .{"self"},          .{"Self"},
    .{"super"},           .{"switch"},    .{"throw"},         .{"throws"},        .{"true"},
    .{"try"},             .{"while"},     .{"some"},          .{"each"},          .{"package"},
    .{"lazy"},            .{"weak"},      .{"unowned"},       .{"mutating"},      .{"override"},
    .{"final"},           .{"required"},  .{"convenience"},   .{"borrowing"},     .{"consuming"},
    .{"copying"},         .{"macro"},     .{"nonisolated"},   .{"distributed"},   .{"sending"},
});

fn isSwiftKeyword(name: []const u8) bool {
    return swift_keywords.has(name);
}

test "node map resolves nested nodes by id" {
    const a = std.testing.allocator;
    var no_nested = [_]schema.Node.NestedNode{};
    var no_annotations = [_]schema.AnnotationUse{};
    var file_nested = [_]schema.Node.NestedNode{.{ .name = "Greeter", .id = 2 }};
    const file_node = schema.Node{
        .id = 1,
        .display_name = "/x/mvp.capnp",
        .display_name_prefix_length = 3,
        .scope_id = 0,
        .nested_nodes = file_nested[0..],
        .annotations = no_annotations[0..],
        .kind = .file,
        .struct_node = null,
        .enum_node = null,
        .interface_node = null,
        .const_node = null,
        .annotation_node = null,
    };
    const greeter = schema.Node{
        .id = 2,
        .display_name = "/x/mvp.capnp:Greeter",
        .display_name_prefix_length = 3,
        .scope_id = 1,
        .nested_nodes = no_nested[0..],
        .annotations = no_annotations[0..],
        .kind = .interface,
        .struct_node = null,
        .enum_node = null,
        .interface_node = null,
        .const_node = null,
        .annotation_node = null,
    };
    var nodes = [_]schema.Node{ file_node, greeter };
    var gen = try Generator.init(a, nodes[0..]);
    defer gen.deinit();
    try std.testing.expectEqual(@as(u64, 2), gen.getNode(2).?.id);
    try std.testing.expectEqual(@as(u64, 1), gen.getFileNode(2).?.id);
    try std.testing.expect(@as(?*schema.Node, null) == gen.getNode(7));
}

test "swift identifier escaping" {
    const a = std.testing.allocator;
    var gen = try Generator.init(a, &.{});
    defer gen.deinit();
    const kw = try gen.swiftMemberName("class");
    try std.testing.expectEqualStrings("`class`", kw);
    const plain = try gen.swiftMemberName("fooBar2");
    try std.testing.expectEqualStrings("fooBar2", plain);
    const digit = try gen.swiftMemberName("9lives");
    try std.testing.expectEqualStrings("_9lives", digit);
}
