const std = @import("std");

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace) noreturn {
    _ = msg;
    _ = stack_trace;
    while (true) { }
}

comptime {
    if (@sizeOf(usize) != 4) @compileError("this code assumes we are in 8086 16-bit mode");
}

extern fn printfln() callconv(.Naked) void;
// not sure why I don't need this, zig's std start.zig should be checking for this
//pub extern fn _start() callconv(.Naked) noreturn;

fn printfln_zig(msg: [*:0]const u8) void {
    asm volatile(
        \\call printfln
        \\
        : [ret] "=" (-> void),
        : [msg] "{si}" (msg)
    );
}

export const hello_msg: [*:0]const u8 = "hello from zig!";

export fn do_some_zig_stuff() linksection(".text.zigboot") callconv(.Naked) void {
    //printfln_zig("hello from zig!");
    asm volatile(
//        \\ push %[arg6]
//        \\ push %%ebp
//        \\ mov  4(%%esp), %%ebp
//        \\ int  $0x80
//        \\ pop  %%ebp
//        \\ add  $4, %%esp
//        \\ret
//        : [ret] "=" (-> void),
//        : [arg6] "{eax}" (@ptrToInt(hello_msg))
//        : "memory"

        \\.global hello_msg
        \\mov hello_msg, %%si
        \\call printfln
        \\ret
        \\
    );
}
