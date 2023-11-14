//! This build.zig file just ensures that config.zig
//! exists, then re-invokes zig build with the buildconfigured.zig

// tested with zig version 0.11.0

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
            _ = try std.fs.cwd().updateFile(
                b.pathFromRoot("defaultconfig.zig"),
                std.fs.cwd(),
                config,
                .{},
            );
        },
        else => |e| fatal("failed to access '{s}', {s}", .{config, @errorName(e)}),
    };

    const build_step = addBuild(b, .{ .path = "buildconfigured.zig" }, .{});
    build_step.addArgs(try getBuildArgs(b));

    var progress = std.Progress{};
    {
        var prog_node = progress.start("run buildconfigured.zig", 1);
        build_step.step.make(prog_node) catch |err| switch (err) {
            error.MakeFailed => std.os.exit(0xff), // error already printed by subprocess, hopefully?
            error.MakeSkipped => @panic("impossible?"),
        };
        prog_node.end();
    }
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
    const cache_root_path = self.cache_root.path orelse @panic("todo");
    run_step.addArg(self.pathFromRoot(cache_root_path));
    return run_step;
}
