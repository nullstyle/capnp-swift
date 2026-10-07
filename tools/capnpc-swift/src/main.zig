//! capnpc-swift entry point: the standard Cap'n Proto plugin protocol.
//!
//! stdin:  a serialized (unpacked) CodeGeneratorRequest message, at most
//!         64 MiB (the same budget capnpc-zig uses).
//! stdout: nothing (diagnostics go to stderr).
//! files:  one .swift per requested schema file, written relative to the
//!         cwd, or to `--output-dir=<dir>` when driven by a build step.
//!
//! Options: `--output-dir=<dir>`. Everything else is an error (no env
//! options: build cache keys must stay honest).

const std = @import("std");
const capnp = @import("capnp");
const generator = @import("generator.zig");

const max_code_generator_request_bytes: usize = 64 * 1024 * 1024;
const output_dir_option = "--output-dir=";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var output_dir: ?[]const u8 = null;
    {
        var iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
        defer iter.deinit();
        _ = iter.skip(); // program name
        while (iter.next()) |arg| {
            if (std.mem.startsWith(u8, arg, output_dir_option)) {
                output_dir = arg[output_dir_option.len..];
            } else {
                std.debug.print("capnpc-swift: unknown argument '{s}'\n", .{arg});
                return error.InvalidArgument;
            }
        }
    }

    var owned_output_root: ?std.Io.Dir = null;
    defer if (owned_output_root) |dir| dir.close(io);
    if (output_dir) |path| {
        owned_output_root = openOutputRoot(std.Io.Dir.cwd(), io, path) catch |err| {
            std.debug.print("capnpc-swift: cannot open output directory '{s}': {}\n", .{ path, err });
            return err;
        };
    }
    const output_root = owned_output_root orelse std.Io.Dir.cwd();

    const stdin = std.Io.File.stdin();
    var read_buf: [65536]u8 = undefined;
    var reader = stdin.reader(io, &read_buf);
    reader.mode = .streaming;
    const input_data = readCodeGeneratorRequestInput(allocator, &reader.interface) catch |err| {
        std.debug.print("capnpc-swift: error reading stdin: {}\n", .{err});
        return err;
    };
    defer allocator.free(input_data);

    const request = capnp.request.parseCodeGeneratorRequest(allocator, input_data) catch |err| {
        std.debug.print("capnpc-swift: error parsing CodeGeneratorRequest: {}\n", .{err});
        return err;
    };
    defer capnp.request.freeCodeGeneratorRequest(allocator, request);

    var gen = try generator.Generator.init(allocator, request.nodes);
    defer gen.deinit();

    for (request.requested_files) |requested_file| {
        const output_code = gen.generateFile(requested_file) catch |err| {
            std.debug.print("capnpc-swift: error generating '{s}': {}\n", .{ requested_file.filename, err });
            return err;
        };
        defer allocator.free(output_code);

        const output_filename = try getOutputFilename(allocator, requested_file.filename);
        defer allocator.free(output_filename);

        const file = try createOutputFileInDir(output_root, io, output_filename);
        defer file.close(io);
        try file.writeStreamingAll(io, output_code);
    }
}

fn readCodeGeneratorRequestInput(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    // The request arrives as one uninterrupted stream; take it whole.
    return reader.allocRemaining(allocator, .limited(max_code_generator_request_bytes)) catch |err| switch (err) {
        error.ReadFailed => return error.InvalidInput,
        else => err,
    };
}

fn openOutputRoot(base: std.Io.Dir, io: std.Io, path: []const u8) !std.Io.Dir {
    if (path.len == 0) return error.InvalidOutputDir;
    return base.createDirPathOpen(io, path, .{});
}

/// A schema filename must be a plain relative path: no absolute paths, no
/// `..` (the request names where output goes; never trust it).
fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/') return error.InvalidOutputPath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidOutputPath;
    }
}

fn getOutputFilename(allocator: std.mem.Allocator, schema_filename: []const u8) ![]const u8 {
    try validateRelativePath(schema_filename);
    if (std.mem.endsWith(u8, schema_filename, ".capnp")) {
        const stem = schema_filename[0 .. schema_filename.len - ".capnp".len];
        return try std.fmt.allocPrint(allocator, "{s}.swift", .{stem});
    }
    return try allocator.dupe(u8, schema_filename);
}

fn createOutputFileInDir(root: std.Io.Dir, io: std.Io, filename: []const u8) !std.Io.File {
    // Schema files may nest (`sub/dir/foo.capnp`); create parents as needed.
    if (std.fs.path.dirname(filename)) |parent| {
        root.createDirPath(io, parent) catch {};
    }
    return root.createFile(io, std.fs.path.basename(filename), .{ .resolve_beneath = true });
}
