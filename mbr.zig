const std = @import("std");
const builtin = @import("builtin");

pub const ChsAddress = packed struct {
    value: [3]u8,

    pub const zeros = ChsAddress { .value = [_]u8 { 0 } ** 3 };
    //pub fn setDefault(self: *ChsAddress) void {
    //    self.value = [_]u8 { 0 } ** 3;
    //}
};
// not working because of "Incorrect byte offset and struct size for packed structs" https://github.com/ziglang/zig/issues/2627
//comptime { std.debug.assert(@sizeOf(ChsAddress) == 3); }

pub const PartitionType = enum(u8) {
    empty                   = 0x00,
    linuxSwapOrSunContainer = 0x82,
    linux                   = 0x83,

    //Value enumValue() const { return value; }
    //string name() const
    //{
    //    import mar.conv : asString;
    //    return asString(value, "?");
    //}
    //template opDispatch(string name)
    //{
    //    enum opDispatch = PartitionType(__traits(getMember, Value, name));
    //}
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
    // workaround issue "Incorrect byte offset and struct size for packed structs" https://github.com/ziglang/zig/issues/2627
    //status: PartitionStatus,
    //first_sector_chs: ChsAddress,
    status_and_first_sector_chs: [4]u8,
    // workaround issue "Incorrect byte offset and struct size for packed structs" https://github.com/ziglang/zig/issues/2627
    //part_type: PartitionType,
    //last_sector_chs: ChsAddress,
    part_type_and_last_sector_chs: [4]u8,
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
    partitions: [4]PartitionEntry,
    boot_sig: [2]u8,

//    void setBootSignature()
//    {
//        *(cast(ushort*)bootSignature.ptr) = toBigEndian!ushort(0x55AA).getRawValue;
//    }

//    ubyte[512]* bytes() const { return cast(ubyte[512]*)&this; }
//    BigEndianOf!ushort bootSignatureValue() const
//    {
//        return BigEndianOf!ushort(*(cast(ushort*)bootSignature.ptr));
//    }
//    bool signatureIsValid() const
//    {
//        return bootSignatureValue() == toBigEndian!ushort(0x55AA);
//    }
};
comptime { std.debug.assert(@sizeOf(Sector) == 512); }
