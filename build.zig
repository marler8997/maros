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
    buildNoreturn(b);
}
fn buildNoreturn(b: *Builder) noreturn {
    const err = buildOrFail(b);
    std.log.err("initial build to setup config.zig failed with {s}", .{@errorName(err)});
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace.*);
    }
    std.os.exit(0xff);
}
fn buildOrFail(b: *Builder) anyerror {
    const config = b.pathFromRoot("config.zig");

    std.fs.cwd().access(config, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("copying default configuration to config.zig..", .{});
            try b.updateFile(b.pathFromRoot("defaultconfig.zig"), config);
        },
        else => |e| fatal("failed to access '{s}', {s}", .{config, @errorName(e)}),
    };

    const build_step = addBuild(b, .{ .path = "buildconfigured.zig" }, .{});
    build_step.addArgs(try getBuildArgs(b));

//    const writer = std.io.getStdErr().writer();
//    for (build_step.args.items) |arg| {
//        try writer.print("{s} ", .{arg});
//    }
//    try writer.print("\n", .{});

    build_step.step.make() catch |err| switch (err) {
        error.UnexpectedExitCode => std.os.exit(0xff), // error already printed by subprocess
        else => |e| return e,
    };
    std.os.exit(0);
}

// TODO: remove the following if https://github.com/ziglang/zig/pull/9987 is integrated
fn getBuildArgs(self: *Builder) ! []const [:0]const u8 {
    const args = try std.process.argsAlloc(self.allocator);
    return args[5..];
}
pub const BuildStepOptions = struct {
    step_name: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
};
pub fn addBuild(self: *Builder, build_file: std.build.FileSource, options: BuildStepOptions) *std.build.RunStep {
    const run_step = std.build.RunStep.create(
        self,
        options.step_name orelse @as([]const u8, self.fmt("zig build {s}", .{build_file.getDisplayName()})),
    );
    run_step.addArg(self.zig_exe);
    run_step.addArg("build");
    run_step.addArg("--build-file");
    run_step.addFileSourceArg(build_file);
    run_step.addArg("--cache-dir");
    run_step.addArg(options.cache_dir orelse @as([]const u8, self.pathFromRoot(self.cache_root)));
    return run_step;
}
