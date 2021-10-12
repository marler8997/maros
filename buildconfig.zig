const std = @import("std");
const build = @import("build.zig");
const MemoryUnit = build.MemoryUnit;
const MemorySize = build.MemorySize;

pub fn sizeFromStr(comptime str: []const u8) build.MemorySize {
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

pub const Config = struct {
    //kernelPath: []const u8,
    //kernelRepo: []const u8,
    kernel_image: []const u8,

    kernelCommandLine: ?[]const u8,

    //imageFile: []const u8,
    sectorSize: MemorySize = .{ .value = 512, .unit = .byte },
    imageSize: MemorySize,
    rootfsPart: RootfsPart,
    swapSize: MemorySize,

    combine_tools: bool,

    pub fn getMinSectorsToHold(self: Config, required_size: MemorySize) u64 {
        const required_len_bytes = required_size.byteValue();
        const sector_len = self.sectorSize.byteValue();
        var sectors_needed = required_len_bytes / sector_len;
        if (required_len_bytes % sector_len > 0) {
            sectors_needed += 1;
        }
        return sectors_needed;
    }
//    KernelPaths getKernelPaths() const
//    {
//        return KernelPaths(
//            // todo: this should be configurable
//            kernelPath ~ "/arch/x86_64/boot/bzImage");
//    }
//    CrystalBootloaderFiles getCrystalBootloaderFiles() const
//    {
//        const dir = "crystal";
//        return CrystalBootloaderFiles(
//            dir,
//            dir.appendPath("crystal.asm"),
//            dir.appendPath("crystal.list"),
//            dir.appendPath("crystal.bin"),
//            dir.appendPath("crystal-img"));
//    }
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
