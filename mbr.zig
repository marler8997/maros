const std = @import("std");
const builtin = @import("builtin");

pub const ChsAddress = extern struct {
    bytes: [3]u8,
    pub const zeros = ChsAddress { .bytes = [3]u8{ 0, 0, 0 } };
};
comptime { std.debug.assert(@sizeOf(ChsAddress) == 3); }

pub const PartitionType = enum(u8) {
    empty                   = 0x00,
    linuxSwapOrSunContainer = 0x82,
    linux                   = 0x83,
};

pub const PartitionStatus = enum(u8) {
    none,
    bootable = 0x80,
    _,
};

// this should be moved somewhere else probably
pub fn LittleEndianOf(comptime T: type) type {
    return packed struct {
        const Self = @This();
        le_val: T,
        pub fn fromNative(val: T) Self {
            return .{ .le_val = std.mem.nativeToLittle(T, val) };
        }
    };
}

// NOTE: can't use packed because of:
//    https://github.com/ziglang/zig/issues/9942
//    https://github.com/ziglang/zig/issues/9943
pub const PartitionEntry = extern struct {
    status: PartitionStatus,
    first_sector_chs: ChsAddress align(1),
    // workaround issue "Incorrect byte offset and struct size for packed structs" https://github.com/ziglang/zig/issues/2627
    part_type: PartitionType,
    last_sector_chs: ChsAddress align(1),
    first_sector_lba: LittleEndianOf(u32),
    sector_count: LittleEndianOf(u32),

    pub fn isBootable(self: PartitionEntry) bool {
        return (self.status & PartitionStatus.bootable) != 0;
    }
};
comptime { std.debug.assert(@sizeOf(PartitionEntry) == 16); }

pub const bootstrap_len = 446;

// NOTE: can't use packed because of:
//    https://github.com/ziglang/zig/issues/9942
//    https://github.com/ziglang/zig/issues/9943
pub const Sector = extern struct {
    bootstrap: [bootstrap_len]u8,
    partitions: [4]PartitionEntry align(2),
    boot_sig: [2]u8 align(2),
};
comptime { std.debug.assert(@sizeOf(Sector) == 512); }
