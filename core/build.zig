//! capnp-swift core: the sans-IO C ABI over capnp-zig, built as the static
//! CapnpCore.xcframework that Package.swift's binaryTarget points at.
//!
//! Steps:
//!   zig build test          unit tests (host target, -Doptimize): the C ABI
//!                           (abi.zig, selftest.zig) and the connection core
//!                           (conn_test.zig: conn, effects, cap_remap), plus a
//!                           compile of the Apple root for the host, plus
//!                           test-abi
//!   zig build test-abi      the C ABI through capnp_core.h (abi_test.zig),
//!                           linked against the host libcapnp_core.a
//!   zig build fuzz-abi      random operation sequences over the C ABI
//!                           (-- --seconds N [--seed S]); M2 gate: 1800 s
//!   zig build xcframework   macOS arm64 + x86_64 slices (-Dcore-optimize,
//!                           default ReleaseSafe), lipo, then
//!                           `xcodebuild -create-xcframework` into
//!                           <repo>/CapnpCore.xcframework
//!
//! Link rules (plan §1.1, §10): no bundled compiler-rt (it would rebind the
//! app's memcpy/memset), `-fno-stack-check` (x86_64 Debug otherwise needs
//! ___zig_probe_stack), never strip DWARF (an app's dSYM is built from the
//! DWARF inside the .a), static only.
//!
//! Since capnp-zig v0.23.0 (handoff H7 executed) the shim itself lives
//! upstream as the Experimental `native` module (`src/native/` in the
//! package): conn.zig, effects.zig, cap_remap.zig, abi.zig, selftest.zig
//! and their tests. What stays here: apple_root.zig (the library root:
//! Apple std overrides + the allocator and version string the native ABI
//! reads from its root), core/include/capnp_core.h (the shipped SNAPSHOT
//! of the package's src/native/include/capnp_core.h; the snapshot gate
//! scripts/check-native-header.sh keeps them identical), fuzz_abi.zig
//! (our long-fuzz lane; upstream runs its own), and this build file.
//!
//! Imports available to core sources: "capnpc-zig" and "capnpc-zig-core"
//! (both capnp-zig's `capnpc-zig-core` module, which exports `native`),
//! and "build_info" (versions from build.zig.zon).

const std = @import("std");
const manifest = @import("build.zig.zon");

/// Apple deployment floors (plan D2 = A).
const macos_min = "15.0";
const ios_min = "18.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_optimize = b.option(
        std.builtin.Optimize,
        "core-optimize",
        "Optimize mode of the XCFramework slices (default: safe, i.e. ReleaseSafe)",
    ) orelse .safe;
    const ios = b.option(
        bool,
        "ios",
        "Also build ios-arm64 and ios-arm64_x86_64-simulator slices (M5; fails until handoff H1)",
    ) orelse false;

    const build_info = b.addOptions();
    build_info.addOption([]const u8, "core_version", manifest.version);
    build_info.addOption([]const u8, "capnp_zig_hash", manifest.dependencies.capnpc_zig.hash);
    build_info.addOption([]const u8, "capnp_zig_version", pinnedVersion(manifest.dependencies.capnpc_zig.hash));

    // ---- test -------------------------------------------------------------
    // The shim's own tests moved upstream with it (capnp-zig v0.23.0); we
    // run the package's abi_test/conn_test against OUR library root and
    // OUR header snapshot, so the embedded configuration (allocator,
    // version string, Apple overrides) is what gets exercised.
    const test_step = b.step("test", "Run the core unit tests");
    {
        // The shim's own tests run transitively: the package's lib_core
        // references native/{conn,abi}_test.zig in test builds (18 native
        // tests at v0.23.0), and test-abi below runs the C ABI through OUR
        // header snapshot and host library. Here: the Apple root must at
        // least compile for the host on every test run.
        const host_lib = appleLibrary(b, build_info, target, optimize);
        test_step.dependOn(&host_lib.step);
    }

    // ---- test-abi -----------------------------------------------------------
    // The C ABI through the header: `src/abi_test.zig` calls the `capnp_*`
    // functions as translate-c declares them, linked from the host build of
    // `libcapnp_core.a` (`apple_root.zig`'s root). It never imports abi.zig,
    // so a prototype, layout or linkage mistake fails here. `zig build test`
    // runs it too.
    const test_abi_step = b.step("test-abi", "Run the C ABI tests (capnp_core.h against the host static library)");
    {
        const dep = capnpDependency(b, target, optimize);
        const mod = b.createModule(.{
            .root_source_file = dep.path("src/native/abi_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "capnpc-zig", .module = dep.module("capnpc-zig-core") }},
        });
        // The header through translate-c — OUR snapshot, the one shipped in
        // the XCFramework (the snapshot gate keeps it equal to the package's).
        const header_c = b.addTranslateC(.{
            .root_source_file = b.path("include/capnp_core.h"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("capnp_core_h", header_c.createModule());
        const tests = b.addTest(.{ .name = "core-abi-c", .root_module = mod });
        mod.linkLibrary(appleLibrary(b, build_info, target, optimize));
        test_abi_step.dependOn(&b.addRunArtifact(tests).step);
    }
    test_step.dependOn(test_abi_step);

    // ---- fuzz-abi -----------------------------------------------------------
    // Random operation sequences over the C ABI (src/fuzz_abi.zig is the
    // root, so abi.zig takes its leak-checking counting allocator). Usage:
    //   zig build fuzz-abi -Doptimize=ReleaseSafe -- --seconds 1800 [--seed S]
    const fuzz_step = b.step("fuzz-abi", "Fuzz the C ABI (pass -- --seconds N [--seed S]); exit 1 on a violation");
    {
        const mod = coreModule(b, build_info, "src/fuzz_abi.zig", target, optimize, .{});
        mod.addAnonymousImport("fuzz_seeds_json", .{ .root_source_file = b.path("fuzz/seeds/framing_fixtures.json") });
        const exe = b.addExecutable(.{ .name = "fuzz-abi", .root_module = mod });
        // Also installed (zig-out/bin/fuzz-abi) so a long run can use a
        // binary that later builds do not touch.
        fuzz_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        fuzz_step.dependOn(&run.step);
    }

    // ---- xcframework ------------------------------------------------------
    const xc_step = b.step("xcframework", "Build <repo>/CapnpCore.xcframework (macOS; iOS with -Dios=true)");
    {
        const macos = fatLibrary(b, build_info, core_optimize, &.{
            "aarch64-macos." ++ macos_min,
            "x86_64-macos." ++ macos_min,
        });

        // Both commands run in core/, so the output lands at the repo root,
        // where Package.swift's binaryTarget(path:) expects it. `rm` waits
        // for every slice (addSlice), so a failed compile leaves the previous
        // XCFramework in place.
        const out_dir = "../CapnpCore.xcframework";
        const rm = b.addSystemCommand(&.{ "rm", "-rf", out_dir });
        rm.setCwd(b.path("."));
        rm.has_side_effects = true;

        const xcodebuild = b.addSystemCommand(&.{ "xcodebuild", "-create-xcframework" });
        xcodebuild.setCwd(b.path("."));
        xcodebuild.has_side_effects = true;
        xcodebuild.step.dependOn(&rm.step);
        addSlice(xcodebuild, rm, b, macos);

        if (ios) {
            // M5 ships these. H1 landed in capnp-zig v0.21.0 (the fd gates
            // are macOS-only and `-Dfd-passing=false` is passed above), so
            // the compile blocker from M0 (`Io/Threaded.zig:15486` through the
            // fd closer) is gone; what remains for M5 is the iOS root work,
            // the simulator test lane and `Package.swift` platforms.
            const device = fatLibrary(b, build_info, core_optimize, &.{
                "aarch64-ios." ++ ios_min,
            });
            const simulator = fatLibrary(b, build_info, core_optimize, &.{
                "aarch64-ios." ++ ios_min ++ "-simulator",
                "x86_64-ios." ++ ios_min ++ "-simulator",
            });
            addSlice(xcodebuild, rm, b, device);
            addSlice(xcodebuild, rm, b, simulator);
        }

        xcodebuild.addArgs(&.{ "-output", out_dir });
        xc_step.dependOn(&xcodebuild.step);
    }
}

const ModuleExtras = struct {
    stack_check: ?bool = null,
    strip: ?bool = null,
    omit_frame_pointer: ?bool = null,
};

/// The capnp-zig dependency, always with fd passing compiled out.
fn capnpDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
) *std.Build.Dependency {
    // `-Dfd-passing=false` (capnp-zig >= v0.21.0, handoff H1): Swift owns
    // every socket, so the core compiles fd passing, the fd closer threads
    // and the AF_UNIX transport out. That removes the fd closer's
    // `___ulock_*` / `_pthread_create` / `_getrlimit` imports from the slices
    // (plan D7) and lets the core compile for iOS (M5).
    return b.dependency("capnpc_zig", .{
        .target = target,
        .optimize = optimize,
        .@"fd-passing" = false,
    });
}

/// A core module rooted at `root`, with the capnp-zig core dependency built
/// for the same target and mode.
fn coreModule(
    b: *std.Build,
    build_info: *std.Build.Step.Options,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    extras: ModuleExtras,
) *std.Build.Module {
    // `-Dfd-passing=false` (capnp-zig >= v0.21.0, handoff H1): Swift owns
    // every socket, so the core compiles fd passing, the fd closer threads
    // and the AF_UNIX transport out. That removes the fd closer's
    // `___ulock_*` / `_pthread_create` / `_getrlimit` imports from the slices
    // (plan D7) and lets the core compile for iOS (M5).
    const dep = capnpDependency(b, target, optimize);
    const capnp_core = dep.module("capnpc-zig-core");
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .stack_check = extras.stack_check,
        .strip = extras.strip,
        .omit_frame_pointer = extras.omit_frame_pointer,
        .imports = &.{
            .{ .name = "capnpc-zig", .module = capnp_core },
            .{ .name = "capnpc-zig-core", .module = capnp_core },
        },
    });
    mod.addOptions("build_info", build_info);
    return mod;
}

/// One thin `libcapnp_core.a` for one target.
fn appleLibrary(
    b: *std.Build,
    build_info: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "capnp_core",
        .linkage = .static,
        .root_module = coreModule(b, build_info, "src/apple_root.zig", target, optimize, .{
            .stack_check = false,
            // Keep DWARF in every slice (plan §10) and frame pointers for
            // crash-report unwinding through Zig frames.
            .strip = false,
            .omit_frame_pointer = false,
        }),
    });
    lib.bundle_compiler_rt = false;
    lib.bundle_ubsan_rt = false;
    return lib;
}

const Slice = struct { lib: std.Build.LazyPath };

/// Builds each triple of one platform and lipos them into one archive.
fn fatLibrary(
    b: *std.Build,
    build_info: *std.Build.Step.Options,
    optimize: std.builtin.Optimize,
    comptime triples: []const []const u8,
) Slice {
    const lipo = b.addSystemCommand(&.{ "lipo", "-create" });
    inline for (triples) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            @panic("bad target triple " ++ triple);
        const lib = appleLibrary(b, build_info, b.resolveTargetQuery(query), optimize);
        if (triples.len == 1) return .{ .lib = lib.getEmittedBin() };
        lipo.addFileArg(lib.getEmittedBin());
    }
    lipo.addArg("-output");
    return .{ .lib = lipo.addOutputFileArg("libcapnp_core.a") };
}

fn addSlice(xcodebuild: *std.Build.Step.Run, rm: *std.Build.Step.Run, b: *std.Build, slice: Slice) void {
    slice.lib.addStepDependencies(&rm.step);
    xcodebuild.addArg("-library");
    xcodebuild.addFileArg(slice.lib);
    xcodebuild.addArg("-headers");
    xcodebuild.addDirectoryArg(b.path("include"));
}

/// "capnpc_zig-0.20.0-<digest>" -> "0.20.0".
fn pinnedVersion(comptime hash: []const u8) []const u8 {
    const first = comptime std.mem.indexOfScalar(u8, hash, '-') orelse
        @compileError("capnpc_zig hash has no version: " ++ hash);
    const rest = hash[first + 1 ..];
    const second = comptime std.mem.indexOfScalar(u8, rest, '-') orelse
        @compileError("capnpc_zig hash has no digest: " ++ hash);
    return rest[0..second];
}
