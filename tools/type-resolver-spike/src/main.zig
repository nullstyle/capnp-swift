//! Optional concrete Swift specialization experiment, not the shipping plugin.
const std = @import("std");
const capnp = @import("capnp");
const specialization = @import("specialization.zig");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingRequest;
    const suffix = args.next() orelse return error.MissingRoot;
    const option = args.next();
    const profiles = if (option) |flag| blk: {
        if (!std.mem.eql(u8, flag, "--methods")) return error.UnexpectedArgument;
        const profile_path = args.next() orelse return error.MissingMethodProfiles;
        break :blk try std.Io.Dir.cwd().readFileAlloc(init.io, profile_path, init.gpa, .limited(1024 * 1024));
    } else null;
    defer if (profiles) |json| init.gpa.free(json);
    if (args.next() != null) return error.UnexpectedArgument;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(bytes);
    const request = try capnp.request.parseCodeGeneratorRequest(init.gpa, bytes);
    defer capnp.request.freeCodeGeneratorRequest(init.gpa, request);
    var root: ?capnp.schema.Id = null;
    for (request.nodes) |node| {
        if (!std.mem.endsWith(u8, node.display_name, suffix)) continue;
        if (root != null) return error.AmbiguousRoot;
        root = node.id;
    }
    const source = try specialization.generateMethods(init.gpa, request.nodes, root orelse return error.MissingNode, .{}, profiles);
    defer init.gpa.free(source);
    // Generate completely before writing, so a rejected graph produces no code.
    try std.Io.File.stdout().writeStreamingAll(init.io, source);
}
