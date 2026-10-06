//! The capnp-swift C ABI (`core/include/capnp_core.h`, Clang module `CapnpCore`).
//!
//! Every symbol here is `pub export fn capnp_*` with the C calling convention.
//! `pub` is load-bearing: the header-drift test at the bottom of this file
//! walks the public decls to find the exports, so a non-`pub` export would
//! escape it.
//!
//! Rules (plan §4.1): inputs are borrowed for the call; no mutable globals
//! except the process-wide panic hook below; the core never calls into Swift
//! except through that hook.
//!
//! M0 surface: version/feature queries, the panic hook, and two test hooks
//! (`capnp_core_debug_trap`, `capnp_core_debug_selftest`).

const std = @import("std");
const build_info = @import("build_info");
const selftest = @import("selftest.zig");

/// Must equal `CAPNP_CORE_ABI_VERSION` in `capnp_core.h` (checked by a test).
pub const abi_version: u32 = 1;

/// Feature bits reported by `capnp_core_features()`. None are defined in M0.
pub const features: u64 = 0;

/// "core <core version> / capnp-zig <pinned version>". Both halves come from
/// `core/build.zig.zon` at build time, so bumping the pin updates the string.
pub const version_string: [:0]const u8 = "core " ++ build_info.core_version ++
    " / capnp-zig " ++ build_info.capnp_zig_version;

/// Host panic hook: `void (*)(const char *msg, size_t len)`. `msg` is not
/// NUL-terminated and is valid only during the call. The hook must not call
/// back into the core; after it returns the core executes `@trap`.
pub const PanicHook = *const fn (msg: [*]const u8, len: usize) callconv(.c) void;

/// The one deliberate mutable global (plan §4.1): a panic is process-wide.
var panic_hook: std.atomic.Value(?PanicHook) = .init(null);

/// Called by the root panic handler (`apple_root.zig`) before it traps.
pub fn runPanicHook(msg: []const u8) void {
    if (panic_hook.load(.acquire)) |hook| hook(msg.ptr, msg.len);
}

// ---------------------------------------------------------------------------
// Version and features
// ---------------------------------------------------------------------------

pub export fn capnp_core_abi_version() callconv(.c) u32 {
    return abi_version;
}

pub export fn capnp_core_features() callconv(.c) u64 {
    return features;
}

/// Static, NUL-terminated; never freed.
pub export fn capnp_core_version() callconv(.c) [*:0]const u8 {
    return version_string.ptr;
}

// ---------------------------------------------------------------------------
// Panic hook
// ---------------------------------------------------------------------------

/// Installs (or, with null, clears) the host panic hook. Any thread.
pub export fn capnp_core_set_panic_hook(hook: ?PanicHook) callconv(.c) void {
    panic_hook.store(hook, .release);
}

// ---------------------------------------------------------------------------
// TEST HOOK -- not part of the supported API.
// ---------------------------------------------------------------------------

/// TEST HOOK ONLY. Executes `@trap` inside `debugTrapFrame` below so
/// `scripts/check-dsym.sh` can prove a trapping Zig frame symbolicates to
/// `core/src/abi.zig:<line>` from an app's dSYM. It does not run the panic
/// hook (a trap is not a panic). Never call it from production code.
pub export fn capnp_core_debug_trap() callconv(.c) noreturn {
    debugTrapFrame();
}

/// The frame `check-dsym.sh` expects to see. `noinline` keeps it a real frame
/// in every optimize mode; the script greps this file for the marker below to
/// learn the expected line, so the two cannot drift.
noinline fn debugTrapFrame() noreturn {
    @trap(); // CAPNP_CORE_DEBUG_TRAP_LINE
}

/// TEST HOOK ONLY. Runs `selftest.zig` (a bootstrap + call round trip between
/// two in-process connections) with the C allocator. Returns 0 on success;
/// otherwise -1 and, when `failure` is non-null, stores the static,
/// NUL-terminated error name there.
///
/// Until M1 adds the `capnp_conn_*` exports, this is also what keeps
/// `conn.zig` and the capnp-zig Peer linked into the XCFramework slices.
pub export fn capnp_core_debug_selftest(failure: ?*?[*:0]const u8) callconv(.c) i32 {
    if (failure) |f| f.* = null;
    selftest.run(std.heap.c_allocator) catch |err| {
        if (failure) |f| f.* = @errorName(err);
        return -1;
    };
    return 0;
}

// ---------------------------------------------------------------------------
// Connection exports (capnp_conn_*, capnp_bootstrap, capnp_call, ...): M1.
//
// Add them here, following plan §4 (C ABI v1) and §4.1 (core rules):
//   - declare each as `pub export fn capnp_...(...) callconv(.c)` and add the
//     prototype to `core/include/capnp_core.h` (the drift test below fails
//     otherwise);
//   - keep the logic in `conn.zig` (Zig API, tested by `conn_test.zig` in
//     `zig build test`); this file stays a thin C-type adapter;
//   - conn.zig takes an allocator; exports pass `std.heap.c_allocator`
//     (apple_root.zig's `allocator`), tests pass `std.testing.allocator`;
//   - keep the ordinals effects.zig already uses: CapKind none/import/
//     export/promised = 0..3; ReturnKind results/exception/canceled/
//     disconnected = 0..3; effect Kind out_frame/close_requested/return/
//     inbound_call/export_dropped/event = 0..5;
//   - map Zig errors to CAPNP_E_*: Busy -> BUSY; Closed -> CLOSED; BadId,
//     BadCapId, CapIndexOutOfRange -> BAD_ID; Protocol -> PROTOCOL;
//     Unsupported, UnsupportedCapKind, Invalid -> INVAL; OutOfMemory -> NOMEM;
//   - import capnp-zig as "capnpc-zig" (its core module; see build.zig);
//   - every new undefined libSystem symbol must be reviewed into
//     `scripts/symbols-allowlist.txt` (`scripts/check-symbols.sh`).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    // selftest.zig's leak-checked run (testing.allocator).
    _ = selftest;
}

test "debug selftest export: 0 and no failure name" {
    var failure: ?[*:0]const u8 = "unset";
    try testing.expectEqual(@as(i32, 0), capnp_core_debug_selftest(&failure));
    try testing.expect(failure == null);
    try testing.expectEqual(@as(i32, 0), capnp_core_debug_selftest(null));
}

test "abi version, features and version string" {
    try testing.expectEqual(@as(u32, 1), capnp_core_abi_version());
    try testing.expectEqual(@as(u64, 0), capnp_core_features());
    const v = std.mem.span(capnp_core_version());
    try testing.expectEqualStrings("core 0.0.1 / capnp-zig 0.20.0", v);
    // The pinned version is derived from the zon hash; it must look like one.
    try testing.expect(std.mem.startsWith(u8, build_info.capnp_zig_hash, "capnpc_zig-" ++ build_info.capnp_zig_version ++ "-"));
}

var test_hook_calls: usize = 0;
var test_hook_buf: [64]u8 = undefined;
var test_hook_len: usize = 0;

fn testHook(msg: [*]const u8, len: usize) callconv(.c) void {
    test_hook_calls += 1;
    test_hook_len = @min(len, test_hook_buf.len);
    @memcpy(test_hook_buf[0..test_hook_len], msg[0..test_hook_len]);
}

test "panic hook: set, run, clear" {
    defer capnp_core_set_panic_hook(null);
    test_hook_calls = 0;

    runPanicHook("no hook installed");
    try testing.expectEqual(@as(usize, 0), test_hook_calls);

    capnp_core_set_panic_hook(&testHook);
    runPanicHook("index out of bounds");
    try testing.expectEqual(@as(usize, 1), test_hook_calls);
    try testing.expectEqualStrings("index out of bounds", test_hook_buf[0..test_hook_len]);

    capnp_core_set_panic_hook(null);
    runPanicHook("cleared");
    try testing.expectEqual(@as(usize, 1), test_hook_calls);
}

// Header-drift gate: every `pub export fn capnp_*` here has a prototype in
// `capnp_core.h` with the same arity and scalar widths (via translate-c), and
// every function the header declares exists here. The header's
// `CAPNP_CORE_ABI_VERSION` must equal `abi_version`.
test "capnp_core.h matches the Zig exports" {
    const c = @import("capnp_core_h");
    const this = @This();

    try testing.expectEqual(abi_version, @as(u32, c.CAPNP_CORE_ABI_VERSION));

    var zig_names: [256][]const u8 = undefined;
    var n_zig: usize = 0;
    inline for (@typeInfo(this).@"struct".decl_names) |name| {
        if (comptime !std.mem.startsWith(u8, name, "capnp_")) continue;
        const ZigFn = @TypeOf(@field(this, name));
        if (@typeInfo(ZigFn) != .@"fn") continue;
        if (!@hasDecl(c, name)) {
            std.debug.print("export {s} has no prototype in capnp_core.h\n", .{name});
            return error.HeaderMissingPrototype;
        }
        try expectSameCShape(name, ZigFn, @TypeOf(@field(c, name)));
        if (n_zig == zig_names.len) return error.TooManyExportsForDriftTest;
        zig_names[n_zig] = name;
        n_zig += 1;
    }

    // Reverse direction: scan the header text for `capnp_xxx(` prototypes.
    const header = @embedFile("capnp_core_h_text");
    var it = HeaderFnNames{ .src = header };
    var n_header: usize = 0;
    while (it.next()) |name| {
        n_header += 1;
        for (zig_names[0..n_zig]) |zn| {
            if (std.mem.eql(u8, zn, name)) break;
        } else {
            std.debug.print("capnp_core.h declares {s} but abi.zig does not export it\n", .{name});
            return error.HeaderExtraPrototype;
        }
    }
    try testing.expectEqual(n_zig, n_header);
}

fn expectSameCShape(name: []const u8, comptime ZigFn: type, comptime CFn: type) !void {
    const z = @typeInfo(ZigFn).@"fn";
    const h = @typeInfo(CFn).@"fn";
    if (!std.meta.eql(z.attrs.@"callconv", h.attrs.@"callconv")) {
        std.debug.print("{s}: calling convention differs from capnp_core.h\n", .{name});
        return error.HeaderCallconvMismatch;
    }
    if (z.param_types.len != h.param_types.len) {
        std.debug.print("{s}: {d} params in Zig, {d} in capnp_core.h\n", .{ name, z.param_types.len, h.param_types.len });
        return error.HeaderArityMismatch;
    }
    inline for (z.param_types, h.param_types, 0..) |zp, hp, i| {
        if (comptime !sameCShape(zp.?, hp.?, 0)) {
            std.debug.print("{s}: param {d} is {s} in Zig, {s} in capnp_core.h\n", .{ name, i, @typeName(zp.?), @typeName(hp.?) });
            return error.HeaderParamMismatch;
        }
    }
    if (comptime !sameCShape(z.return_type.?, h.return_type.?, 0)) {
        std.debug.print("{s}: returns {s} in Zig, {s} in capnp_core.h\n", .{ name, @typeName(z.return_type.?), @typeName(h.return_type.?) });
        return error.HeaderReturnMismatch;
    }
}

/// C-compatibility of a Zig type `Z` and its translate-c twin `H`: ints agree
/// on size and signedness; pointers agree on what they point at (function
/// pointers by signature, structs by layout, opaque handles by opaqueness);
/// optional pointers match plain ones (C has no non-null pointers); structs
/// agree field by field and offset by offset; `noreturn` matches `void`.
fn sameCShape(comptime Z: type, comptime H: type, comptime depth: u8) bool {
    if (depth > 6) return true; // self-referential layouts: stop descending
    if (Z == noreturn) return H == void or H == noreturn;
    if (Z == void or H == void) return Z == H;
    if (comptime pointee(Z)) |zc| {
        const hc = comptime pointee(H) orelse return false;
        return samePointee(zc, hc, depth + 1);
    }
    if (comptime pointee(H) != null) return false;
    const zi = @typeInfo(Z);
    const hi = @typeInfo(H);
    return switch (zi) {
        .int => |a| hi == .int and hi.int.bits == a.bits and hi.int.signedness == a.signedness,
        .@"enum" => |e| sameCShape(e.tag_type, H, depth + 1),
        .bool => (hi == .bool or hi == .int) and @sizeOf(Z) == @sizeOf(H),
        .float => |f| hi == .float and hi.float.bits == f.bits,
        .@"struct" => sameStruct(Z, H, depth + 1),
        else => Z == H,
    };
}

fn pointee(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| p.child,
            else => null,
        },
        else => null,
    };
}

fn samePointee(comptime Z: type, comptime H: type, comptime depth: u8) bool {
    const zi = @typeInfo(Z);
    const hi = @typeInfo(H);
    if (zi == .@"fn" or hi == .@"fn") {
        if (zi != .@"fn" or hi != .@"fn") return false;
        const z = zi.@"fn";
        const h = hi.@"fn";
        if (!std.meta.eql(z.attrs.@"callconv", h.attrs.@"callconv")) return false;
        if (z.param_types.len != h.param_types.len) return false;
        for (z.param_types, h.param_types) |zp, hp| {
            if (!sameCShape(zp.?, hp.?, depth + 1)) return false;
        }
        return sameCShape(z.return_type.?, h.return_type.?, depth + 1);
    }
    if (zi == .@"opaque" or hi == .@"opaque") return zi == .@"opaque" and hi == .@"opaque";
    return sameCShape(Z, H, depth + 1);
}

fn sameStruct(comptime Z: type, comptime H: type, comptime depth: u8) bool {
    if (@typeInfo(H) != .@"struct") return false;
    if (@sizeOf(Z) != @sizeOf(H) or @alignOf(Z) != @alignOf(H)) return false;
    const z = @typeInfo(Z).@"struct";
    const h = @typeInfo(H).@"struct";
    if (z.field_names.len != h.field_names.len) return false;
    for (z.field_names, h.field_names, z.field_types, h.field_types) |zn, hn, zt, ht| {
        if (@offsetOf(Z, zn) != @offsetOf(H, hn)) return false;
        if (!sameCShape(zt, ht, depth + 1)) return false;
    }
    return true;
}

/// Yields `capnp_*` identifiers that are immediately followed by `(` in the
/// header, skipping comments. Function-pointer typedefs (`(*capnp_x)(`) and
/// macros are not matched.
const HeaderFnNames = struct {
    src: []const u8,
    i: usize = 0,

    fn next(self: *HeaderFnNames) ?[]const u8 {
        const s = self.src;
        while (self.i < s.len) {
            if (std.mem.startsWith(u8, s[self.i..], "/*")) {
                const end = std.mem.indexOfPos(u8, s, self.i + 2, "*/") orelse s.len;
                self.i = @min(end + 2, s.len);
                continue;
            }
            if (std.mem.startsWith(u8, s[self.i..], "//")) {
                self.i = std.mem.indexOfScalarPos(u8, s, self.i, '\n') orelse s.len;
                continue;
            }
            const prev_is_ident = self.i > 0 and isIdent(s[self.i - 1]);
            if (!prev_is_ident and std.mem.startsWith(u8, s[self.i..], "capnp_")) {
                const start = self.i;
                while (self.i < s.len and isIdent(s[self.i])) self.i += 1;
                var j = self.i;
                while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
                if (j < s.len and s[j] == '(') return s[start..self.i];
                continue;
            }
            self.i += 1;
        }
        return null;
    }

    fn isIdent(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }
};
