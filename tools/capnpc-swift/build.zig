//! capnpc-swift: the Cap'n Proto -> Swift schema code generator (plan §6, M3).
//!
//!   mise exec -- zig build            -> zig-out/bin/capnpc-swift
//!   mise exec -- zig build test       -> unit tests + the golden gate
//!
//! The plugin is a sibling of capnp-zig's own capnpc-zig: it reads a
//! serialized CodeGeneratorRequest on stdin (the wasm compiler's
//! `compile -o-` output; the compiler never spawns plugins itself — the
//! driver splits the pipeline) and writes one .swift file per requested
//! schema file, relative to the cwd or `--output-dir=` (the form a build
//! step uses: `run.addPrefixedOutputDirectoryArg("--output-dir=", ...)`).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("capnpc_zig", .{ .target = target, .optimize = optimize });
    const core = dep.module("capnpc-zig-core");

    const exe = b.addExecutable(.{
        .name = "capnpc-swift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "capnp", .module = core }},
        }),
    });
    b.installArtifact(exe);

    // The golden gate: run the built plugin on a committed CodeGeneratorRequest
    // (no schema compiler needed) and diff its output against the committed
    // golden file. `-Dupdate-goldens` rewrites the golden instead.
    const update_goldens = b.option(bool, "update-goldens", "Rewrite tests/golden/*.swift instead of diffing") orelse false;
    const golden_check = b.step("golden-check", "Diff the plugin output against its golden");
    {
        const run = b.addRunArtifact(exe);
        run.setStdIn(.{ .lazy_path = b.path("tests/requests/mvp.request.bin") });
        const out = run.addPrefixedOutputDirectoryArg("--output-dir=", "gen");

        const golden = b.path("tests/golden/mvp.swift");
        const generated = out.join(b.allocator, "mvp.swift") catch @panic("OOM");
        if (update_goldens) {
            const cp = b.addSystemCommand(&.{"cp"});
            cp.addFileArg(generated);
            cp.addFileArg(golden);
            b.getInstallStep().dependOn(&cp.step);
        } else {
            const diff = b.addSystemCommand(&.{"diff"});
            diff.addArg("-u");
            diff.addFileArg(golden);
            diff.addFileArg(generated);
            golden_check.dependOn(&diff.step);
        }
    }

    const test_step = b.step("test", "Run the generator unit tests and the golden gate");
    const tests = b.addTest(.{
        .name = "capnpc-swift-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "capnp", .module = core }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    if (!update_goldens) test_step.dependOn(golden_check);
}
