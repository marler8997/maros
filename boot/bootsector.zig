const std = @import("std");
pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace) noreturn {
    _ = msg;
    _ = stack_trace;
    while (true) { }
}


export var boot_disk_num: u8 = 0;

fn biosTeletypeOut(c: u8) void {
    asm volatile(
        \\ mov $0x0e, %%ah
        \\ int $0x10
        :
        : [c] "{al}" (c),
        : "ah"
    );
}

export fn biosPrintfln(str: [*:0]const u8) void {
    biosPrintf(str);
    biosPrintf("\r\n");
}

export fn biosPrintf(str: [*:0]const u8) void {
    var next = str;
    while (next[0] != 0) : (next += 1) {
        //if (next[0] >= 16 and next[0] <= 28) {
        //    biosTeletype
        //} else {
            biosTeletypeOut(next[0]);
        //}
    }
}

// These values are based on the offset the register will be stored
// after running pushad
//const ax_fmt = [_]u8 { 28 };
//const cx_fmt = [_]u8 { 24 };
//const dx_fmt = [_]u8 { 20 };
//const bx_fmt = [_]u8 { 16 };

pub export fn _start() linksection(".text.start") callconv(.Naked) noreturn {
    asm volatile(
        \\ .globl boot_disk_num
        \\ .global bootloader_stage2_sector_count
        \\
        \\ // initialize segments and stack
        \\ xor %%ax, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%ss
        \\ mov $0x7c00, %%esp         // the stack grows down so we put it just below the bootloader
        \\                            // so it won't overwrite it
        \\
        \\ mov %%dl, boot_disk_num    // save the boot disk number (used in the read_disk function)
    );

//    biosTeletypeOut('B');
//    biosTeletypeOut('C');
//    biosTeletypeOut('\r');
//    biosTeletypeOut('\n');

    biosPrintfln("bootloader started!!");
    //biosPrintfln("bootloader drive=" ++ dx_fmt ++ " size=" ++ ax_fmt);

    //var i: u8 = 0;
    //while (i < 10) : (i += 1) {
    //    biosTeletypeOut();
    //}

//    bootsector_data.boot_disk_num
//        \\
//        \\ // print start message
//        \\ and $0xFF, %%dx
//        \\ mov $bootloader_stage2_sector_count, %ax
//        \\ //mov $msg_started_dx_ax, %si
//        \\ //call printfln
//    );
    while (true) {
    }
}
