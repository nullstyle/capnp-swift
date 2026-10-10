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
    const source = try specialization.generate(init.gpa, request.nodes, root orelse return error.MissingNode, .{});
    defer init.gpa.free(source);
    // Generate completely before writing, so a rejected graph produces no code.
    try std.Io.File.stdout().writeStreamingAll(init.io, source);
}
