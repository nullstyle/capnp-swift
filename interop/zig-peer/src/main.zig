//! zig-peer: the capnp-zig side of the M1 e2e (interop/schemas/mvp.capnp),
//! plus the M6 QUIC lanes (plan §8 M6; Experimental — QUIC is Experimental
//! in capnp-zig too).
//!
//! `--transport tcp` (default) serves `Greeter` over TCP with capnp-zig's
//! Stable `ServerSession.accept`:
//!   - greet(name, listener) replies "Hello, <name>!" and, before it replies,
//!     calls listener.notify("greeted <name>") (a server -> Swift call on a
//!     capability the Swift client passed in the params);
//!   - greet("") fails with the exception reason "EmptyName" (the handler
//!     returns `error.EmptyName`; capnp-zig sends `@errorName`).
//!
//! `--port 0` picks an ephemeral port; the bound port is printed to stdout
//! as `port=<n>` so the Swift e2e client can find it. The process serves
//! connections one after another until it is killed.
//!
//! `--transport quic --cert-pem <f> --key-pem <f>` serves the same Greeter
//! over the M6 baseline wire (ALPN "capnp-rpc/1", stream 0, u32 LE frames)
//! through capnp-zig's `rpc.transport.quic.PeerServer`; the idle timeout is
//! 120 s so the 90 s idle gate fits. Each session close prints
//! `close_cause=<name>` on stderr (the close-code-0 gate reads it).
//!
//! `--client --transport quic --host H --port P` is the Zig->Swift lane: it
//! dials a Swift QUICListener serving Greeter, bootstraps, calls
//! greet("Zig") passing a Zig-served `Listener`, and prints TAP
//! (`1..3`, `ok - ...`) for bootstrap / greet reply / the notify callback.
//! Exit 0 only if every line is ok. TLS verification mirrors capnp-zig's
//! own loopback tests: `insecure_skip_verify` with the self-signed fixture
//! (pass `--ca-pem` to verify instead).

const std = @import("std");
const capnpc = @import("capnpc-zig");
const mvp = @import("mvp");

const rpc = capnpc.rpc;
const Peer = rpc.peer.Peer;
const quic = rpc.transport.quic;

comptime {
    if (!quic.enabled) @compileError("zig-peer needs the -Dquic=true package root");
}

const Args = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
    transport: enum { tcp, quic } = .tcp,
    client: bool = false,
    cert_pem: ?[]const u8 = null,
    key_pem: ?[]const u8 = null,
    ca_pem: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, arg, "--transport")) {
            const v = it.next() orelse return error.MissingArgValue;
            if (std.mem.eql(u8, v, "tcp")) {
                out.transport = .tcp;
            } else if (std.mem.eql(u8, v, "quic")) {
                out.transport = .quic;
            } else return error.UnknownArgument;
        } else if (std.mem.eql(u8, arg, "--client")) {
            out.client = true;
        } else if (std.mem.eql(u8, arg, "--cert-pem")) {
            const v = it.next() orelse return error.MissingArgValue;
            out.cert_pem = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--key-pem")) {
            const v = it.next() orelse return error.MissingArgValue;
            out.key_pem = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--ca-pem")) {
            const v = it.next() orelse return error.MissingArgValue;
            out.ca_pem = try allocator.dupe(u8, v);
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
    std.debug.print(
        "usage: zig-peer [--host 127.0.0.1] [--port 0] [--transport tcp|quic]\n" ++
            "                [--cert-pem F --key-pem F]   (quic server)\n" ++
            "                [--client [--ca-pem F]]       (quic client: Zig->Swift)\n",
        .{},
    );
}

var chunk_buffer: [8192]u8 = undefined;

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &chunk_buffer);
    const data = try reader.interface.allocRemaining(allocator, .unlimited);
    if (data.len > 1 << 20) {
        allocator.free(data);
        return error.TooLarge;
    }
    return @constCast(data);
}

// Long enough for the 90 s idle gate (plan §8 M6).
const idle_ms: u64 = 120_000;

fn idleTransportParams() @TypeOf(quic.defaultTransportParams()) {
    var params = quic.defaultTransportParams();
    params.max_idle_timeout_ms = idle_ms;
    return params;
}

// ---------------------------------------------------------------------------
// QUIC server (Swift -> Zig)
// ---------------------------------------------------------------------------

/// One Greeter for every session; the PeerServer frees sessions, not this.
var quic_server: mvp.Greeter.Server = undefined;
var quic_server_impl: u8 = 0;

fn onQuicAccept(_: ?*anyopaque, session: *quic.PeerServer.Session) anyerror!void {
    quic_server = .{
        .ctx = &quic_server_impl,
        .vtable = .{ .greet = handleGreet },
    };
    _ = try mvp.Greeter.setBootstrap(&session.peer, &quic_server);
}

fn onQuicClose(_: ?*anyopaque, session: *quic.PeerServer.Session) void {
    std.debug.print("zig-peer: quic session closed close_cause={s}\n", .{@tagName(session.closeCause())});
}

fn runQuicServer(allocator: std.mem.Allocator, io: std.Io, args: Args) !void {
    const cert_pem = try readFileAlloc(allocator, io, args.cert_pem orelse return error.MissingCertPem);
    defer allocator.free(cert_pem);
    const key_pem = try readFileAlloc(allocator, io, args.key_pem orelse return error.MissingKeyPem);
    defer allocator.free(key_pem);

    const address = try std.Io.net.IpAddress.parse(args.host, args.port);
    var server_options = quic.ServerOptions{
        .listen_addr = address,
        .tls_cert_pem = cert_pem,
        .tls_key_pem = key_pem,
        .max_concurrent_connections = 8,
    };
    server_options.transport_params = idleTransportParams();

    const server = try quic.PeerServer.init(allocator, io, server_options, .{
        .on_accept = onQuicAccept,
        .on_close = onQuicClose,
    });
    defer server.deinit();

    var stdout_buf: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("port={d}\n", .{server.getAddress().getPort()});
    try stdout.interface.flush();
    std.debug.print("zig-peer: quic listening on {s}:{d}\n", .{ args.host, server.getAddress().getPort() });

    server.run();
}

// ---------------------------------------------------------------------------
// QUIC client (Zig -> Swift)
// ---------------------------------------------------------------------------

/// Written only on the session's run thread; the main thread reads after
/// `done.load(.acquire)`, which orders every field below it (notify always
/// precedes the greet return on this protocol).
const ClientState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    greeter: ?mvp.Greeter.Client = null,
    greet_reply: ?[]const u8 = null,
    greet_error: ?[]const u8 = null,
    notified: ?[]const u8 = null,
    listener_server: mvp.Listener.Server = undefined,
    listener_impl: u8 = 0,
};

var client_state: ClientState = .{};

fn handleNotify(
    _: *anyopaque,
    _: *Peer,
    params: mvp.Listener.Notify.Params.Reader,
    results: *mvp.Listener.Notify.Results.Builder,
    _: *const rpc.caps.table.InboundCapTable,
) anyerror!void {
    const msg = try params.getMsg();
    if (client_state.notified) |old| std.heap.c_allocator.free(@constCast(old));
    client_state.notified = try std.heap.c_allocator.dupe(u8, msg);
    _ = results;
    std.debug.print("zig-peer: notify({s})\n", .{msg});
}

fn buildGreet(_: *anyopaque, params: *mvp.Greeter.Greet.Params.Builder) anyerror!void {
    try params.setName("Zig");
    try params.setListenerServer(undefined_peer_hack.?, &client_state.listener_server);
}

// setListenerServer needs the peer; the bootstrap callback has it.
var undefined_peer_hack: ?*Peer = null;

fn onGreetReturn(
    _: *anyopaque,
    _: *Peer,
    response: mvp.Greeter.Greet.Response,
    _: *const rpc.caps.table.InboundCapTable,
) anyerror!void {
    switch (response) {
        .results => |reader_ptr| {
            const reply = reader_ptr.getReply() catch "";
            client_state.greet_reply = std.heap.c_allocator.dupe(u8, reply) catch null;
        },
        .exception => |exc| {
            client_state.greet_error = std.heap.c_allocator.dupe(u8, exc.reason) catch null;
        },
        .canceled => client_state.greet_error = "canceled",
        .results_sent_elsewhere,
        .take_from_other_question,
        .accept_from_third_party,
        => client_state.greet_error = "unexpected return shape",
    }
    client_state.done.store(true, .release);
}

fn onBootstrap(
    _: *anyopaque,
    peer: *Peer,
    response: mvp.Greeter.BootstrapResponse,
) anyerror!void {
    const client = try response.unwrap();
    client_state.greeter = client;
    client_state.listener_server = .{
        .ctx = &client_state.listener_impl,
        .vtable = .{ .notify = handleNotify },
    };
    undefined_peer_hack = peer;
    _ = try client.callGreet(undefined, buildGreet, onGreetReturn);
}

fn runQuicClient(allocator: std.mem.Allocator, io: std.Io, args: Args) !void {
    const address = try std.Io.net.IpAddress.parse(args.host, args.port);
    var conn_options = quic.ClientOptions{
        .remote_addr = address,
        .server_name = "localhost",
        // Mirrors capnp-zig's own loopback tests: self-signed fixture,
        // no chain to verify (pass --ca-pem for real verification).
        .insecure_skip_verify = args.ca_pem == null,
    };
    if (args.ca_pem) |path| conn_options.ca_pem = try readFileAlloc(allocator, io, path);
    conn_options.transport_params = idleTransportParams();

    // Hand-wired like capnp-zig's own bench (bench/quic_round_trip.zig):
    // Connection + Peer with thread affinity disabled BEFORE start, so the
    // main thread can drive questions while run() pumps on its own thread.
    // (ClientSession.connect cannot be used here: it peer.start()s on the
    // calling thread and the peer stays affine to it.)
    var conn = try quic.Connection.initClient(allocator, io, conn_options);
    defer conn.deinit();
    var peer = Peer.init(allocator, &conn);
    defer peer.deinit();
    peer.disableThreadAffinity();
    peer.setClockIo(io);
    peer.start(null, null, null);

    const run_thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *quic.Connection) void {
            c.run();
        }
    }.run, .{&conn});
    var have_run_thread = true;
    defer if (have_run_thread) run_thread.join();

    _ = try mvp.Greeter.Client.fromBootstrap(&peer, undefined, onBootstrap);

    // The greet return (or a hang) ends the wait; the caller's timeout is
    // the process being killed by the harness.
    while (!client_state.done.load(.acquire)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch break;
    }
    conn.requestClose();
    run_thread.join();
    have_run_thread = false;

    var passed: usize = 0;
    const total = 3;
    std.debug.print("1..{d}\n", .{total});
    const have_greeter = client_state.greeter != null;
    const reply = client_state.greet_reply;
    const notified = client_state.notified;
    if (have_greeter) {
        passed += 1;
        std.debug.print("ok - bootstrap\n", .{});
    } else std.debug.print("not ok - bootstrap\n", .{});
    if (reply) |r| {
        if (std.mem.eql(u8, r, "Hello, Zig!")) {
            passed += 1;
            std.debug.print("ok - greet reply\n", .{});
        } else std.debug.print("not ok - greet reply ({s})\n", .{r});
    } else std.debug.print("not ok - greet reply (error: {s})\n", .{client_state.greet_error orelse "none"});
    if (notified) |n| {
        if (std.mem.eql(u8, n, "greeted Zig")) {
            passed += 1;
            std.debug.print("ok - notify callback\n", .{});
        } else std.debug.print("not ok - notify callback ({s})\n", .{n});
    } else std.debug.print("not ok - notify callback\n", .{});
    if (passed != total) return error.ClientChecksFailed;
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

    if (args.client) {
        if (args.transport != .quic) return error.ClientNeedsQuic;
        return runQuicClient(allocator, io, args);
    }
    if (args.transport == .quic) return runQuicServer(allocator, io, args);

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
