//! This build.zig file just ensures that config.zig
//! exists, then re-invokes zig build with the buildconfigured.zig
const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;

comptime {
    // this ensures defaultconfig.zig stays valid
    _ = @import("defaultconfig.zig");
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
}

pub fn build(b: *Builder) !void {
    build2(b);
}
fn build2(b: *Builder) noreturn {
    const err = build3(b);
    std.log.err("initial build to setup config.zig failed with {s}", .{@errorName(err)});
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace.*);
    }
    std.os.exit(0xff);
}
fn build3(b: *Builder) anyerror {
    const config = b.pathFromRoot("config.zig");

    std.fs.cwd().access(config, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("copying default configuration to config.zig..", .{});
            try b.updateFile(b.pathFromRoot("defaultconfig.zig"), config);
        },
        else => |e| fatal("failed to access '{s}', {s}", .{config, @errorName(e)}),
    };

    // first 4 args are zig_exe, build_root, cache_root and global_cache_root
    // see std/special/build_runner.zig
    //
    // hopefully this doesn't change! ;)
    //
    const args = (try std.process.argsAlloc(b.allocator))[5..];

    var new_args = std.ArrayList([]const u8).init(b.allocator);
    try new_args.append(b.zig_exe);
    try new_args.append("build");
    try new_args.append("--build-file");
    try new_args.append(b.pathFromRoot("buildconfigured.zig"));
    try new_args.append("--cache-dir");
    try new_args.append(b.cache_root);

    var skip_next = false;
    for (args) |arg| {
        if (skip_next) continue;
        if (std.mem.eql(u8, arg, "--build-file")) {
            skip_next = true;
            continue;
        }
        try new_args.append(arg);
    }
    const writer = std.io.getStdErr().writer();
    for (new_args.items) |arg| {
        try writer.print("{s} ", .{arg});
    }
    try writer.print("\n", .{});

    const child = try std.ChildProcess.init(new_args.items, b.allocator);
    defer child.deinit();
    child.env_map = b.env_map;

    // TODO: use execve when possible
    try child.spawn();
    const term = try child.wait();
    const status = switch (term) {
        .Exited => |code| std.os.exit(code),
        .Signal => |signum| b.fmt("was killed by signal {}", .{signum}),
        .Stopped => |signum| b.fmt("was stopped by signal {}", .{signum}),
        .Unknown => |status| b.fmt("died with status {}", .{status}),
    };
    std.log.err("zig build {s}", .{status});
    std.os.exit(0xff);
}
