const std = @import("std");

pub fn main() u8 {
    return @call(
        .always_inline,
        @import("tool").maros_tool_main,
        .{ @as([:null] ?[*:0]u8, @ptrCast(std.os.argv)) },
    ) catch |e| std.debug.panic("{}", .{e});
}
