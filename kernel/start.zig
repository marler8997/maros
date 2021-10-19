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

fn biosTeletypeOut(c: u8) void {
    asm volatile(
        \\ mov $0x0e, %%ah
        \\ int $0x10
        :
        : [c] "{al}" (c),
        : "ah"
    );
}

pub export fn _start() align(16) linksection(".text.start") callconv(.Naked) noreturn {
    biosTeletypeOut('H');
    biosTeletypeOut('i');
    biosTeletypeOut('!');
    biosTeletypeOut('\r');
    biosTeletypeOut('\n');
    while (true) {
    }
}
