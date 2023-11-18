const std = @import("std");
const buildlog = std.log.scoped(.build);

pub fn exec(allocator: std.mem.Allocator, argv: []const []const u8) !std.ChildProcess.ExecResult {
    const cmd = try std.Build.Step.allocPrintCmd2(allocator, null, null, argv);
    defer allocator.free(cmd);
    buildlog.debug("[exec] {s}", .{cmd});
    return std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv,
    });
}

pub fn fmtTerm(term: ?std.process.Child.Term) std.fmt.Formatter(formatTerm) {
    return .{ .data = term };
}
fn formatTerm(
    term: ?std.process.Child.Term,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    if (term) |t| switch (t) {
        .Exited => |code| try writer.print("exited with code {}", .{code}),
        .Signal => |sig| try writer.print("terminated with signal {}", .{sig}),
        .Stopped => |sig| try writer.print("stopped with signal {}", .{sig}),
        .Unknown => |code| try writer.print("terminated for unknown reason with code {}", .{code}),
    } else {
        try writer.writeAll("exited with any code");
    }
}
