# H1 — capnp-zig: let the core build for iOS (fd gate, `-Dfd-passing`, an iOS lane)

- **To:** capnp-zig (the owner lands it on `main` and cuts the tag)
- **From:** capnp-swift
- **Date:** 2026-10-06
- **Status:** DRAFT (the owner sends it)
- **Needed by:** M5 (iOS). The `-Dfd-passing=false` part already helps at M0: it removes the fd closer threads and the `___ulock_*` imports from the macOS slices.

This is a document, not an issue. Nothing here was filed anywhere.

## Summary

1. capnp-zig v0.20.0 cannot build `capnpc-zig-core` for iOS, in any optimize mode, even with the std workaround from H2. The cause is the fd-passing gate: it uses `isDarwin()`, so the fd closer compiles in on iOS, and the closer names `std.Io.Threaded.io()`, which does not compile for iOS at Zig 0.17.0.
2. Change the gate to Linux and macOS.
3. Add a build option, `-Dfd-passing=false`, that compiles fd passing, the fd closer and the fd budget out on every target. capnp-swift owns every socket, so it wants none of them, on macOS either.
4. Add a `check-ios` step and a CI lane. No existing step can target iOS today (measured below).

Base: v0.20.0 (`01eaebe`). `src/` is identical at `1ee6d18`. Every line number below is v0.20.0's. `main` has moved to `5fabb36` since (the H4 fix); that commit touches none of the files cited here.

## The defect

The three gates (`isDarwin()` is true for macOS, iOS, tvOS, watchOS, visionOS, Mac Catalyst and DriverKit):

- `src/rpc/transport/fd_passing.zig:15`
- `src/rpc/transport/unix/fd_closer.zig:146`
- `src/rpc/transport/unix/fd_budget.zig:68`

```zig
pub const supported: bool = builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin();
```

What ties them together:

- `src/rpc/peer/peer_fds.zig:100-102` asserts `closer.supported == fd_passing.supported` at comptime.
- `src/rpc/transport/tcp/connection.zig:13-16` asserts `fd_io.supported == fd_passing.supported`. `fd_io.supported` is `closer.supported` (`src/rpc/transport/unix/fd_io.zig:175`), and `unix.supported` is `fd_io.supported` (`src/rpc/transport/unix/socket.zig:116`).
- Nothing asserts `fd_budget.supported`. A scratch build with only the first two changed also compiled.

The path to the compile error on iOS:

`Peer.deinit` (`mod.zig:1542`) → `peer_lifecycle.zig:284` → `PeerFds.deinit` (`peer_fds.zig:438`; `closer.release` at `:452`) → `fd_closer.release` (`:371`) → `trim` (`:358`) → `LaneState.lock` (`:268`) → `syncIo()` (`:284-286`), which returns `std.Io.Threaded.global_single_threaded.io()`. At Zig 0.17.0, naming `Threaded.io()` fails to compile for every iOS-family target (H2). Root overrides cannot help, because the reference is in capnp-zig code, not in std's panic path.

## Repro

A pristine v0.20.0 tree and an embedder root that already carries the H2 workaround:

```sh
git -C /path/to/capnp-zig archive v0.20.0 | tar -x -C /tmp/capnp-zig-0.20.0
```

`root_apple.zig`:

```zig
const std = @import("std");
const core = @import("capnpc-zig-core");

fn trapPanic(msg: []const u8, ra: ?usize) noreturn {
    _ = msg;
    _ = ra;
    @trap();
}
pub const panic = std.debug.FullPanic(trapPanic);
fn noLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    _ = fmt;
    _ = args;
}
pub const std_options: std.Options = .{ .logFn = noLog };
pub const std_options_debug_io: std.Io = std.Io.failing;

export fn h1_peer_roundtrip() u32 {
    var p = core.rpc.peer.Peer.initDetached(std.heap.c_allocator);
    defer p.deinit();
    p.disableThreadAffinity();
    return 1;
}
```

```sh
zig build-lib -target aarch64-ios -O ReleaseSafe -lc \
  --dep capnpc-zig-core -Mroot=root_apple.zig \
  --dep capnpc-zig=capnpc-zig-core -Mcapnpc-zig-core=/tmp/capnp-zig-0.20.0/src/lib_core.zig \
  -freference-trace=20
```

**Expected:** a static library. **Actual** (2026-10-06, tagged Zig 0.17.0, macOS 27 arm64; exit 1; paths shortened):

```
lib/std/Io/Threaded.zig:15486:25: error: no field named 'fd' in struct 'Io.Threaded.NullFile__struct_37'
        if (t.null_file.fd != -1) return t.null_file.fd;
                        ^~
lib/std/Io/Threaded.zig:357:48: note: struct declared here
    .wasi, .ios, .tvos, .visionos, .watchos => struct {
                                               ^~~~~~
referenced by:
    spawnDarwin: lib/std/Io/Threaded.zig:17468:59
    processReplace: lib/std/Io/Threaded.zig:15217:37
    io: lib/std/Io/Threaded.zig:1905:14
    syncIo: src/rpc/transport/unix/fd_closer.zig:285:53
    unlock: src/rpc/transport/unix/fd_closer.zig:273:30
    trim: src/rpc/transport/unix/fd_closer.zig:365:13
    release: src/rpc/transport/unix/fd_closer.zig:372:9
    deinit: src/rpc/peer/peer_fds.zig:452:31
    deinit: src/rpc/peer/peer_lifecycle.zig:284:42
    deinit: src/rpc/peer/mod.zig:1543:36
    h1_peer_roundtrip: root_apple.zig:24:19
```

The pristine tree fails the same way for `aarch64-ios` Debug and for both simulators in ReleaseSafe. With only the three gates changed to `.linux or .macos` in a copy of that tree, the same command builds (a 1,632,784-byte archive), and so do `aarch64-ios`, `aarch64-ios-simulator` and `x86_64-ios-simulator` in Debug and ReleaseSafe (6 of 6).

### No existing build step can target iOS

`zig build check-compile -Dtarget=aarch64-ios` at v0.20.0: 11 artifacts fail, every one with the `Threaded.zig:15486` error. After the gate change it is still 11. Those are executables and test binaries, and they use std's default panic handler, which is H2's path. With the H2 std fix applied too (a patched copy of `lib/`), the compile errors go away and only link errors remain: 1005 `undefined symbol` errors across the 11 artifacts (`___ulock_wait2`, `__NSGetExecutablePath`, ...), because nothing supplies an iOS SDK. So `check-compile` cannot be the iOS lane even after H2. A static-library step can: a static library never links.

## Why capnp-swift also wants fd passing off on macOS

The macOS slice of a core-only static library (the root above, built through a consumer `build.zig`, ReleaseSafe, `nm -u`):

| `-Dfd-passing` | undefined symbols | of them |
|---|---|---|
| `true` (today) | 27 | `___ulock_wait2`, `___ulock_wake`, `_pthread_create`, `_pthread_detach`, `_getrlimit`, `_shutdown`, `_close$NOCANCEL`, `_sigaltstack`, `__tlv_bootstrap`, ... and 5 defined `fd_closer` functions |
| `false` | 11 | `___stack_chk_fail ___stack_chk_guard _bzero _free _malloc _malloc_size _memcpy _memset _posix_memalign _pthread_threadid_np _realloc`; 0 `fd_closer` functions |

capnp-swift's symbol gate fails on `___ulock_*` and `_pthread_create` (App Store review risk and a thread the app did not ask for). Swift owns every socket, so the core never needs the closer.

## Proposed change

### 1. The gate: Linux and macOS

```diff
--- a/src/rpc/transport/fd_passing.zig
+++ b/src/rpc/transport/fd_passing.zig
-/// True where fd passing is compiled in: Linux and Darwin.
-pub const supported: bool = builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin();
+/// The targets where fd passing can be compiled in: Linux and macOS. Not
+/// iOS, tvOS, watchOS or visionOS: std's `Io.Threaded` does not compile
+/// there at Zig 0.17.0, and no lane tests fd passing there.
+pub const target_supported: bool = builtin.target.os.tag == .linux or builtin.target.os.tag == .macos;
+
+/// True where fd passing is compiled in: `target_supported` and the build
+/// option `-Dfd-passing` (default true).
+pub const supported: bool = target_supported and @import("capnp_build_options").fd_passing;
--- a/src/rpc/transport/unix/fd_closer.zig
+++ b/src/rpc/transport/unix/fd_closer.zig
-pub const supported: bool = builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin();
+pub const supported: bool = @import("../fd_passing.zig").supported;
--- a/src/rpc/transport/unix/fd_budget.zig
+++ b/src/rpc/transport/unix/fd_budget.zig
-pub const supported: bool = builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin();
+pub const supported: bool = @import("../fd_passing.zig").supported;
```

One source of truth makes the two comptime asserts true by construction. Also update the prose that says "Linux and Darwin": `fd_passing.zig:8` and `:14`, `fd_closer.zig:4` and `:145`, `fd_budget.zig:66`, `docs/api_contracts.md:88`, `docs/stability.md:305-306`. `fd_passing.zig:3` says the file depends only on `builtin`; that changes too.

**`.macos` or "not the iOS family"?** `== .macos` also turns fd passing off for Mac Catalyst and DriverKit, which compile today. The other choice, `isDarwin()` minus `.ios, .tvos, .watchos, .visionos`, keeps them on. capnp-swift's plan picks `.macos`: enable fd passing only where a lane tests it. Mac Catalyst is a non-goal for capnp-swift v1.

**A fourth Darwin gate, not tied to fd passing:** `src/rpc/integration/worker_pool.zig:708` (`park_door_supported`) also uses `isDarwin()`. With the gate change, the full `capnpc-zig` module still compiled for `aarch64-ios` with a root that names `tcp.Listener.init`, `WorkerPool.initListener` and `rpc.transport.unix` (a limited probe). It can stay as is.

### 2. The build option `-Dfd-passing`

```diff
--- a/build/modules.zig
+++ b/build/modules.zig
@@ Graph
     wasm_host_module: *std.Build.Step.Compile,
+    capnp_build_options_module: *std.Build.Module,
 };
@@ setup()
+    const fd_passing = b.option(
+        bool,
+        "fd-passing",
+        "Compile in fd passing, the fd closer threads and the AF_UNIX transport on Linux and macOS (default: true)",
+    ) orelse true;
+    const capnp_build_options = b.addOptions();
+    capnp_build_options.addOption(bool, "fd_passing", fd_passing);
+    const capnp_build_options_module = capnp_build_options.createModule();
@@
     lib_module.addImport("capnpc-zig", lib_module);
+    lib_module.addImport("capnp_build_options", capnp_build_options_module);
@@
     core_module.addImport("capnpc-zig", core_module);
+    core_module.addImport("capnp_build_options", capnp_build_options_module);
@@
     core_module_wasm.addImport("capnpc-zig", core_module_wasm);
+    core_module_wasm.addImport("capnp_build_options", capnp_build_options_module);
```

Every module that compiles `fd_passing.zig` needs the same import. The prototype wired every other module rooted in `src/`: `build/build_impl.zig:46, 64, 379, 745, 754, 778, 1033, 1114, 1619, 1700, 1741, 2034` and `build/reflection.zig:7` (v0.20.0 lines). For `:2034` (inside `addCodegenSkewChecks`) and `reflection.zig:7` (inside `runtime`), pass the module in as a parameter. `build/modules.zig:140` and `:151` (the wasm example schema and the wasm host) passed without it. A missed site fails loudly: with only `modules.zig` wired, `check-compile check-test-compile` stopped with 10 errors `no module named 'capnp_build_options' available within module ...`.

A consumer turns it off like this (what capnp-swift's `core/build.zig` will do):

```zig
const dep = b.dependency("capnpc_zig", .{ .target = target, .optimize = optimize, .@"fd-passing" = false });
const core = dep.module("capnpc-zig-core");
```

Two notes for the docs. (a) Every package that depends on capnp-zig in one build must pass the same option map, or the build gets two capnp-zig module sets; this is the rule `build/modules.zig` already states for quic. (b) A raw `zig build-lib -M...lib_core.zig` user must now also pass `-Mcapnp_build_options=<file>` holding `pub const fd_passing: bool = true;`.

**Considered and not picked:** a root declaration (`pub const capnp_fd_passing = false;`, read with `@hasDecl(@import("root"), ...)`). It is 3 lines and needs no build wiring. But `zig build test` cannot run in that configuration, because a test binary's root is the test runner. The build option can (lane 2 below). Both versions were built; both remove exactly the symbols in the table above.

### 3. Two test fixes so the suites pass with `-Dfd-passing=false` on macOS

```diff
--- a/tests/rpc/transport/unix/fd_test_support.zig
+++ b/tests/rpc/transport/unix/fd_test_support.zig
@@ -25 +25 @@
-pub const supported = is_linux or is_macos;
+pub const supported = (is_linux or is_macos) and capnpc.rpc.transport.unix.fd_io.supported;
--- a/tests/rpc/transport/unix/rpc_unix_worker_pool_test.zig
+++ b/tests/rpc/transport/unix/rpc_unix_worker_pool_test.zig
@@ -802 +802,5 @@ test "WorkerPool.initListener: unsupported targets return UnixSocketsUnsupported" {
-    if (comptime supported) return error.SkipZigTest;
+    // The park door's own gate (worker_pool.zig `park_door_supported`), not
+    // fd passing: `-Dfd-passing=false` turns the AF_UNIX suites off on macOS
+    // but leaves the park door in.
+    const park_door_supported = builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin();
+    if (comptime park_door_supported) return error.SkipZigTest;
```

Without the first fix, `check-test-compile -Dfd-passing=false` fails with 17 + 3 errors in `rpc_unix_fd_peer_test.zig` and `rpc_unix_fd_limits_test.zig` (`expected type 'i32', found 'void'`: the files read `FdHandle.fd`, which is `void` when fd passing is off). Without the second, one test fails (below). A cleaner second fix makes `park_door_supported` public and uses it; that adds an Experimental declaration to the API snapshot.

### 4. The `check-ios` step

Put this before the `check` step (`build/build_impl.zig:2003` at v0.20.0):

```zig
// iOS cross-compile lane. Static libraries never link, so no Apple SDK
// is needed. The macOS point builds with fd passing off, so the root's
// comptime check proves `-Dfd-passing` reaches the gate.
const check_ios_step = b.step("check-ios", "Compile capnpc-zig-core as static libraries for iOS, the iOS simulators, and macOS with fd passing off (no SDK, nothing runs)");
const ApplePoint = struct { query: std.Target.Query, fd_passing: bool };
const apple_points = [_]ApplePoint{
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .ios }, .fd_passing = true },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator }, .fd_passing = true },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator }, .fd_passing = true },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .fd_passing = false },
};
for (apple_points) |point| {
    const apple_target = b.resolveTargetQuery(point.query);
    const apple_options = b.addOptions();
    apple_options.addOption(bool, "fd_passing", point.fd_passing);
    const apple_options_module = apple_options.createModule();
    const apple_core = b.createModule(.{
        .root_source_file = b.path("src/lib_core.zig"),
        .target = apple_target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "capnp_build_options", .module = apple_options_module }},
    });
    apple_core.addImport("capnpc-zig", apple_core);
    const apple_lib = b.addLibrary(.{
        .name = "capnp-apple-check",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/apple/apple_check_root.zig"),
            .target = apple_target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "capnpc-zig-core", .module = apple_core },
                .{ .name = "capnp_build_options", .module = apple_options_module },
            },
        }),
    });
    _ = apple_lib.getEmittedBin();
    check_ios_step.dependOn(&apple_lib.step);
}
```

New file `tests/apple/apple_check_root.zig`:

```zig
//! Root for `zig build check-ios`: compiles `capnpc-zig-core` into a static
//! library for the iOS device and simulator targets, and for macOS with fd
//! passing compiled out. Nothing links or runs.
//!
//! The std overrides are the ones every iOS embedder needs at Zig 0.17.0:
//! any reference to `std.Io.Threaded.io()` fails to compile for iOS, tvOS,
//! watchOS and visionOS, and the default panic handler reaches it through
//! `std.Options.debug_io` (docs/upstream/handoff-zig-fork-ios-nullfile.md).
const std = @import("std");
const builtin = @import("builtin");
const core = @import("capnpc-zig-core");
const build_options = @import("capnp_build_options");

fn trapPanic(msg: []const u8, ra: ?usize) noreturn {
    _ = msg;
    _ = ra;
    @trap();
}
pub const panic = std.debug.FullPanic(trapPanic);

fn noLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    _ = fmt;
    _ = args;
}
pub const std_options: std.Options = .{ .logFn = noLog };
pub const std_options_debug_io: std.Io = std.Io.failing;

// The gate must follow both the target and `-Dfd-passing`.
comptime {
    const os = builtin.target.os.tag;
    const expect_fd = build_options.fd_passing and (os == .linux or os == .macos);
    if ((@FieldType(core.rpc.peer.FdHandle, "fd") != void) != expect_fd)
        @compileError("fd passing gate disagrees with the target and -Dfd-passing");
}

/// The sans-IO surface an embedder drives (capnp-swift's shim).
export fn capnp_apple_check_peer() u32 {
    var peer = core.rpc.peer.Peer.initDetached(std.heap.c_allocator);
    defer peer.deinit();
    peer.disableThreadAffinity();
    _ = peer.checkDeadlines();
    peer.handleFrame(&.{}) catch {};
    peer.notifyTransportClosed();
    return 1;
}
```

Cost, measured on an M-series Mac with a cold cache: 4 libraries at about 9 s each, 11.7 s wall in parallel. Without `getEmittedBin()` the step only analyzes. That also caught both ablations below and is cheaper; emitting also catches code-generation failures. The owner can pick.

### 5. CI

```yaml
  ios-check:
    name: iOS cross-compile (static libraries, no SDK)
    runs-on: ubuntu-latest        # assumed: a static library never links, so no SDK is needed
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v4
        with:
          version: 2026.7.17
      - uses: ./.github/actions/setup-zig
      - run: zig build check-ios --summary all
```

And one step in the macOS leg of the `test` job:

```yaml
      - name: Peer and transport suites with fd passing compiled out
        if: runner.os == 'macOS'
        run: zig build test-rpc-peer test-rpc-transport -Dfd-passing=false --summary all
```

## The tests that prove it, and their ablations

All runs: tagged Zig 0.17.0, macOS 27 arm64, on a scratch copy of v0.20.0 with sections 1-4 applied.

| Gate | Patched | Ablation | Result of the ablation |
|---|---|---|---|
| `zig build check-ios` | 9/9 steps pass | `target_supported` back to `isDarwin()` | RED: the 3 iOS libraries fail with `Threaded.zig:15486` and the root's `fd passing gate disagrees` error |
| `zig build check-ios` | 9/9 steps pass | `supported` ignores the option (`= target_supported`) | RED: only the `aarch64-macos` point fails, with `fd passing gate disagrees` |
| `test-rpc-peer test-rpc-transport -Dfd-passing=false` | 603 passed, 137 skipped, 0 failed | the `rpc_unix_worker_pool_test.zig:802` fix reverted | RED: 1 failed, `expected error.UnixSocketsUnsupported, found .{ ... }` (`WorkerPool.initListener` still works on macOS) |

Restoring each ablation turned the gate green again. More runs on the patched tree:

- Same suites with the default option: 734 of 740 passed, 6 skipped.
- `zig build check-compile check-test-compile`, native, with `-Dfd-passing` true and false: both pass.
- The repro above: builds for `aarch64-ios`, `aarch64-ios-simulator` and `x86_64-ios-simulator`, Debug and ReleaseSafe.

## Not verified

- `check-ios` on a Linux or Windows runner. The claim that static libraries need no SDK was checked only on a macOS host (an earlier probe ran an `aarch64-ios` build under `env -i PATH=/nonexistent DEVELOPER_DIR=/nonexistent`).
- The full `zig build test`, `-Dquic=true`, `check-api` and `docs-smoke` with the option off. The snapshot lists `unix.supported` and `fd_io.supported` by type only (`docs/api-snapshot-experimental.txt:3423, 3427`), so no drift is expected.
- Running capnp-zig on an iOS device or simulator. capnp-swift ran a capnp-zig peer in the iOS 27 simulator from a patched copy, but not through this exact patch.

## Scratch evidence (not in any repo)

Under `/private/tmp/claude-501/-Users-nullstyle-prj-zig-capnp-zig/d3e1b574-cf0b-4f76-a01c-9b84d5bc10a3/scratchpad/capnp-swift/h1-repro/`:

- `root_apple.zig`, `build1.sh`: the repro.
- `v0.20.0/`: the pristine tree. `optA/`: the patched tree.
- `h1-src.diff`, `h1-build.diff`, `h1-tests.diff`: the full prototype diffs. The build diff was made by a script, so `zig fmt` folded some module literals onto one line; write the real change by hand.
- `consumer/`: a consumer package that sets `-Dfd-passing` through `b.dependency`.
- `out/`: every log quoted above.
