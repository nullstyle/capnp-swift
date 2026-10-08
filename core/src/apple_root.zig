//! Root module of the Apple static library (`libcapnp_core.a` in
//! CapnpCore.xcframework). It owns the process-level std overrides a library
//! linked into someone else's app must make, and re-exports `abi.zig`.
//!
//! Why each override exists:
//! - `panic`: the default std panic handler prints a trace through
//!   `std.Options.debug_io`, which defaults to `std.Io.Threaded`. On iOS that
//!   does not compile at Zig 0.17.0 (`Io/Threaded.zig:15486`, NullFile has no
//!   `fd`; plan §1.1, handoff H2), and on macOS it adds ~2 MB and a stderr
//!   writer to a host app. Ours calls the host's panic hook, then traps.
//! - `std_options_debug_io = std.Io.failing`: nothing in std.debug may reach
//!   `Io.Threaded` through the debug Io either.
//! - `std_options_debug_threaded_io = null`: no static `Io.Threaded` singleton.
//! - `logFn`: a library writes nothing to the app's stderr.
//! - `enable_segfault_handler = false`, `signal_stack_size = null`: the core
//!   never installs signal handlers or alternate signal stacks in a host
//!   process (the app and its crash reporter own those).
//! - `allocator`: the C allocator (malloc), not `page_allocator` (one mmap
//!   per allocation). Code in the core takes its allocator from here.

const std = @import("std");
const build_info = @import("build_info");

// The shim lives upstream since capnp-zig v0.23.0 (handoff H7): the
// Experimental `native` module in the package. Referencing `native.abi`
// from this root is what emits the `capnp_*` symbols into the archive.
const core = @import("capnpc-zig-core");
pub const abi = core.native.abi;

comptime {
    // Analyze abi so its `export fn`s land in the archive.
    _ = abi;
}

/// The allocator every core object uses on Apple platforms.
pub const allocator: std.mem.Allocator = std.heap.c_allocator;
/// What `abi.zig` reads (`@import("root").capnp_core_allocator`).
pub const capnp_core_allocator: std.mem.Allocator = allocator;

/// What `abi.zig` reads (`@import("root").capnp_core_version_string`):
/// core <version> / capnp-zig <pin version> / <pin hash>, both from
/// build.zig.zon (release.md "Version bookkeeping" bumps these together).
pub const capnp_core_version_string: [:0]const u8 =
    "core " ++ build_info.core_version ++
    " / capnp-zig " ++ build_info.capnp_zig_version ++
    " / " ++ build_info.capnp_zig_hash;

pub const panic = std.debug.FullPanic(corePanic);

fn corePanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    abi.runPanicHook(msg);
    @trap();
}

pub const std_options: std.Options = .{
    .logFn = noopLog,
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

pub const std_options_debug_io: std.Io = std.Io.failing;
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;

fn noopLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}
