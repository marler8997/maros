const std = @import("std");

/// Mimic the linux boot header for now.
/// This will make it easy for our bootloader to work with both linux and our kernel.
///
/// https://github.com/torvalds/linux/blob/master/Documentation/x86/boot.rst
///
const BootHeader = packed struct {
    stuff0: [0x1f1]u8 = [_]u8 { 0xab } ** 0x1f1,
    setup_sects: u8,
    stuff1: [2]u8 = [_]u8 { 0xbc } ** 2,
    syssize: u32,
    stuff2: [14]u8 = [_]u8 { 0xbc } ** 14,
    version: u16,
    stuff3: [8]u8 = [_]u8 { 0xcd } ** 8,
    type_of_loader: u8 = 0,
    loadflags: u8,
    stuff4: [6]u8 = [_]u8 { 0xcd } ** 6,
    ramdisk_image: u32 = 0,
    ramdisk_size: u32,
    stuff5: [4]u8 = [_]u8 { 0xde } ** 4,
    heap_end_ptr: u16 = 0,
    stuff6: [1]u8 = [_]u8 { 0xde } ** 1,
    ext_loader_type: u8 = 0,
    cmd_line_ptr: u32 = 0,
};
comptime {
    std.debug.assert(@offsetOf(BootHeader, "setup_sects") == 0x1f1);
    std.debug.assert(@offsetOf(BootHeader, "syssize") == 0x1f4);
    std.debug.assert(@offsetOf(BootHeader, "version") == 0x206);
    std.debug.assert(@offsetOf(BootHeader, "type_of_loader") == 0x210);
    std.debug.assert(@offsetOf(BootHeader, "loadflags") == 0x211);
    std.debug.assert(@offsetOf(BootHeader, "ramdisk_image") == 0x218);
    std.debug.assert(@offsetOf(BootHeader, "ramdisk_size") == 0x21c);
    std.debug.assert(@offsetOf(BootHeader, "heap_end_ptr") == 0x224);
    std.debug.assert(@offsetOf(BootHeader, "ext_loader_type") == 0x227);
    std.debug.assert(@offsetOf(BootHeader, "cmd_line_ptr") == 0x228);
}

const LOADED_HIGH = 0x01;

export const _ linksection(".bootheader") = BootHeader {
    .setup_sects = 0x03, // just hardcode for now
    .syssize = 0x123, // just hardcode for now
    .version = 0x0204, // 2.4
    .loadflags = LOADED_HIGH,
    .ramdisk_size = 0x0,
};
