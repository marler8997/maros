const std = @import("std");

const bootheader = @import("bootheader.zig");
comptime {
    _ = bootheader;
}

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace) noreturn {
    _ = msg;
    _ = stack_trace;
    while (true) { }
}

//export fn _start() align(16) linksection(".text.boot") callconv(.Naked) noreturn {
pub export fn _start() align(16) linksection(".text") callconv(.Naked) noreturn {
    while (true) {
    }
}
