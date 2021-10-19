const std = @import("std");

/// Mimic the linux boot header for now.
/// This will make it easy for our bootloader to work with both linux and our kernel.
///
/// https://github.com/torvalds/linux/blob/master/Documentation/x86/boot.rst
///
// can't use packed because of bugs in zig compiler
const BootHeader = extern struct {
    stuff0: [0x1f1]u8 = [_]u8 { 0xab } ** 0x1f1,
    setup_sects: u8,
    root_flags: u16,
    /// size of the 32-bit code in 16-byte paras
    syssize: u32,
    stuff2: [8]u8 = [_]u8 { 0xbc } ** 8,
    // The following byte is the x86 'jump rel8' instruction
    // The bootloader will jump to this address, which will then jump to
    // another address based on the immediate operand offset in the following byte
    jump_instr: u8 = 0xeb,
    // The jump offset from addres 0x202 to jump to
    jump_instr_rel8_operand: i8,
    header: [4]u8 = [_]u8 { 'H', 'd', 'r', 'S' },
    version: u16,
    stuff3: [8]u8 = [_]u8 { 0xcd } ** 8,
    type_of_loader: u8 = 0,
    loadflags: u8,
    stuff4: [6]u8 = [_]u8 { 0xef } ** 6,
    ramdisk_image: u32 = 0,
    ramdisk_size: u32,
    stuff5: [4]u8 = [_]u8 { 0xfa } ** 4,
    heap_end_ptr: u16 = 0,
    stuff6: [1]u8 = [_]u8 { 0xac } ** 1,
    ext_loader_type: u8 = 0,
    cmd_line_ptr: u32 = 0,
    stuff7: [82]u8 = [_]u8 { 0xbd } ** 82,
};

const jump_instr_offset = 0x200;
comptime {
    std.debug.assert(@offsetOf(BootHeader, "setup_sects") == 0x1f1);
    std.debug.assert(@offsetOf(BootHeader, "root_flags") == 0x1f2);
    std.debug.assert(@offsetOf(BootHeader, "syssize") == 0x1f4);
    std.debug.assert(@offsetOf(BootHeader, "jump_instr") == jump_instr_offset);
    std.debug.assert(@offsetOf(BootHeader, "header") == 0x202);
    std.debug.assert(@offsetOf(BootHeader, "version") == 0x206);
    std.debug.assert(@offsetOf(BootHeader, "type_of_loader") == 0x210);
    std.debug.assert(@offsetOf(BootHeader, "loadflags") == 0x211);
    std.debug.assert(@offsetOf(BootHeader, "ramdisk_image") == 0x218);
    std.debug.assert(@offsetOf(BootHeader, "ramdisk_size") == 0x21c);
    std.debug.assert(@offsetOf(BootHeader, "heap_end_ptr") == 0x224);
    std.debug.assert(@offsetOf(BootHeader, "ext_loader_type") == 0x227);
    std.debug.assert(@offsetOf(BootHeader, "cmd_line_ptr") == 0x228);
    std.debug.assert(@sizeOf(BootHeader) == 0x280);
}

const LOADED_HIGH = 0x01;
// 000001f0  ff 1f
// root_flags: 01 00
// 38 37 08 00  00 00 ff ff 00 00 55 aa  |....87........U.|
export const bootheader linksection(".bootheader") = BootHeader {
    .setup_sects = 0x03, // just hardcode for now
    .root_flags = 0,
    .syssize = 0x123, // just hardcode for now
    // jump past the end of the bootheader from the end of jump instruction
    .jump_instr_rel8_operand = @sizeOf(BootHeader) - (jump_instr_offset + 2),
    .version = 0x0204, // 2.4
    .loadflags = LOADED_HIGH,
    .ramdisk_size = 0x0,
};
