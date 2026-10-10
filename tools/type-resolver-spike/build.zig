const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("capnpc_zig", .{ .target = target, .optimize = optimize, .@"fd-passing" = false });
    const fixtures = b.addOptions();
    fixtures.addOption([]const u8, "root", b.root.joinString(b.allocator, "../../Tests/generated_shape/requests") catch @panic("OOM"));
    fixtures.addOption([]const u8, "local", b.root.joinString(b.allocator, "fixtures") catch @panic("OOM"));
    const tests = b.addTest(.{
        .name = "type-resolver-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "capnp", .module = dep.module("capnpc-zig-core") },
                .{ .name = "fixtures", .module = fixtures.createModule() },
            },
        }),
    });
    const step = b.step("test", "Probe the public resolver against committed generic requests");
    step.dependOn(&b.addRunArtifact(tests).step);
    const exe = b.addExecutable(.{
        .name = "capnpc-swift-specialize",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "capnp", .module = dep.module("capnpc-zig-core") }},
        }),
    });
    b.installArtifact(exe);
    b.default_step = step;
}
