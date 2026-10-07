//! zig-peer: the capnp-zig side of the M1 e2e (interop/schemas/mvp.capnp).
//!
//! Serves `Greeter` over TCP with capnp-zig's Stable `ServerSession.accept`:
//!   - greet(name, listener) replies "Hello, <name>!" and, before it replies,
//!     calls listener.notify("greeted <name>") (a server -> Swift call on a
//!     capability the Swift client passed in the params);
//!   - greet("") fails with the exception reason "EmptyName" (the handler
//!     returns `error.EmptyName`; capnp-zig sends `@errorName`).
//!
//! `--port 0` picks an ephemeral port; the bound port is printed to stdout
//! as `port=<n>` so the Swift e2e client can find it. The process serves
//! connections one after another until it is killed.

const std = @import("std");
const capnpc = @import("capnpc-zig");
const mvp = @import("mvp");

const rpc = capnpc.rpc;
const Peer = rpc.peer.Peer;

const Args = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
};

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !Args {
    var out = Args{};
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            const v = it.next() orelse return error.MissingArgValue;
            out.host = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--port")) {
            const v = it.next() orelse return error.MissingArgValue;
            out.port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else {
            std.debug.print("zig-peer: unknown argument {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Greeter
// ---------------------------------------------------------------------------

/// Per-notify state: freed when the notify Return arrives.
const NotifyCtx = struct {
    allocator: std.mem.Allocator,
    listener: mvp.Listener.Client,
    text: []const u8,
};

fn handleGreet(
    _: *anyopaque,
    peer: *Peer,
    params: mvp.Greeter.Greet.Params.Reader,
    results: *mvp.Greeter.Greet.Results.Builder,
    caps: *const rpc.caps.table.InboundCapTable,
) anyerror!void {
    const name = try params.getName();
    if (name.len == 0) return error.EmptyName;

    // The Listener the client passed: an import we hold until its notify
    // returns (then `release` sends Release, and Swift drops its export).
    const listener = try params.resolveListener(peer, caps);
    var released = false;
    errdefer if (!released) listener.release();

    const ctx = try peer.allocator.create(NotifyCtx);
    errdefer peer.allocator.destroy(ctx);
    const text = try std.fmt.allocPrint(peer.allocator, "greeted {s}", .{name});
    errdefer peer.allocator.free(text);
    ctx.* = .{ .allocator = peer.allocator, .listener = listener, .text = text };
    _ = try listener.callNotify(ctx, buildNotify, onNotifyReturn);
    released = true; // onNotifyReturn owns the listener now

    var buf: [512]u8 = undefined;
    const reply = std.fmt.bufPrint(&buf, "Hello, {s}!", .{name}) catch return error.NameTooLong;
    try results.setReply(reply);
    std.debug.print("zig-peer: greet({s})\n", .{name});
}

fn buildNotify(ctx_ptr: *anyopaque, params: *mvp.Listener.Notify.Params.Builder) anyerror!void {
    const ctx: *NotifyCtx = @ptrCast(@alignCast(ctx_ptr));
    try params.setMsg(ctx.text);
}

fn onNotifyReturn(
    ctx_ptr: *anyopaque,
    _: *Peer,
    response: mvp.Listener.Notify.Response,
    _: *const rpc.caps.table.InboundCapTable,
) anyerror!void {
    const ctx: *NotifyCtx = @ptrCast(@alignCast(ctx_ptr));
    defer {
        ctx.allocator.free(ctx.text);
        ctx.allocator.destroy(ctx);
    }
    defer ctx.listener.release();
    _ = response.unwrap() catch |err| {
        std.debug.print("zig-peer: notify failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("zig-peer: notify returned\n", .{});
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

fn usage() void {
    std.debug.print("usage: zig-peer [--host 127.0.0.1] [--port 0]\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const io = init.io;

    const args = parseArgs(allocator, init.minimal.args) catch |err| switch (err) {
        error.HelpRequested => {
            usage();
            return;
        },
        else => {
            usage();
            return err;
        },
    };

    const address = try std.Io.net.IpAddress.parse(args.host, args.port);
    var listener = try rpc.transport.tcp.Listener.init(allocator, io, address, .{});
    defer listener.close();

    // Tell the client where we are.
    var stdout_buf: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("port={d}\n", .{listener.getAddress().getPort()});
    try stdout.interface.flush();
    std.debug.print("zig-peer: listening on {s}:{d}\n", .{ args.host, listener.getAddress().getPort() });

    var impl: u8 = 0;
    var server = mvp.Greeter.Server{
        .ctx = &impl,
        .vtable = .{ .greet = handleGreet },
    };

    while (true) {
        const session = rpc.transport.tcp.ServerSession.accept(allocator, &listener, .{}) catch |err| switch (err) {
            error.ListenerClosed => break,
            else => {
                std.debug.print("zig-peer: accept failed: {s}\n", .{@errorName(err)});
                return err;
            },
        };
        defer session.deinit();
        std.debug.print("zig-peer: connection accepted\n", .{});
        _ = mvp.Greeter.setBootstrap(&session.peer, &server) catch |err| {
            std.debug.print("zig-peer: setBootstrap failed: {s}\n", .{@errorName(err)});
            continue;
        };
        session.run();
        std.debug.print("zig-peer: connection closed\n", .{});
    }
}
