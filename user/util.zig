const std = @import("std");
const io = @import("io.zig");

pub fn dumpProgramInput(args: [:null] ?[*:0]u8) !void {
    {
        const cwd = try std.process.getCwdAlloc(std.heap.page_allocator);
        defer std.heap.page_allocator.free(cwd);
        try io.printStdout("cwd \"{s}\"\n", .{cwd});
    }
    for (args, 0..) |arg, i| {
        try io.printStdout("arg {} \"{s}\"\n", .{i, arg.?});
    }
    for (std.os.environ) |env| {
        try io.printStdout("env \"{s}\"\n", .{env});
    }
}
