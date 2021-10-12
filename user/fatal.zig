const std = @import("std");
const io = @import("io.zig");

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    io.printStderr(fmt, args) catch |e|
        std.debug.panic("failed to print error where fmt=\"{s}\" to stderr with {}", .{fmt, e});
    std.os.exit(0xff);
}
