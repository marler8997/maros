const std = @import("std");

pub const MemoryUnit = enum(u8) {
    byte, kiloByte, megaByte, gigaByte,

    pub fn getInfo(self: MemoryUnit) MemoryUnitInfo {
        return switch (self) {
            .byte     => .{ .byteShift =  0, .qemuPostfix = "B", .fdiskPostfix = "B" },
            .kiloByte => .{ .byteShift = 10, .qemuPostfix = "K", .fdiskPostfix = "K" },
            .megaByte => .{ .byteShift = 20, .qemuPostfix = "M", .fdiskPostfix = "M" },
            .gigaByte => .{ .byteShift = 30, .qemuPostfix = "G", .fdiskPostfix = "G" },
        };
    }
};

const MemoryUnitInfo = struct {
    byteShift: u6,
    qemuPostfix: []const u8,
    fdiskPostfix: []const u8,
};

pub const MemorySize = struct {
    value: u64,
    unit: MemoryUnit,
    pub fn nonZero(self: MemorySize) bool { return self.value != 0; }
    pub fn byteValue(self: MemorySize) u64 {
        return self.value << self.unit.getInfo().byteShift;
    }

    fn formatQemu(
        self: MemorySize,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}{}", .{self.value, self.unit.info.qemuPostfix});
    }
    pub fn fmtQemu(self: MemorySize) std.fmt.Formatter(formatQemu) {
        return .{ .data = self };
    }
};

pub fn sizeFromStr(comptime str: []const u8) MemorySize {
    return parseMemorySize(str) catch unreachable;
//    return comptime parseMemorySize(str) catch |e| {
//        const reason = switch (e) {
//            error.MissingUnit => "missing unit (i.e. G, M)",
//            error.DoesNotStartWithDigit => "does not start with a digit 0-9",
//            error.UnknownUnit => "unknown unit, expected 'G', 'M', etc.",
//            error.Overflow => "overflow, does not fit in u64",
//        };
//        @compileError("invalid memory size '" ++ str ++ "', " ++ reason);
//    };
}

const RootfsPart = struct {
    fstype: []const u8,
    size: MemorySize,
};

const KernelConfig = union(enum) {
    linux: struct {
        image: []const u8,
    },
    maros: struct {
        // TODO
    },
};

pub fn getMinSectorsToHold(sector_len: u64, required_len: u64) u64 {
    var count = @divTrunc(required_len, sector_len);
    if (required_len % sector_len != 0) {
        count += 1;
    }
    return count;
}

pub const Config = struct {
    kernel: KernelConfig,
    kernelCommandLine: ?[]const u8,

    //imageFile: []const u8,
    sectorSize: MemorySize = .{ .value = 512, .unit = .byte },
    imageSize: MemorySize,
    rootfsPart: RootfsPart,
    swapSize: MemorySize,

    combine_tools: bool,

//    auto mapImage(size_t offset, size_t length, Flag!"writeable" writeable) const
//    {
//        mixin tempCString!("imageFileTempCStr", "imageFile");
//        return MappedFile.openAndMap(imageFileTempCStr.str, offset, length, writeable);
//    }
//
//    Mounts getMounts() const
//    {
//        auto rootfs = imageFile ~ ".rootfs";
//        return Mounts(rootfs, rootfs.absolutePath);
//    }
//    LoopPartFiles getLoopPartFiles(string loopFile) const
//    {
//        return LoopPartFiles(
//            loopFile ~ "p1",
//            loopFile ~ "p2");
//    }
};

pub fn parseMemorySize(size: []const u8) !MemorySize {
    std.debug.assert(size.len > 0);

    var value_len: usize = 0;
    while (true) : (value_len += 1) {
        if (value_len >= size.len)
            return error.MissingUnit;
        if (!std.ascii.isDigit(size[value_len]))
            break;
    }
    if (value_len == 0)
        return error.DoesNotStartWithDigit;

    const unit = blk: {
        const unit_str = size[value_len..];
        if (std.mem.eql(u8, unit_str, "G"))
            break :blk MemoryUnit.gigaByte;
        if (std.mem.eql(u8, unit_str, "M"))
            break :blk MemoryUnit.megaByte;
        if (std.mem.eql(u8, unit_str, "K"))
            break :blk MemoryUnit.kiloByte;
        if (std.mem.eql(u8, unit_str, "B"))
            break :blk MemoryUnit.byte;
        return error.UnknownUnit;
    };

    const value = std.fmt.parseInt(u64, size[0..value_len], 10) catch |e| switch (e) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => unreachable,
    };
    return MemorySize { .value = value, .unit = unit };
}
