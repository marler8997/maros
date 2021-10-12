const std = @import("std");
const io = @import("io.zig");

pub fn main() u8 {
    return @call(
        .{
            .modifier = .always_inline
        },
        @import("tool").maros_tool_main,
        .{ @bitCast([:null] ?[*:0]u8, std.os.argv) },
    ) catch |e| std.debug.panic("{}", .{e});
}
