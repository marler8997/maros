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

fn biosTeletypeOutString(str: [*:0]const u8) void {
    var i: usize = 0;
    while (str[i] != 0) : (i += 1) {
        biosTeletypeOut(str[i]);
    }
}

pub export fn _start() align(16) linksection(".text.start") noreturn {
    // NOTE: this function is not working yet for some reason
    //biosTeletypeOutString("Hi!\r\n");
    biosTeletypeOut('H');
    biosTeletypeOut('i');
    biosTeletypeOut('!');
    biosTeletypeOut('\r');
    biosTeletypeOut('\n');

    // test that a simple loop is working
    {
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            biosTeletypeOut('*');
        }
    }


    biosTeletypeOut('\r');
    biosTeletypeOut('\n');
    while (true) {
    }
}
