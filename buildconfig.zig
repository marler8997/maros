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
    kernelPath: []const u8,
    kernelRepo: []const u8,
    kernelCommandLine: ?[]const u8,

    //imageFile: []const u8,
    sectorSize: MemorySize = .{ .value = 512, .unit = .byte },
    imageSize: MemorySize,
    crystalBootloaderKernelReserve: ?MemorySize,
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

const whitespace = " ";

fn peel(s: *[]const u8) ?[]const u8 {
    // ensure s does not start with whitespace
    std.debug.assert(s.*.len == 0 or std.mem.indexOfScalar(u8, whitespace, s.*[0]) == null);

    for (s.*) |c, i| {
        if (std.mem.indexOfScalar(u8, whitespace, c)) |_| {
            var result = s.*[0..i];
            s.* = s.*[i+1..];
            return result;
        }
    }
    s.* = s.*[s.*.len..];
    return null;
}

fn invalidConfig(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
}

pub const ConfigParser = struct {
    filename: []const u8,
    text: []const u8,
    lineNumber: u32,

//    pub fn init(allocator: *std.mefilename: []const u8) ConfigParser {
//        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
//        return .{

//        };
//         this.filename = filename;
//         if (!exists(filename))
//         {
//             logError("config file '", filename, "' does not exist");
//             exit(1);
//         }
//         this.text = cast(string)readText(filename);
//         this.lineNumber = 1;
//     }
//     void configError(T...)(string fmt, T args)
//     {
//         logError(filename, "(", lineNumber, ") ", format(fmt, args));
//         exit(1);
//     }

    fn invalidConfigCurrentPos(self: ConfigParser, comptime fmt: []const u8, args: anytype) noreturn {
        std.log.err("{s}({}): " ++ fmt, .{self.filename, self.lineNumber} ++ args);
        std.os.exit(0xff);
    }

    pub fn parse(self: *ConfigParser) Config {
        _ = self;

//        var bootloader: ?[]const u8 = null;
        var opt_kernel_path: ?[]const u8 = null;
        var opt_kernel_repo: ?[]const u8 = null;
        var opt_kernel_cmd_line: ?[]const u8 = null;
        var opt_image_size: ?MemorySize = null;
        var opt_crystal_kernel_reserve: ?MemorySize = null;
        var opt_rootfs_part: ?RootfsPart = null;
        var opt_swap_size: ?MemorySize = null;
        var combine_tools = false;

        var it = std.mem.split(u8, self.text, "\n");
        while (it.next()) |line_unstripped| : (self.lineNumber += 1) {
            var line = std.mem.trim(u8, line_unstripped, whitespace);
            const cmd = peel(&line) orelse {
                continue;
            };
            std.debug.assert(cmd.len > 0);
            if (cmd[0] == '#') {
                // just a comment
            } else if (std.mem.eql(u8, cmd, "bootloader")) {
                line = std.mem.trimLeft(u8, line, whitespace);
                std.log.err("bootloader config not impl", .{});
                std.os.exit(0xff);

                //bootloader = tryParseEnum!Bootloader(line);
                //if (bootloader.isNull)
                //    configError("invalid bootloader value '%s'", line);
            } else if (std.mem.eql(u8, cmd, "kernelPath")) {
                 opt_kernel_path = std.mem.trimLeft(u8, line, whitespace);
            } else if (std.mem.eql(u8, cmd, "kernelRepo")) {
                 opt_kernel_repo = std.mem.trimLeft(u8, line, whitespace);
            } else if (std.mem.eql(u8, cmd, "kernelCommandLine")) {
                 opt_kernel_cmd_line = std.mem.trimLeft(u8, line, whitespace);
//            } else if (std.mem.eql(u8, cmd, "imageFile")) {
//                 config.imageFile = line.stripLeft;
//            } else if (std.mem.eql(u8, cmd, "sectorSize")) {
//                 config.sectorSize = parseMemorySize(line.stripLeft);
            } else if (std.mem.eql(u8, cmd, "imageSize")) {
                opt_image_size = self.configParseMemorySize(std.mem.trimLeft(u8, line, whitespace));
            } else if (std.mem.eql(u8, cmd, "crystalBootloaderKernelReserve")) {
                opt_crystal_kernel_reserve = self.configParseMemorySize(std.mem.trimLeft(u8, line, whitespace));
            } else if (std.mem.eql(u8, cmd, "rootfsPartition")) {
                const fstype = peel(&line) orelse self.invalidConfigCurrentPos("rootfsPartition requires an fs type (i.e. ext4)", .{});
                const size = self.configParseMemorySize(std.mem.trimLeft(u8, line, whitespace));
                opt_rootfs_part = .{ .fstype = fstype, .size = size };
            } else if (std.mem.eql(u8, cmd, "swapPartition")) {
                opt_swap_size = self.configParseMemorySize(std.mem.trimLeft(u8, line, whitespace));
            } else if (std.mem.eql(u8, cmd, "combineTools")) {
                combine_tools = self.parseBool(std.mem.trimLeft(u8, line, whitespace));
            } else {
                self.invalidConfigCurrentPos("unknown config '{s}'", .{line_unstripped});
            }
         }
//
//         /*
//         enforce(!bootloader.isNull, "config file is missing the 'bootloader' setting");
//         config.bootloader = bootloader.unsafeGetValue;
//         final switch (config.bootloader)
//         {
//         case Bootloader.crystal:
//             enforce(config.crystalBootloaderKernelReserve.nonZero,
//                 "config file is missing the 'crystalBootloaderKernelReserve' setting");
//         }
//         */
        const kernel_path = opt_kernel_path orelse invalidConfig("missing the 'kernelPath' setting", .{});
        const kernel_repo = opt_kernel_repo orelse invalidConfig("missing the 'kernelRepo' setting", .{});
//         enforce(config.imageFile !is null, "config file is missing the 'imageFile' setting");
        const image_size = opt_image_size orelse invalidConfig("missing the 'imageSize' setting", .{});
        const rootfs_part = opt_rootfs_part orelse invalidConfig("missing the 'rootfsPartition' setting", .{});
        const swap_size = opt_swap_size orelse invalidConfig("missing the 'swapPartition' setting", .{});
        return Config {
            .kernelPath = kernel_path,
            .kernelRepo = kernel_repo,
            .kernelCommandLine = opt_kernel_cmd_line,
            //.imageFile = "not impl",
            //.sectorSize = .{ .value = 0, .unit = .byte },
            .imageSize = image_size,
            .crystalBootloaderKernelReserve = opt_crystal_kernel_reserve,
            .rootfsPart = rootfs_part,
            .swapSize = swap_size,
            .combine_tools = combine_tools,
        };
    }
//     string tryNext(string* inOutLine)
//     {
//         auto line = *inOutLine;
//         scope(exit) *inOutLine = line;
//
//         line = line.stripLeft;
//         if (line.length == 0)
//             return null; // nothing next
//         auto spaceIndex = line.indexOf(' ');
//         if (spaceIndex < 0)
//         {
//             auto result = line;
//             line = line[$ .. $];
//             return result;
//         }
//         auto result = line[0 .. spaceIndex];
//         line = line[spaceIndex .. $];
//         return result;
//     }
    fn configParseMemorySize(self: ConfigParser, size: []const u8) MemorySize {
        return parseMemorySize(size) catch |e| {
            const reason = switch (e) {
                error.MissingUnit => "missing unit (i.e. G, M)",
                error.DoesNotStartWithDigit => "does not start with a digit 0-9",
                error.UnknownUnit => "unknown unit, expected 'G', 'M', etc.",
                error.Overflow => "overflow, does not fit in u64",
            };
            self.invalidConfigCurrentPos("invalid memory size '{s}', {s}", .{size, reason});
        };
    }
    fn parseBool(self: ConfigParser, val: []const u8) bool {
        if (std.mem.eql(u8, val, "true")) return true;
        if (std.mem.eql(u8, val, "false")) return false;
        self.invalidConfigCurrentPos("invalid bool '{s}', expected 'true' or 'false'", .{val});
    }
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
