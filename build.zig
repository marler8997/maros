//! This build.zig file just ensures that config.zig
//! exists, then re-invokes zig build with the buildconfigured.zig

// tested with zig version 0.13.0

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // this ensures defaultconfig.zig stays valid
    _ = @import("defaultconfig.zig");
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

pub fn build(b: *std.Build) !void {
    buildNoreturn(b);
}
fn buildNoreturn(b: *std.Build) noreturn {
    const err = buildOrFail(b);
    std.log.err("initial build to setup config.zig failed with {s}", .{@errorName(err)});
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace.*);
    }
    std.process.exit(0xff);
}
fn buildOrFail(b: *std.Build) anyerror {
    const config = b.pathFromRoot("config.zig");

    std.fs.cwd().access(config, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("copying default configuration to config.zig..", .{});
            _ = try std.fs.cwd().updateFile(
                b.pathFromRoot("defaultconfig.zig"),
                std.fs.cwd(),
                config,
                .{},
            );
        },
        else => |e| fatal("failed to access '{s}', {s}", .{config, @errorName(e)}),
    };

    var build_args = std.ArrayListUnmanaged([]const u8){ };
    build_args.appendSlice(b.allocator, &.{
        b.graph.zig_exe,
        "build",
        "--build-file",
        b.pathFromRoot("buildconfigured.zig"),
        "--cache-dir",
        b.cache_root.path orelse @panic("todo"),
    }) catch @panic("OOM");
    build_args.appendSlice(b.allocator, try getBuildArgs(b)) catch @panic("OOM");

    var child = std.process.Child.init(
        build_args.toOwnedSlice(b.allocator) catch @panic("OOM"),
        b.allocator,
    );
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| std.process.exit(code),
        inline else => |sig| {
            const exit_code: u8 = @intCast(sig & 0xff);
            std.process.exit(if (exit_code == 0) 1 else exit_code);
        },
    }
}

// TODO: remove the following if https://github.com/ziglang/zig/pull/9987 is integrated
fn getBuildArgs(self: *std.Build) ! []const [:0]const u8 {
    const args = try std.process.argsAlloc(self.allocator);
    return args[5..];
}
