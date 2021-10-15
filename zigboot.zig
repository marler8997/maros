const std = @import("std");

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace) noreturn {
    _ = msg;
    _ = stack_trace;
    while (true) { }
}


pub export fn _start() noreturn {
    asm volatile(
        \\int $0x10
    );
    while (true) { }
}

