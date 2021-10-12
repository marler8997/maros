const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

const buildconfig = @import("buildconfig.zig");
const Config = buildconfig.Config;
const ConfigParser = buildconfig.ConfigParser;

const MappedFile = @import("MappedFile.zig");
const mbr = @import("mbr.zig");

// TODO: rename this to GenerateCombinedToolsSourceStep
const GenerateToolsSourceStep = struct {
    step: std.build.Step,
    builder: *Builder,
    pub fn init(builder: *Builder) GenerateToolsSourceStep {
        return .{
            .step = std.build.Step.init(.custom, "generate tools.gen.zig", builder.allocator, make),
            .builder = builder,
        };
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(GenerateToolsSourceStep, "step", step);

        var build_root = try std.fs.cwd().openDir(self.builder.build_root, .{});
        defer build_root.close();

        // TODO: only generate and/or update the file if it was modified
        const file = try build_root.createFile("user" ++ std.fs.path.sep_str ++ "tools.gen.zig", .{});
        defer file.close();

        const writer = file.writer();
        try writer.writeAll("pub const tool_names = [_][]const u8 {\n");
        inline for (commandLineTools) |commandLineTool| {
            try writer.print("    \"{s}\",\n", .{commandLineTool.name});
        }
        try writer.writeAll("};\n");
        inline for (commandLineTools) |commandLineTool| {
            try writer.print("pub const {s} = @import(\"{0s}.zig\");\n", .{commandLineTool.name});
        }
    }
};
const InstallSymlink = struct {
    step: std.build.Step,
    builder: *Builder,
    symlink_target: []const u8,
    dir: std.build.InstallDir,
    dest_rel_path: []const u8,

    pub fn init(
        builder: *Builder,
        symlink_target: []const u8,
        dir: std.build.InstallDir,
        dest_rel_path: []const u8,
    ) InstallSymlink {
        return .{
            .step = std.build.Step.init(.custom, "install symlink", builder.allocator, make),
            .builder = builder,
            .symlink_target = symlink_target,
            .dir = dir,
            .dest_rel_path = dest_rel_path,
        };
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(InstallSymlink, "step", step);
        const full_dest_path = self.builder.getInstallPath(self.dir, self.dest_rel_path);
        _ = try updateSymlink(self.symlink_target, full_dest_path, .{});
    }
};

pub fn build(b: *Builder) !void {
    const config = try b.allocator.create(Config);
    config.* = try @import("config.zig").makeConfig();

    const target = blk: {
        var target = b.standardTargetOptions(.{});
        if (target.os_tag) |os_tag| {
            if (os_tag != .linux) {
                std.log.err("unsupported os '{s}', only linux is supported", .{@tagName(os_tag)});
                std.os.exit(0xff);
            }
        } else if (builtin.os.tag != .linux) {
            target.os_tag = .linux;
        }
        break :blk target;
    };
    const mode = b.standardReleaseOptions();

    try addUserStep(b, target, mode, config);

    const alloc_image_step = try b.allocator.create(AllocImageStep);
    alloc_image_step.* = AllocImageStep.init(b, config.imageSize.byteValue());
    b.step("alloc-image", "Allocate the image file").dependOn(&alloc_image_step.step);

    try addImageSteps(b, config, &alloc_image_step.step);
    try addBootloaderSteps(b, target, alloc_image_step);
    try addQemuStep(b, alloc_image_step.image_file);
}

fn addQemuStep(b: *Builder, image_file: []const u8) !void {
    var args = std.ArrayList([]const u8).init(b.allocator);

    const qemu_prog_name = "qemu-system-x86_64";
    try args.append(qemu_prog_name);
    try args.append("-m");
    try args.append("2048");
    try args.append("-drive");
    try args.append(try std.fmt.allocPrint(b.allocator, "format=raw,file={s}", .{image_file}));
    // TODO: make this an option
    //try args.append("--enable-kvm");

    // TODO: support serial options
    try args.append("--serial");
    try args.append("stdio");

    const qemu = b.addSystemCommand(args.toOwnedSlice());
    qemu.step.dependOn(b.getInstallStep());

    b.step("qemu", "Run maros in the Qemu VM").dependOn(&qemu.step);
}

fn addBootloaderSteps(b: *Builder, target: std.build.Target, alloc_image_step: *AllocImageStep) !void {
    const bootloader_bin = b.addExecutable("bootloader", null);
    bootloader_bin.setTarget(target);
    bootloader_bin.addAssemblyFile("bootloader.S");
    // TODO: this doesn't work with installRaw apparently (file issue and fix)
    //       I don't really want to install the bootloader to the "bin" install dir
    //       I'd rather put it in a directory named "boot"
    //bootloader_bin.override_dest_dir = .prefix;
    //bootloader_bin.installRaw("bootloader");
    const bootloader_bin_install = b.addInstallRaw(bootloader_bin, "bootloader");
    bootloader_bin.setLinkerScriptPath(.{ .path = "bootloader.ld" });

    // TODO: add installBootloader step

    const install_bootloader = try b.allocator.create(InstallBootloaderStep);
    install_bootloader.* = InstallBootloaderStep.init(b, alloc_image_step, bootloader_bin_install);
    b.getInstallStep().dependOn(&install_bootloader.step);
    b.step("install-bootloader", "Install bootloader").dependOn(&install_bootloader.step);
}

const InstallBootloaderStep = struct {
    step: std.build.Step,
    alloc_image_step: *AllocImageStep,
    bootloader_step: *std.build.InstallRawStep,
    pub fn init(b: *Builder, alloc_image_step: *AllocImageStep, bootloader_step: *std.build.InstallRawStep) InstallBootloaderStep {
        var result = .{
            .step = std.build.Step.init(.custom, "install the bootloader to the image", b.allocator, make),
            .alloc_image_step = alloc_image_step,
            .bootloader_step = bootloader_step,
        };
        result.step.dependOn(&bootloader_step.step);
        result.step.dependOn(&alloc_image_step.step);
        return result;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(InstallBootloaderStep, "step", step);
        const bootloader_filename = self.bootloader_step.output_file.path.?;
        std.log.debug("installing bootloader '{s}' to '{s}'", .{
            bootloader_filename,
            self.alloc_image_step.image_file
        });

        const bootloader_file = try std.fs.cwd().openFile(bootloader_filename, .{});
        defer bootloader_file.close();
        const bootloader_len = try bootloader_file.getEndPos();
        const mapped_bootloader = try MappedFile.init(bootloader_file, bootloader_len, .read_only);
        defer mapped_bootloader.deinit();

        const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .write = true });
        defer image_file.close();
        const mapped_image = try MappedFile.init(image_file, bootloader_len, .read_write);
        defer mapped_image.deinit();

        const bootloader_ptr = mapped_bootloader.getPtr();
        const image_ptr = mapped_image.getPtr();

        @memcpy(image_ptr      , bootloader_ptr      , mbr.bootstrap_len);
        // don't overwrite the partition table between 446 and 510
        // separate memcpy so we can do the rest aligned
        @memcpy(image_ptr + 510, bootloader_ptr + 510, 2);
        @memcpy(image_ptr + 512, bootloader_ptr + 512, bootloader_len - 512);
    }
};

fn addUserStep(b: *Builder, target: std.build.Target, mode: std.builtin.Mode, config: *const Config) !void {
    const build_user_step = b.step("user", "Build userspace");
    if (config.combine_tools) {
        const gen_tools_file_step = try b.allocator.create(GenerateToolsSourceStep);
        gen_tools_file_step.* = GenerateToolsSourceStep.init(b);
        const exe = b.addExecutable("maros", "user" ++ std.fs.path.sep_str ++ "combined_root.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
        exe.step.dependOn(&gen_tools_file_step.step);
        inline for (commandLineTools) |commandLineTool| {
            const install_symlink = try b.allocator.create(InstallSymlink);
            install_symlink.* = InstallSymlink.init(b, "maros", .bin, commandLineTool.name);
            install_symlink.step.dependOn(&exe.install_step.?.step);
            build_user_step.dependOn(&install_symlink.step);
        }
    } else {
        inline for (commandLineTools) |commandLineTool| {
            const exe = b.addExecutable(commandLineTool.name, "user" ++ std.fs.path.sep_str ++ "standalone_root.zig");
            exe.setTarget(target);
            exe.setBuildMode(mode);
            exe.addPackage(.{
                .name = "tool",
                .path = .{ .path = "user" ++ std.fs.path.sep_str ++ commandLineTool.name ++ ".zig" },
            });
            exe.install();
            build_user_step.dependOn(&exe.install_step.?.step);
        }
    }
    b.getInstallStep().dependOn(build_user_step);
}

const AllocImageStep = struct {
    step: std.build.Step,
    image_file: []const u8,
    image_len: u64,
    pub fn init(b: *Builder, image_len: u64) AllocImageStep {
        const image_file = b.getInstallPath(.prefix, "maros.img");
        b.pushInstalledFile(.prefix, "maros.img");
        return .{
            .step = std.build.Step.init(.custom, "truncate image file", b.allocator, make),
            .image_file = image_file,
            .image_len = image_len,
        };
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(AllocImageStep, "step", step);
        std.log.debug("allocating image '{s}' of {} bytes", .{self.image_file, self.image_len});
        if (std.fs.path.dirname(self.image_file)) |dirname| {
            try std.fs.cwd().makePath(dirname);
        }
        const file = try std.fs.cwd().createFile(self.image_file, .{ .truncate = false });
        defer file.close();
        try file.setEndPos(self.image_len);
    }
};

fn enforceImageLen(image_file: std.fs.File, expected_len: usize) !void {
    const actual_image_size = try image_file.getEndPos();
    try enforce(
        actual_image_size == expected_len,
        "image file size '{}' != configured image size '{}'",
        .{actual_image_size, expected_len}
    );
}
const ZeroImageStep = struct {
    step: std.build.Step,
    image_file: []const u8,
    image_len: u64,
    pub fn init(b: *Builder, image_len: u64) ZeroImageStep {
        return .{
            .step = std.build.Step.init(.custom, "truncate image file", b.allocator, make),
            .image_file = b.getInstallPath(.prefix, "maros.img"),
            .image_len = image_len,
        };
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(ZeroImageStep, "step", step);
        std.log.debug("zeroing image '{s}'", .{self.image_file});
        const file = try std.fs.cwd().openFile(self.image_file, .{ .write = true });
        defer file.close();
        try enforceImageLen(file, self.image_len);
        const mapped_file = try MappedFile.init(file, self.image_len, .read_write);
        defer mapped_file.deinit();

        @memset(mapped_file.getPtr(), 0, self.image_len);
    }
};

const crystal = struct {
    // crystal is meant to reside in the first 16 sectors of the disk
    pub const reserve_512byte_sector_count = 16;
    pub const reserve_len = reserve_512byte_sector_count * 512;
    pub const kernel_start_512byte_sector = 17;
    pub const kernel_start = kernel_start_512byte_sector * 512;
};

fn getPart1SectorOffset(config: Config) u32 {
    const kernel_reserve = config.crystalBootloaderKernelReserve orelse
        @panic("crystalBootloaderKernelReserve is not set (not supported)");
    // TODO: verify we are using 512 byte sectors
    return crystal.reserve_512byte_sector_count +
        downcast(u32, config.getMinSectorsToHold(kernel_reserve), "MBR sector count");
}

fn downcast(comptime T: type, val: anytype, value_descriptor_for_error: []const u8) T {
    const dest_info = switch (@typeInfo(T)) {
        .Int => |info| info,
        else => @compileError("downcast only supports integer types, got " ++ @typeName(T)),
    };
    std.debug.assert(dest_info.signedness == .unsigned); // only unsigned implemented

    switch (@typeInfo(@TypeOf(val))) {
        .Int => |src_info| {
            std.debug.assert(src_info.signedness == .unsigned); // only unsigned implemented
            if (dest_info.bits >= src_info.bits) {
                @compileError("downcast only goes from larger integer types to smaller ones");
            }
        },
        else => @compileError("downcast only supports integer types, got " ++ @typeName(@TypeOf(val))),
    }
    if (val > std.math.maxInt(T)) {
        std.debug.panic("cannot downcast {s} {} to {s}", .{value_descriptor_for_error, val, @typeName(T)});
    }
    return @intCast(T, val);
}

fn dumpHex(writer: anytype, mem: [*]const u8, width: usize, height: usize) !void {
    var row: usize = 0;
    while (row < height) : (row += 1) {
       var col: usize = 0;
       var prefix: []const u8 = "";
       while (col < width) : (col += 1) {
           try writer.print("{s}{x:0>2}", .{prefix, mem[row * width + col]});
           prefix = " ";
       }
       try std.io.getStdOut().writer().writeAll("\n");
    }
}

const PartitionImageStep = struct {
    step: std.build.Step,
    image_file: []const u8,
    config: *const Config,
    pub fn init(b: *Builder, config: *const Config) PartitionImageStep {
        return .{
            .step = std.build.Step.init(.custom, "truncate image file", b.allocator, make),
            .image_file = b.getInstallPath(.prefix, "maros.img"),
            .config = config,
        };
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(PartitionImageStep, "step", step);
        const file = try std.fs.cwd().openFile(self.image_file, .{ .write = true });
        defer file.close();
        const image_len = self.config.imageSize.byteValue();
        try enforceImageLen(file, image_len);
        std.log.debug("partitioning image '{s}'", .{self.image_file});

        const part1_sector_off = getPart1SectorOffset(self.config.*);
        const part1_sector_cnt = downcast(u32, self.config.getMinSectorsToHold(self.config.rootfsPart.size), "MBR part1 sector count");
        const part2_sector_off = part1_sector_off + part1_sector_cnt;
        const part2_sector_cnt = downcast(u32, self.config.getMinSectorsToHold(self.config.swapSize), "MBR part2 sector count");

        const mapped_file = try MappedFile.init(file, image_len, .read_write);
        defer mapped_file.deinit();
        const image_ptr = mapped_file.getPtr();
        const mbr_ptr = @ptrCast(*mbr.Sector, image_ptr);

        // rootfs partition
        mbr_ptr.partitions[0] = .{
            // workaround issue "Incorrect byte offset and struct size for packed structs" https://github.com/ziglang/zig/issues/2627
            //.status = mbr.PartitionStatuse.bootable;
            //.first_sector_chs = mbr.ChsAddress.zeros;
            .status_and_first_sector_chs =
                [_]u8 { @enumToInt(mbr.PartitionStatus.bootable) } ++
                mbr.ChsAddress.zeros.value,

            // workaround issue "Incorrect byte offset and struct size for packed structs" https://github.com/ziglang/zig/issues/2627
            //.part_type = .linux;
            //.last_sector_chs = mbr.ChsAddress.zeros;
            .part_type_and_last_sector_chs =
                [_]u8 { @enumToInt(mbr.PartitionType.linux) } ++
                mbr.ChsAddress.zeros.value,

            .first_sector_lba = mbr.LittleEndianOf(u32).fromNative(part1_sector_off),
            .sector_count     = mbr.LittleEndianOf(u32).fromNative(part1_sector_cnt),
        };
        // swap partition
        mbr_ptr.partitions[1] = .{
            // workaround issue "Incorrect byte offset and struct size for packed structs" https://github.com/ziglang/zig/issues/2627
            //.status = mbr.PartitionStatuse.bootable;
            //.first_sector_chs = mbr.ChsAddress.zeros;
            .status_and_first_sector_chs =
                [_]u8 { @enumToInt(mbr.PartitionStatus.none) } ++
                mbr.ChsAddress.zeros.value,

            // workaround issue "Incorrect byte offset and struct size for packed structs" https://github.com/ziglang/zig/issues/2627
            //.part_type = .linux;
            //.last_sector_chs = mbr.ChsAddress.zeros;
            .part_type_and_last_sector_chs =
                [_]u8 { @enumToInt(mbr.PartitionType.linuxSwapOrSunContainer) } ++
                mbr.ChsAddress.zeros.value,

            .first_sector_lba = mbr.LittleEndianOf(u32).fromNative(part2_sector_off),
            .sector_count     = mbr.LittleEndianOf(u32).fromNative(part2_sector_cnt),
        };
        mbr_ptr.boot_sig = [_]u8 { 0x55, 0xaa };
    }
};
fn addImageSteps(b: *Builder, config: *const Config, alloc_image_step: *std.build.Step) !void {

    {
        const zero_image_step = try b.allocator.create(ZeroImageStep);
        zero_image_step.* = ZeroImageStep.init(b, config.imageSize.byteValue());
        zero_image_step.step.dependOn(alloc_image_step);
        b.step("zero-image", "Initialize image to zeros (depends on alloc-image)").dependOn(&zero_image_step.step);
    }

    {
        const partition_step = try b.allocator.create(PartitionImageStep);
        partition_step.* = PartitionImageStep.init(b, config);
        partition_step.step.dependOn(alloc_image_step);
        b.getInstallStep().dependOn(&partition_step.step);
        b.step("partition", "Partition the image (depends on alloc-image)").dependOn(&partition_step.step);
    }
}

// import core.stdc.errno;
// import core.stdc.stdlib : exit, alloca;
// import core.stdc.string : memcpy, memset;
//
// import std.array : join;
// import std.string : lineSplitter, strip, stripLeft, startsWith, endsWith, indexOf;
// import std.conv : to, ConvException;
// import std.format : format, formattedWrite;
// import std.algorithm : skipOver, canFind, map;
// import std.datetime : SysTime;
// import std.path : isAbsolute, absolutePath, buildNormalizedPath;
// import std.file : exists, readText, rmdir, timeLastModified;
// import std.process : executeShell, environment;
//
// import mar.flag;
// import mar.enforce;
fn enforce(condition: bool, comptime fmt: []const u8, args: anytype) !void {
    if (!condition) {
        std.log.err(fmt, args);
        return error.AlreadyReported;
    }
}

// import mar.endian;
// import mar.array : acopy;
// import mar.sentinel : SentinelArray, makeSentinel, verifySentinel, lit;
// import mar.print : formatHex, sprintMallocSentinel;
// import mar.c;
// import mar.ctypes : off_t, mode_t;
// import mar.conv : tryParseEnum;
// import mar.typecons : Nullable;
// import mar.file : getFileSize, tryGetFileMode, fileExists, open, close,
//     OpenFlags, OpenAccess, OpenCreateFlags,
//     S_IXOTH,
//     S_IWOTH,
//     S_IROTH,
//     S_IRWXO,
//     S_IXGRP,
//     S_IWGRP,
//     S_IRGRP,
//     S_IRWXG,
//     S_IXUSR,
//     S_IWUSR,
//     S_IRUSR,
//     S_IRWXU;
// import mar.linux.filesys : mkdir;
// static import mar.path;
// import mar.findprog : findProgram, usePath;
// import mar.process : ProcBuilder;
// import mar.cmdopt;
// import mbr = mar.disk.mbr;
// // TODO: replace this linux-specific import
// //import mar.linux.file : open, close;
// import mar.linux.capability : CAP_TO_MASK, CAP_SYS_ADMIN, CAP_SYS_CHROOT;
//
// import common;
// import compile;
// import elf;
//
// void log(T...)(T args)
// {
//     import mar.stdio;
//     stdout.writeln("[BUILD] ", args);
// }
// void logError(T...)(T args)
// {
//     import mar.stdio;
//     stdout.writeln("Error: ", args);
// }
//
// enum DefaultDirMode = S_IRWXU | S_IRWXG | S_IROTH;
//
// //
// // TODO: prefix all information from this tool with [BUILD] so
// //       it is easy to distinguish between output from this tool
// //       and output from other tools.
// //       do this by not importing std.stdio globally
// //
//
const CommandList = struct {
    commands: []const Command,
    desc: []const u8,
};
const commandLists = [_]CommandList {
    CommandList {
        .commands = &buildCommands,
        .desc = "Build Commands",
    },
//     immutable CommandList(buildCommands,
//         "Build Commands"),
//     immutable CommandList(diskSetupCommands,
//         "Disk Setup Commands (in the same order as they would be invoked)"),
//     immutable CommandList(utilityCommands,
//         "Some Generic Utility Commands"),
};
//
// string marosRelativeShortPath(string path)
// {
//     return shortPath(path, mar.path.dirName(__FILE_FULL_PATH__));
// }
//
// void logSymlink(string linkTarget, string linkFile)
// {
//     import mar.linux.file : stat_t;
//     import mar.linux.filesys : readlink, symlink, unlink;
//     import mar.linux.syscall : sys_lstat;
//
//     mixin tempCString!("linkTargetCStr", "linkTarget");
//     mixin tempCString!("linkFileCStr", "linkFile");
//
//     {
//         stat_t stat = void;
//         const statResult = sys_lstat(linkFileCStr.str, &stat);
//         if (!statResult.failed)
//         {
//             auto currentValue = new char[linkTarget.length];
//             if (readlink(linkFileCStr.str, currentValue).passed)
//             {
//                 if (currentValue == linkTarget)
//                 {
//                     log("symlink '", linkFile, "' -> '", linkTarget, "' (already exists)");
//                     return;
//                 }
//             }
//             const unlinkResult = unlink(linkFileCStr.str);
//             if (unlinkResult.failed)
//             {
//                 logError("link '", linkFile, "' already exists with wrong target but could not unlink it: ", unlinkResult);
//                 exit(1);
//             }
//         }
//     }
//     {
//         log("symlink '", linkFile, "' -> '", linkTarget, "'");
//         const result = symlink(linkTargetCStr.str, linkFileCStr.str);
//         if (result.failed)
//         {
//             logError("symlink '", linkFile, "' -> '", linkTarget, "' failed: ", result);
//             exit(1);
//         }
//     }
// }
//
// / **
// Makes sure the the directory exists with the given `mode`.  Creates
// it if it does not exist.
// */
// void logMkdir(string pathname, mode_t mode = DefaultDirMode)
// {
//     mixin tempCString!("pathnameCStr", "pathname");
//
//     // get the current state of the pathnameCStr
//     auto currentMode = tryGetFileMode(pathnameCStr.str);
//     if (currentMode.failed)
//     {
//         log("mkdir \"", pathnameCStr.str, "\" mode=0x", mode.formatHex);
//         auto result = mkdir(pathnameCStr.str, mode);
//         if (result.failed)
//         {
//             logError("mkdir failed, returned ", result.numval);
//             exit(1);
//         }
//     }
//     else
//     {
//     /*
//         currently not really working as I expect...need to look into this
//         if (currentMode.value != mode)
//         {
//             stderr.write("Error: expected path \"", pathnameCStr, "\" mode to be 0x",
//                 mode.formatHex, " but it is 0x", currentMode.value.formatHex, "\n");
//             exit(1);
//         }
//         */
//     }
// }
// void logCopy(From, To)(From from, To to, Flag!"asRoot" asRoot)
// {
//     import std.file : copy;
//     exec(format("%scp %s %s", asRoot ? "sudo " : "", from.formatFile, to.formatFile));
// }
//
// void usage()
// {
//     import std.stdio : writeln, writefln;
//     writeln ("build.d [-C <dir>] <command>");
//     foreach (ref commandList; commandLists)
//     {
//         writeln();
//         writeln(commandList.desc);
//         foreach (ref cmd; commandList.commands)
//         {
//             writefln(" %-20s %s", cmd.name, cmd.description);
//         }
//     }
// }
//
// int main(string[] args)
// {
//     try { return tryMain(args); }
//     catch(EnforceException) { return 1; }
// }
// int tryMain(string[] args)
// {
//     args = args[1 .. $];
//     string configOption;
//     {
//         size_t newArgsLength = 0;
//         scope (exit) args = args[0 .. newArgsLength];
//         for (size_t i = 0; i < args.length; i++)
//         {
//             auto arg = args[i];
//             if (arg[0] != '-')
//                 args[newArgsLength++] = arg;
//             // TODO: implement -C
//             else
//             {
//                 logError("unknown option \"", arg, "\"");
//                 return 1;
//             }
//         }
//     }
//     if (args.length == 0)
//     {
//         usage();
//         return 1;
//     }
//
//     import std.stdio;
//
//     const commandToInvoke = args[0];
//     args = args[1 .. $];
//    for (&commandLists) |commandList| {
//        std.log.debug("commandList count={} desc={s}", .{commandList.commands.len, commandList.desc});
//         for (size_t cmdIndex; cmdIndex < commandList.commands.length; cmdIndex++)
//         {
//             auto cmd = &commandList.commands[cmdIndex];
//             if (commandToInvoke == cmd.name)
//             {
//                 const result = cmd.func(args);
//                 if (result == 0)
//                 {
//                     writeln("--------------------------------------------------------------------------------");
//                     cmdIndex++;
//                     if (!cmd.inSequence || cmdIndex >= commandList.commands.length)
//                     {
//                         writeln("Success");
//                         return 0;
//                     }
//                     cmd = &commandList.commands[cmdIndex];
//                     if (!cmd.inSequence)
//                     {
//                         writeln("Success");
//                         return 0;
//                     }
//                     writeln("Success, next step(s) are:");
//                     for (;;)
//                     {
//                         writefln("    '%s'%s", cmd.name, cmd.isOptional ? " (optional)" : "");
//                         cmdIndex++;
//                         if (cmdIndex >= commandList.commands.length)
//                             break;
//                         cmd = &commandList.commands[cmdIndex];
//                         if (!cmd.inSequence)
//                             break;
//                     }
//                 }
//                 return result;
//             }
//         }
//    }
//
//     logError("unknown command '", commandToInvoke, "'");
//     return 1;
//
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
        return @intCast(u64, self.value) << self.unit.getInfo().byteShift;
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

//    auto formatFdisk() const
//    {
//        static struct Formatter
//        {
//            const(MemorySize) memorySize;
//            void toString(scope void delegate(const(char)[]) sink)
//            {
//                formattedWrite(sink, "%s%s", memorySize.value,
//                    memorySize.unit.info.qemuPostfix);
//            }
//        }
//        return Formatter(this);
//    }
};

// struct KernelPaths
// {
//     string image;
// }
// struct Mounts
// {
//     string rootfs;
//     string rootfsAbsolute;
// }
//
// struct LoopPartFiles
// {
//     string rootfs;
//     string swap;
// }
//
// // crystal is meant to reside in the first 16 sectors
// // of the disk
// enum CrystalReserveSectorCount = 16;
// enum CrystalReserveByteSize = CrystalReserveSectorCount * 512;
// enum CrystalKernelStartSector = 17;
// enum CrystalKernelStartByteOffset = 17 * 512;
// struct CrystalBootloaderFiles
// {
//     string dir;
//     string source;
//     string list;
//     string binary;
//     string script;
// }

//
// auto appendPath(T, U)(T dir, U path)
// {
//     if (dir.length == 0)
//         return path;
//     if (path.length == 0)
//         return dir;
//     assert(dir[$-1] != '/', "no paths should end in '/'");
//     assert(path[0]  != '/', "cannot append an absolute path to a relative one");
//     return dir ~ "/" ~ path;
// }
//
// size_t asSizeT(ulong value, lazy string errorPrefix, lazy string errorPostfix)
// {
//     if (value > size_t.max)
//     {
//         import std.stdio;
//         writeln("Error: ", errorPrefix, value, errorPostfix);
//         exit(1);
//     }
//     return cast(size_t)value;
// }
//
// bool isDigit(char c) { return c <= '9' && c >= '0'; }
fn parseConfig(allocator: *std.mem.Allocator) !Config {
    const filename = "maros.config";
    const text = blk: {
        // TODO: shouldn't use cwd to open this file!!!
        //       or maybe use self.builder.pathFromRoot(filename)???
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    };
    // NOTE: no need to free text memory
    var parser = ConfigParser {
        .filename = filename,
        .text = text,
        .lineNumber = 1,
    };
    const config = parser.parse();
    return config;
}

// bool prompt(string msg)
// {
//     import std.stdio;
//     for (;;)
//     {
//         write(msg, " (y/n) ");
//         stdout.flush();
//         auto response = stdin.readln().strip();
//         if (response == "y")
//             return true; // yes
//         if (response == "n")
//             return false; // no
//     }
// }
//
// pragma(inline) uint asUint(ulong value)
// in { assert(value <= uint.max, "value too large"); } do
// {
//     return cast(uint)value;
// }
//
//
// string tryGetImageLoopFile(ref const Config config)
// {
//     log("checking if image '", config.imageFile, "' is looped");
//     const command = format("sudo losetup -j %s", config.imageFile.formatFile);
//     auto output = exec(command);
//     if (output.length == 0)
//         return null;
//
//     auto colonIndex = output.indexOf(":");
//     enforce(colonIndex >= 0, format("output of '%s' (see above) did not have a colon ':' to delimit end of loop filename", command));
//     return output[0 .. colonIndex];
// }
// string loopImage(ref const Config config)
// {
//     auto loopFile = tryGetImageLoopFile(config);
//     if (loopFile)
//     {
//         log("image file '", config.imageFile, "' is already looped to '", loopFile, "'");
//     }
//     else
//     {
//         log("image file '", config.imageFile, "' is not looped, looping it now");
//         exec(format("sudo losetup -f -P %s", config.imageFile.formatFile));
//         loopFile = tryGetImageLoopFile(config);
//         enforce(loopFile !is null, "attempted to loop the image but could not find the loop file");
//         log("looped image '", config.imageFile, "' to '", loopFile, "'");
//     }
//     log("Loop Partitions:");
//     run(format("ls -l %sp*", loopFile));
//     return loopFile;
// }
// void unloopImage(string loopFile)
// {
//     log("unlooping image...");
//     exec(format("sudo losetup -d %s", loopFile.formatFile));
// }
//
// struct Rootfs
// {
//     static ulong getPartitionOffset(ref const Config config)
//     {
//         return CrystalReserveSectorCount + config.getMinSectorsToHold(
//             config.crystalBootloaderKernelReserve); // kernel reserve
//     }
//     static struct IsMountedResult
//     {
//         bool isMounted;
//         string notMountedReason;
//     }
//     static IsMountedResult rootfsIsMounted(ref const Config config, ref const Mounts mounts)
//     {
//         log("checking if rootfs is mounted to '", mounts.rootfs, "'");
//         if (!exists(mounts.rootfs))
//         {
//             return IsMountedResult(false, format("mount dir '%s' does not exist", mounts.rootfs));
//         }
//         auto output = exec("sudo mount -l", mounts.rootfsAbsolute);
//         if (output.length == 0)
//         {
//             return IsMountedResult(false, format("mount dir '%s' is not in `mount -l` output", mounts.rootfs));
//         }
//         return IsMountedResult(true);
//     }
//     static void mount(ref const Config config, ref const Mounts mounts)
//     {
//         {
//             const result = rootfsIsMounted(config, mounts);
//             if (result.isMounted)
//             {
//                 log("rootfs is already mounted to '", mounts.rootfs, "'");
//                 return;
//             }
//         }
//         log("rootfs is not mounted");
//
//         if (!exists(mounts.rootfs))
//             logMkdir(mounts.rootfs);
//
//         exec(format("sudo mount -t %s -o loop,rw,offset=%s %s %s",
//             config.rootfsType, Rootfs.getPartitionOffset(config) * 512,
//             config.imageFile.formatFile, mounts.rootfs.formatDir));
//         exec(format("sudo chown `whoami` %s", mounts.rootfs.formatDir));
//         /*
//         import mar.filesys : mount;
//         mixin tempCString!("imageFileCStr", "config.imageFile");
//         mixin tempCString!("targetCStr", "mounts.rootfs");
//         mixin tempCString!("typeCStr", "config.rootfsType");
//         auto options = format("loop,rw,offset=%s", Rootfs.getPartitionOffset(config) * 512);
//         mixin tempCString!("optionsCStr", "options");
//         log("mount -t ", typeCStr.str, " -o ", optionsCStr.str, " ", imageFileCStr.str, " ", targetCStr.str);
//         auto result = mount(imageFileCStr.str, targetCStr.str, typeCStr.str, 0, optionsCStr.str.raw);
//         if (result != 0)
//         {
//             logError("mount failed, returned ", result);
//             exit(1);
//         }
//         */
//     }
//     static void unmount(ref const Config config, ref const Mounts mounts)
//     {
//         {
//             const result = rootfsIsMounted(config, mounts);
//             if (!result.isMounted)
//             {
//                 log("rootfs is not mounted '", mounts.rootfs, "'");
//                 return;
//             }
//         }
//         log("rootfs is mounted...unmounting");
//         exec(format("sudo umount %s", mounts.rootfs));
//         exec(format("sudo rmdir %s", mounts.rootfs));
//     }
// }
//
const SetRootSuid = enum { no, yes };

const CommandLineTool = struct {
    name: []const u8,
    setRootSuid: SetRootSuid = .no,
    versions: ?[]const []const u8 = null,
    caps: u32 = 0,
};

const commandLineTools = [_]CommandLineTool {
    CommandLineTool { .name = "init" },
//     CommandLineTool("msh"),
//     CommandLineTool("env"),
    CommandLineTool { .name = "mount" },
//     CommandLineTool("umount"),
//     CommandLineTool("pwd"),
//     CommandLineTool("ls"),
//     CommandLineTool("mkdir"),
//     CommandLineTool("chvt"),
//     CommandLineTool("fgconsole"),
    CommandLineTool { .name = "cat" },
//     CommandLineTool("openvt"),
//     CommandLineTool("insmod"),
//     CommandLineTool("masterm"),
//     CommandLineTool("medit", No.setRootSuid, ["NoExit"]),
//     CommandLineTool("rex", No.setRootSuid, null, CAP_TO_MASK(CAP_SYS_ADMIN) | CAP_TO_MASK(CAP_SYS_CHROOT)),
//     CommandLineTool("rexrootops", Yes.setRootSuid),
};
//
// /**
// Returns: 0 on success
// */
// int installRootfs(string target, bool forWsl)
// {
//     // create the directory structure
//     logMkdir(target ~ "/dev", S_IRWXU | S_IRWXG | (S_IROTH | S_IXOTH));
//     logMkdir(target ~ "/proc", (S_IRUSR | S_IXUSR) | (S_IRGRP | S_IXGRP) | (S_IROTH | S_IXOTH));
//     logMkdir(target ~ "/sys", (S_IRUSR | S_IXUSR) | (S_IRGRP | S_IXGRP) | (S_IROTH | S_IXOTH));
//     logMkdir(target ~ "/var", S_IRWXU | (S_IRGRP | S_IXGRP) | (S_IROTH | S_IXOTH));
//     logMkdir(target ~ "/tmp", S_IRWXU | S_IRWXG | S_IRWXO);
//     //logMkdir(target ~ "/root", Yes.asRoot); // not sure I need this one
//     if (forWsl)
//     {
//         // the /bin and /etc directories are required for WSL distros
//         logMkdir(target ~ "/bin", S_IRWXU | S_IRWXG | S_IRWXO);
//         logSymlink("/sbin/msh", target ~ "/bin/msh");
//         logMkdir(target ~ "/etc", S_IRWXU | S_IRWXG | S_IRWXO);
//         {
//             auto wslpathFilename = target ~ "/bin/wslpath";
//             mixin tempCString!("wslpathFilenameCStr", "wslpathFilename");
//             auto file = open(wslpathFilenameCStr.str, OpenFlags(OpenAccess.writeOnly, OpenCreateFlags.creat));
//             file.write("/sbin/init");
//             file.close();
//             run("sudo chmod 0777 " ~ wslpathFilename);
//         }
//         {
//             auto passwdFilename = target ~ "/etc/passwd";
//             mixin tempCString!("passwdFilenameCStr", "passwdFilename");
//             auto passwd = open(passwdFilenameCStr.str, OpenFlags(OpenAccess.writeOnly, OpenCreateFlags.creat));
//             passwd.write("root:x:0:0:root:/:/bin/msh\n");
//             passwd.close();
//             run("sudo chmod 0777 " ~ passwdFilename);
//         }
//     }
//
// /*
//     // used for the terminfo capability database
//     {
//         const targetTerminfo = target ~ "/terminfo";
//         const sourceTerminfo = "terminfo";
//         logMkdir(targetTerminfo, S_IRWXU | S_IRWXG | S_IROTH);
//         exec(format("cp %s/* %s", sourceTerminfo, targetTerminfo));
//     }
// */
//     const targetSbinPath = target ~ "/sbin";
//     logMkdir(targetSbinPath, S_IRWXU | S_IRWXG | S_IRWXO);
//
//     const sourcePath = "rootfs";
//     const sourceSbinPath = sourcePath ~ "/sbin";
//     foreach (ref tool; commandLineTools)
//     {
//         const exe = sourceSbinPath ~ "/" ~ tool.name;
//         if (!exists(exe))
//         {
//             logError("cannot find '", exe, "', have you run 'buildUser'?");
//             return 1; // fail
//         }
//         logCopy(exe, targetSbinPath ~ "/" ~ tool.name, Yes.asRoot);
//     }
//     return 0; // success
// }
//
const CommandFlags = enum(u2) {
    none       = 0x00,
    inSequence = 0x01,
    optional   = 0x02,
};
const cmdNoFlags = CommandFlags.none;
const cmdInSequence = CommandFlags.inSequence;
const cmdInSequenceOptional = CommandFlags.inSequence | CommandFlags.optional;

const CommandFuncError = anyerror;
//error {
//    AlreadyReported,
//};

const Command = struct {
    name: []const u8,
    description: []const u8,
    flags: CommandFlags,
    func: fn(args: []const []const u8) CommandFuncError!c_int,
    pub fn inSequence(self: Command) bool {
        return (self.flags & CommandFlags.inSequence) != 0;
    }
    pub fn isOptional(self: Command) bool {
        return (self.flags & CommandFlags.optional) != 0;
    }
};

// =============================================================================
// Build Commands
// =============================================================================

fn installTools(args: []const []const u8) CommandFuncError!c_int {
    try enforce(args.len == 0, "installTools requires 0 arguments but got {}", .{args.len});
    //run("sudo apt-get install git fakeroot build-essential" ~
    //    " ncurses-dev xz-utils libssl-dev bc libelf-dev flex bison gcc" ~
    //    " make nasm");
    return 0;
}

fn cloneKernel(args: []const []const u8) CommandFuncError!c_int {
    try enforce(args.len == 0, "clone-kernel requires 0 arguments but got {}", .{args.len});

    const config = try parseConfig(std.heap.page_allocator);
    _ = config;
//
//    if (!config.kernelRepo)
//    {
//        logError("cannot 'cloneRepo' because no 'kernelRepo' is configured");
//        return 1;
//    }
//
//    if (exists(config.kernelPath))
//    {
//        log("kernel '", config.kernelPath, "' already exists");
//    }
//    else
//    {
//        // TODO: move this to config.txt
//        run(format("git clone %s %s",
//            config.kernelRepo.formatQuotedIfSpaces,
//            config.kernelPath.formatQuotedIfSpaces));
//    }
    return 0;
}

const buildCommands = [_]Command { Command {
    .name = "installTools",
    .description = "install tools to build",
    .flags = cmdNoFlags,
    .func = installTools,
}, Command {
    .name = "clone-kernel",
    .description = "clone the linux kernel",
    .flags = cmdNoFlags,
    .func = cloneKernel,
},

// Command("cloneKernel", "clone the linux kernel", cmdNoFlags, function(string[] args)
// {
// }),
//
// Command("cloneBootloader", "clone the bootloader", cmdNoFlags, function(string[] args)
// {
//     enforce(args.length == 0, "clonerBootloader requires 0 arguments");
//     const config = parseConfig();
//
//     auto repo = "crystal";
//     if (exists("crystal"))
//     {
//         log("crystal repo '", repo, "' already exists");
//     }
//     else
//     {
//         run(format("git clone %s %s", "https://github.com/marler8997/crystal", repo));
//     }
//     return 0;
// }),
//
// Command("buildBootloader", "build the bootloader", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "buildBootloader requires 0 arguments");
//     const config = parseConfig();
//
//     const files = config.getCrystalBootloaderFiles();
//     run(format("nasm -o %s -l %s %s",
//         files.binary.formatFile, files.list.formatFile,
//         files.source.formatFile));
//
//     return 0;
// }),
//
// Command("buildUser", "build userspace of the os", cmdInSequence, function(string[] args)
// {
//     bool force;
//     foreach (arg; args)
//     {
//         if (arg == "force")
//             force = true;
//         else
//         {
//             logError("unknown argument '", arg, "'");
//             return 1; // error
//         }
//     }
//     const config = parseConfig();
//
//     enum Mode
//     {
//         debug_,
//         release,
//     }
//     //auto mode = Mode.debug_;
//     auto mode = Mode.release;
//
//     string compiler = config.compiler ~ CompilerArgs()
//         .version_("NoStdc")
//         .conf("")
//         .betterC
//         //.inline
//         .toString;
//
//     final switch (mode)
//     {
//     case Mode.debug_ : compiler ~= " -debug -g"; break;
//     case Mode.release: compiler ~= " -release -O -inline"; break;
//     }
//
//     const userSourcePath   = marosRelativeShortPath("user");
//     const rootfsPath = "rootfs";
//     const sbinPath   = rootfsPath ~ "/sbin";
//     const objPath  = "obj";
//     logMkdir(rootfsPath);
//     logMkdir(sbinPath);
//     logMkdir(objPath);
//
//     const druntimePath = marosRelativeShortPath("mar/druntime");
//     const marlibPath = marosRelativeShortPath("mar/src");
//
//     const includePaths = [
//         druntimePath,
//         marlibPath,
//         userSourcePath,
//     ];
//
//     foreach (ref tool; commandLineTools)
//     {
//         const src = userSourcePath ~ "/" ~ tool.name ~ ".d";
//         const toolObjPath  = "obj/" ~ tool.name;
//         logMkdir(toolObjPath);
//
//         const binaryFilename = (sbinPath ~ "/" ~ tool.name).makeSentinel;
//         const buildJsonFilename = (toolObjPath ~ "/info.json").makeSentinel;
//
//         bool needsBuild = true;
//         if (!force && fileExists(buildJsonFilename.ptr))
//         {
//             auto buildFiles = tryGetBuildFiles(buildJsonFilename, src, includePaths, toolObjPath);
//             if (buildFiles)
//             {
//                 auto binaryTime = binaryFilename.array.timeLastModified(SysTime.min);
//                 if (binaryTime > SysTime.min)
//                 {
//                     needsBuild = false;
//                     foreach (buildFile; buildFiles)
//                     {
//                         if (buildFile.src.timeLastModified > binaryTime)
//                         {
//                             needsBuild = true;
//                             break;
//                         }
//                     }
//                 }
//             }
//         }
//
//         if (needsBuild)
//         {
//             auto compilerArgs = CompilerArgs();
//             if (tool.versions)
//             {
//                 foreach (version_; tool.versions)
//                 {
//                     compilerArgs.version_(version_);
//                 }
//             }
//             run(compiler ~ compilerArgs
//                 .includeImports("object") // include the 'object' module
//                 .includeImports(".")      // include by default
//                 .noLink
//                 .outputDir(toolObjPath)
//                 .preserveOutputPaths
//                 .jsonFile(buildJsonFilename.array)
//                 .jsonIncludes("semantics")
//                 .includePaths(includePaths)
//                 .source(src)
//                 .toString);
//             auto buildFiles = tryGetBuildFiles(buildJsonFilename, src, includePaths, toolObjPath);
//
//             bool forceGoldLinker = false;
//             string linker = "ld";
//             if (forceGoldLinker)
//             {
//                 linker = "/usr/bin/gold --strip-lto-sections";
//             }
//
//             run(linker ~ " --gc-sections -static --output " ~ binaryFilename.array ~ " " ~ buildFiles.map!(s => s.obj).join(" "));
//
//             if (tool.setRootSuid)
//             {
//                 run("sudo chown root:root " ~ binaryFilename.array);
//                 run("sudo chmod +s " ~ binaryFilename.array);
//             }
//             if (tool.caps)
//             {
//                 string prefix = "";
//                 string capString = "";
//
//                 uint caps = tool.caps;
//                 if (caps & CAP_TO_MASK(CAP_SYS_ADMIN)) {
//                     caps &= ~CAP_TO_MASK(CAP_SYS_ADMIN);
//                     capString ~= prefix ~ "cap_sys_admin";
//                     prefix = ",";
//                 }
//                 if (caps & CAP_TO_MASK(CAP_SYS_CHROOT)) {
//                     caps &= ~CAP_TO_MASK(CAP_SYS_CHROOT);
//                     capString ~= prefix ~ "cap_sys_chroot";
//                     prefix = ",";
//                 }
//                 if (caps) {
//                     logError("tool caps contain unhandled flags 0x", caps.formatHex);
//                     return 1; // fail
//                 }
//                 run("sudo setcap " ~ capString ~ "+ep " ~ binaryFilename.array);
//             }
//         }
//         else
//         {
//             log(binaryFilename.array, " is up-to-date");
//         }
//     }
//     return 0;
// }),
//
}; // end of buildCommands
//
// // =============================================================================
// // Disk Setup Commands
// // =============================================================================
// immutable diskSetupCommands = [
//
// Command("allocImage", "allocate a file for the disk image", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "allocImage requies 0 arguments");
//     const config = parseConfig();
//     if (exists(config.imageFile))
//     {
//         if (!prompt(format("would you like to overrwrite the existing image '%s'?", config.imageFile)))
//             return 1;
//     }
//
//     /*
//     mixin tempCString!("imageFileCStr", "config.imageFile");
//     auto fd = open(imageFileCStr.str, OpenFlags(OpenAccess.writeOnly, OpenCreateFlags.creat));
//     auto result = fallocate(fd,...
//     close(fd);
//     */
//
//     run(format("truncate -s %s %s", config.imageSize.byteValue, config.imageFile.formatFile));
//     return 0;
// }),
//
// Command("zeroImage", "initialize the disk image to zero", cmdInSequenceOptional, function(string[] args)
// {
//     enforce(args.length == 0, "allocImage requies 0 arguments");
//     const config = parseConfig();
//
//     const imageFileSize = getFileSize(config.imageFile).asSizeT("file size ", " is too large to map");
//     enforce(imageFileSize == config.imageSize.byteValue,
//         format("image file size '%s' != configured image size '%s'",
//             imageFileSize, config.imageSize.byteValue));
//
//     log("zeroing image of ", imageFileSize, " bytes...");
//     auto mappedImage = config.mapImage(0, imageFileSize, Yes.writeable);
//     memset(mappedImage.ptr, 0, imageFileSize);
//     mappedImage.unmapAndClose();
//     return 0;
// }),
//
// Command("partition", "partition the disk image", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "partition requires 0 arguments");
//     const config = parseConfig();
//     enforce(exists(config.imageFile),
//         format("image file '%s' does not exist, have you run 'allocImage'?", config.imageFile));
//
//
//     ulong part1SectorOffset = Rootfs.getPartitionOffset(config);
//     ulong part1SectorCount  = config.getMinSectorsToHold(config.rootfsSize);
//     ulong part2SectorOffset = part1SectorOffset + part1SectorCount;
//     ulong part2SectorCount  = config.getMinSectorsToHold(config.swapSize);
//
//     auto mappedImage = config.mapImage(0, 512, Yes.writeable);
//     auto mbrPtr = cast(mbr.OnDiskFormat*)mappedImage.ptr;
//
//     //
//     // rootfs partition
//     //
//     mbrPtr.partitions[0].status = mbr.PartitionStatus.bootable;
//     mbrPtr.partitions[0].firstSectorChs.setDefault();
//     mbrPtr.partitions[0].type = mbr.PartitionType.linux;
//     mbrPtr.partitions[0].lastSectorChs.setDefault();
//     mbrPtr.partitions[0].firstSectorLba = part1SectorOffset.asUint.toLittleEndian;
//     mbrPtr.partitions[0].sectorCount    = part1SectorCount.asUint.toLittleEndian;
//     //
//     // swap partition
//     //
//     mbrPtr.partitions[1].status = mbr.PartitionStatus.none;
//     mbrPtr.partitions[1].firstSectorChs.setDefault();
//     mbrPtr.partitions[1].type = mbr.PartitionType.linuxSwapOrSunContainer;
//     mbrPtr.partitions[1].lastSectorChs.setDefault();
//     mbrPtr.partitions[1].firstSectorLba = part2SectorOffset.asUint.toLittleEndian;
//     mbrPtr.partitions[1].sectorCount    = part2SectorCount.asUint.toLittleEndian;
//
//     mbrPtr.setBootSignature();
//
//     mappedImage.unmapAndClose();
//
// /+
//     run(format("sudo parted %s mklabel msdos", config.imageFile.formatFile));
//
//     auto p1Kb = 1024;
//     auto p2Kb = p1Kb + config.rootfsSize.kbValue;
//     auto p3Kb = p2Kb + config.swapSize.kbValue;
//
//     run(format("sudo parted %s mkpart primary %s %sKiB %sKiB",
//         config.imageFile.formatFile, config.rootfsType, p1Kb, p2Kb));
//     run(format("sudo parted %s mkpart primary linux-swap %sKiB %sKiB",
//         config.imageFile.formatFile, p2Kb, p3Kb));
//     run(format("sudo parted %s set 1 boot on", config.imageFile.formatFile));
//     run(format("sudo parted %s print", config.imageFile.formatFile));
// +/
//     return 0;
// }),
//
// Command("makefs", "make the filesystems", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "makefs requires 0 arguments");
//     const config = parseConfig();
//
//     {
//         auto loopFile = loopImage(config);
//         scope(exit) unloopImage(loopFile);
//         //const loopFile = getImageLoopFile(config);
//         const loopPartFiles = config.getLoopPartFiles(loopFile);
//         run(format("sudo mkfs -t ext4 %s", loopPartFiles.rootfs.formatFile));
//         run(format("sudo mkswap %s", loopPartFiles.swap.formatFile));
//     }
//     return 0;
// }),
//
// Command("installBootloader", "install the bootloader", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "install requires 0 arguments");
//     const config = parseConfig();
//
//     const files = config.getCrystalBootloaderFiles();
//     enforce(exists(files.binary), format(
//         "bootloader binary '%s' does not exist, have you run 'buildBootloader'?",
//         files.binary));
//     mixin tempCString!("binaryTempCStr", "files.binary");
//     const bootloaderSize = getFileSize(binaryTempCStr.str).asSizeT("bootloader image size ", " is too big to map");
//     log("bootloader file is ", bootloaderSize, " bytes");
//     enforce(bootloaderSize <= CrystalReserveByteSize,
//         format("bootloader is too large (%s bytes, max is %s bytes)", bootloaderSize, CrystalReserveByteSize));
//     auto mappedImage = config.mapImage(0, CrystalReserveByteSize, Yes.writeable);
//     {
//         auto bootloaderImage = MappedFile.openAndMap(binaryTempCStr.str, 0, mbr.BootstrapSize, No.writeable);
//         log("copying bootsector code (", mbr.BootstrapSize, " bytes)...");
//         memcpy(mappedImage.ptr, bootloaderImage.ptr, mbr.BootstrapSize);
//         if (bootloaderSize > 512)
//         {
//             const copySize = bootloaderSize - 512;
//             log("copying ", copySize, " more bytes after the boot sector...");
//             acopy(mappedImage.ptr + 512, bootloaderImage.ptr + 512, copySize);
//             //memcpy(mappedImage.ptr + 512, bootloaderImage.ptr + 512, copySize);
//         }
//         else
//         {
//             log("all code is within the boot sector");
//         }
//         bootloaderImage.unmapAndClose();
//     }
//     {
//         const zeroSize = CrystalReserveByteSize - bootloaderSize;
//         log("zeroing the rest of the crystal reserved sectors (", zeroSize, " bytes)...");
//         memset(mappedImage.ptr + bootloaderSize, 0, zeroSize);
//     }
//     mappedImage.unmapAndClose();
//
//     log("Succesfully installed the crystal bootloader");
//     return 0;
// }),
//
// Command("installKernelCmd", "install the kernel command line", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "install requires 0 arguments");
//     const config = parseConfig();
//
//     const files = config.getCrystalBootloaderFiles();
//     enforce(exists(files.script), format(
//         "crystal script '%s' does not exist", files.script));
//
//     run(format("%s set-kernel-cmd-line %s %s",
//         files.script, config.imageFile, config.kernelCommandLine));
//     log("Succesfully installed the kernel command line for crystal to use");
//     return 0;
// }),
//
// Command("installKernel", "install the kernel to the rootfs", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "installKernel requires 0 arguments");
//     const config = parseConfig();
//
//     const kernelPaths = config.getKernelPaths();
//     if (!exists(kernelPaths.image))
//     {
//         logError("kernel image '", kernelPaths.image, "' does not exist, have you built the kernel?");
//         return 1;
//     }
//
//     if (true /*config.bootloader == Bootloader.crystal*/)
//     {
//         // kernel gets installed starting at sector 17 of the disk
//         mixin tempCString!("kernelPathTempCStr", "kernelPaths.image");
//         const kernelImageSize = getFileSize(kernelPathTempCStr.str)
//             .asSizeT("kernel image size ", " is too big to map");
//         log("kernel image is \"", kernelPaths.image, "\" is ", kernelImageSize, " bytes");
//         auto kernelImageMap = MappedFile.openAndMap(kernelPathTempCStr.str, 0, kernelImageSize, No.writeable);
//         auto diskImageMap = config.mapImage(0, CrystalKernelStartByteOffset + kernelImageSize, Yes.writeable);
//
//         log("Copying ", kernelImageSize, " bytes from kernel image to disk image...");
//         memcpy(diskImageMap.ptr + CrystalKernelStartByteOffset, kernelImageMap.ptr, kernelImageSize);
//
//         diskImageMap.unmapAndClose();
//         kernelImageMap.unmapAndClose();
//     }
//     else
//     {
//         const mounts = config.getMounts();
//
//         Rootfs.mount(config, mounts);
//         scope(exit) Rootfs.unmount(config, mounts);
//
//         const rootfsBoot = mounts.rootfs ~ "/boot";
//         logMkdir(rootfsBoot);
//         run(format("sudo cp %s %s", kernelPaths.image, rootfsBoot));
//     }
//     log("Succesfully installed kernel");
//     return 0;
// }),
//
// Command("installRootfs", "install files/programs to rootfs", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "installRootfs requires 0 arguments");
//     const config = parseConfig();
//     const mounts = config.getMounts();
//
//     Rootfs.mount(config, mounts);
//     scope(exit) Rootfs.unmount(config, mounts);
//
//     return installRootfs(mounts.rootfs, false);
// }),
//
// ]; // End of diskSetupCommands
//
// // =============================================================================
// // Utility Commands
// // =============================================================================
// immutable utilityCommands = [
//
// Command("status", "try to get the current status of the configured image", cmdNoFlags, function(string[] args)
// {
//     logError("status command not implemented");
//     return 1;
// }),
//
// Command("installFile", "Install one of more files <src>[:<dst>] or <src>[:<dir>/]", cmdNoFlags, function(string[] args)
// {
//     if (args.length == 0)
//     {
//         logError("please supply one or more files");
//         return 1;
//     }
//     const config = parseConfig();
//     const mounts = config.getMounts();
//
//     Rootfs.mount(config, mounts);
//     scope (exit) Rootfs.unmount(config, mounts);
//
//     foreach (arg; args)
//     {
//         string file;
//         string destDir;
//         auto colonIndex = arg.indexOf(':');
//         if (colonIndex >= 0)
//         {
//             file = arg[0 .. colonIndex];
//             destDir = arg[colonIndex + 1 .. $];
//         }
//         else
//         {
//             file = arg;
//             destDir = null;
//         }
//         auto result = installFile(file, mounts.rootfs, destDir);
//         if (result.failed)
//             return 1; // fail
//     }
//     return 0;
// }),
//
// Command("installElf", "Install an elf program and it's library dependencies <src>[:<dst>] or <src>[:<dir>/]", cmdNoFlags, function(string[] args)
// {
//     if (args.length == 0)
//     {
//         logError("please supply one or more elf binaries");
//         return 1;
//     }
//
//     bool useLdd = true;
//     string progName = useLdd ? "ldd" : "readelf";
//     auto prog = findProgram(environment.get("PATH").verifySentinel.ptr, progName);
//     if (prog.isNull)
//     {
//         logError("failed to find program '", progName, "'");
//         return 1; // fail
//     }
//
//     const config = parseConfig();
//     const mounts = config.getMounts();
//
//     Rootfs.mount(config, mounts);
//     scope (exit) Rootfs.unmount(config, mounts);
//
//     foreach (arg; args)
//     {
//         SentinelArray!(immutable(char)) elfSourceFile;
//         string elfDestDir;
//         {
//             auto colonIndex = arg.indexOf(':');
//             if (colonIndex >= 0)
//             {
//                 elfSourceFile = sprintMallocSentinel(arg[0 .. colonIndex]).asImmutable;
//                 elfDestDir = arg[colonIndex + 1 .. $];
//             }
//             else
//             {
//                 elfSourceFile = arg.makeSentinel;
//                 elfDestDir = null;
//             }
//         }
//
//         if (usePath(elfSourceFile.array))
//         {
//             if (!fileExists(elfSourceFile.ptr))
//             {
//                 log("looking for '", elfSourceFile, "'...");
//                 auto result = findProgram(environment.get("PATH").verifySentinel.ptr, elfSourceFile.array);
//                 if (result.isNull)
//                 {
//                     logError("failed to find program '", elfSourceFile, "'");
//                     return 1;
//                 }
//                 elfSourceFile = result.walkToArray.asImmutable;
//                 log("found program at '", elfSourceFile, "'");
//             }
//         }
//
//         if (useLdd)
//         {
//             auto result = installElfWithLdd(prog, elfSourceFile, elfDestDir, mounts.rootfs);
//             if (result.failed)
//                 return 1;
//         }
//         else
//         {
//             auto result = installElfWithReadelf(prog, elfSourceFile, elfDestDir, mounts.rootfs);
//             if (result.failed)
//                 return 1;
//         }
//     }
//     return 0;
// }),
//
// Command("startQemu", "start the os using qemu", cmdNoFlags, function(string[] args)
// {
//     enforce(args.length == 0, "startQemu requires 0 arguments");
//     const config = parseConfig();
//
//     auto qemuProgName = "qemu-system-x86_64";
//     auto qemuProg = findProgram(environment.get("PATH").verifySentinel.ptr, qemuProgName);
//     if (qemuProg.isNull)
//     {
//         logError("failed to find program '", qemuProgName, "'");
//         return 1; // fail
//     }
//     auto procBuilder = ProcBuilder.forExeFile(qemuProg);
//     procBuilder.tryPut(lit!"-m").enforce;
//     procBuilder.tryPut(lit!"2048").enforce;
//     procBuilder.tryPut(lit!"-drive").enforce;
//     procBuilder.tryPut(sprintMallocSentinel("format=raw,file=", config.imageFile)).enforce;
//
//     // optional, enable kvm (TODO: make this an option somehow)
//     //procBuilder.tryPut(lit!"--enable-kvm").enforce;
//     {
//         enum SerialSetting {default_, stdio, file, telnet }
//         const serialSetting = SerialSetting.stdio;
//         final switch (serialSetting)
//         {
//         case SerialSetting.default_: break;
//         case SerialSetting.stdio:
//             procBuilder.tryPut(lit!"-serial").enforce;
//             procBuilder.tryPut(lit!"stdio").enforce;
//             break;
//         case SerialSetting.file:
//             procBuilder.tryPut(lit!"-serial").enforce;
//             procBuilder.tryPut(lit!"file:serial.log").enforce;
//             break;
//         case SerialSetting.telnet:
//             procBuilder.tryPut(lit!"-serial").enforce;
//             procBuilder.tryPut(lit!"telnet:0.0.0.0:1234,server,wait").enforce;
//             break;
//         }
//     }
//     run(procBuilder);
//     return 0;
// }),
//
// Command("installBochs", "install the bochs emulator", cmdNoFlags, function(string[] args)
// {
//     run("sudo apt-get install bochs bochs-x");
//     return 0;
// }),
// Command("startBochs", "start the os using bochs", cmdNoFlags, function(string[] args)
// {
//     enforce(args.length == 0, "startBochs requires 0 arguments");
//     const config = parseConfig();
//
//     run("bochs -f /dev/null"
//         ~        ` 'memory: guest=1024, host=1024'`
//         ~        ` 'boot: disk'`
//         ~ format(` 'ata0-master: type=disk, path=%s, mode=flat'`, config.imageFile));
//     return 0;
// }),
//
// Command("readMbr", "read/print the MBR of the image using the mar library", cmdNoFlags, function(string[] args)
// {
//     import std.stdio;
//     enforce(args.length == 0, "readMbr requires 0 arguments");
//     const config = parseConfig();
//
//     writefln("Reading MBR of '%s'", config.imageFile);
//     writeln("--------------------------------------------------------------------------------");
//
//     auto f = File(config.imageFile, "rb");
//     mbr.OnDiskFormat mbrPtr;
//     assert(mbrPtr.bytes.length == f.rawRead(*mbrPtr.bytes).length);
//     if (!mbrPtr.signatureIsValid)
//     {
//         logError("invalid mbr signature '", mbrPtr.bootSignatureValue.toHostEndian, "'");
//         return 1;
//     }
//
//     foreach (i, ref part; mbrPtr.partitions)
//     {
//         writefln("part %s: type=%s(0x%x)", i + 1, part.type.name, part.type.enumValue);
//         writefln(" status=0x%02x%s", part.status, part.bootable ? " (bootable)" : "");
//         writefln(" firstSectorChs %s", part.firstSectorChs);
//         writefln(" lastSectorChs  %s", part.lastSectorChs);
//         const firstSectorLba = part.firstSectorLba.toHostEndian;
//         const sectorCount    = part.sectorCount.toHostEndian;
//         writefln(" firstSectorLba 0x%08x %s", firstSectorLba, firstSectorLba);
//         writefln(" sectorCount    0x%08x %s", sectorCount, sectorCount);
//     }
//     return 0;
//
// }),
//
// Command("zeroMbr", "zero the image mbr", cmdNoFlags, function(string[] args)
// {
//     enforce(args.length == 0, "zeroMbr requires 0 arguments");
//     const config = parseConfig();
//
//     auto mappedImage = config.mapImage(0, 512, Yes.writeable);
//     memset(mappedImage.ptr, 0, 512);
//     mappedImage.unmapAndClose();
//     return 0;
// }),
//
// Command("mountRootfs", "mount the looped image", cmdNoFlags, function(string[] args)
// {
//     enforce(args.length == 0, "mount requires 0 arguments");
//     const config = parseConfig();
//     const mounts = config.getMounts();
//
//     Rootfs.mount(config, mounts);
//     return 0;
// }),
// Command("unmountRootfs", "unmount the disk image", cmdNoFlags, function(string[] args)
// {
//     enforce(args.length == 0, "unmount requires 0 arguments");
//     const config = parseConfig();
//     const mounts = config.getMounts();
//     Rootfs.unmount(config, mounts);
//     return 0;
// }),
//
// Command("makeTar", "make the rootfs into a tar file", cmdNoFlags, function(string[] args)
// {
//     bool forWsl = false;
//     string tarFile = null;
//     for (;args.length > 0;)
//     {
//         const arg = args[0];
//         if (arg == "for-wsl")
//         {
//             forWsl = true;
//             args = args[1 .. $];
//         }
//         else
//         {
//             enforce(tarFile is null, format("unknown argument to makeTar '%s'", arg));
//             tarFile = arg;
//             args = args[1 .. $];
//         }
//     }
//     enforce(tarFile !is null, "the makeTar command requires a tarFile be provided on the command-line");
//     const config = parseConfig();
//
//     const tarTempDir = tarFile ~ ".tmp";
//     logMkdir(tarTempDir);
//     installRootfs(tarTempDir, forWsl);
//     run(format("tar --create \"--file=%s\" -C \"%s\" .", tarFile, tarTempDir));
//     run(format("rm -rf \"%s\"", tarTempDir));
//     return 0;
// }),
//
// Command("loopImage", "attach the image file to a loop device and scan for partitions", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "loopImage requires 0 arguments");
//     const config = parseConfig();
//     loopImage(config);
//     return 0;
// }),
// Command("unloopImage", "release the image file from the loop device", cmdInSequence, function(string[] args)
// {
//     enforce(args.length == 0, "unloopImage requires 0 arguments");
//     const config = parseConfig();
//
//     auto loopFile = tryGetImageLoopFile(config);
//     if (!loopFile)
//     {
//         log("image '", config.imageFile, "' it not looped");
//     }
//     else
//         unloopImage(loopFile);
//
//     return 0;
// }),
//
// Command("hostRunInit", "run the init process on the host machine", cmdNoFlags, function(string[] args)
// {
//     enforce(args.length == 0, "unloopImage requires 0 arguments");
//     const config = parseConfig();
//
//     const rootfsPath = "rootfs";
//     run(format("sudo chroot %s /sbin/init", rootfsPath));
//     return 0;
// }),
// Command("hostCleanInit", "cleanup after running the init process on the host machine", cmdNoFlags, function(string[] args)
// {
//     enforce(args.length == 0, "unloopImage requires 0 arguments");
//     const config = parseConfig();
//
//     const rootfsPath = "rootfs";
//     tryExec(format("sudo umount %s/proc", rootfsPath));
//     tryExec(format("sudo rmdir %s/proc", rootfsPath));
//     return 0;
// }),
//
// ];

/// returns: true if the symlink was updated, false if it was already set to the given `target_path`
pub fn updateSymlink(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.SymLinkFlags) !bool {
    if (std.fs.path.dirname(sym_link_path)) |dirname| {
        try std.fs.cwd().makePath(dirname);
    }

    var current_target_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    if (std.fs.readLinkAbsolute(sym_link_path, &current_target_path_buffer)) |current_target_path| {
        if (std.mem.eql(u8, target_path, current_target_path)) {
            //std.debug.print("symlink '{s}' already points to '{s}'\n", .{ sym_link_path, target_path });
            return false; // already up-to-date
        }
        try std.os.unlink(sym_link_path);
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    try std.fs.cwd().symLink(target_path, sym_link_path, flags);
    return true; // updated
}

pub const GitRepo = struct {
    url: []const u8,
    branch: ?[]const u8,
    sha: []const u8,
    path: ?[]const u8 = null,

    pub fn defaultReposDir(allocator: *std.mem.Allocator) ![]const u8 {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        return try std.fs.path.join(allocator, &[_][]const u8 { cwd, "dep" });
    }

    pub fn resolve(self: GitRepo, allocator: *std.mem.Allocator) ![]const u8 {
        var optional_repos_dir_to_clean: ?[]const u8 = null;
        defer {
            if (optional_repos_dir_to_clean) |p| {
                allocator.free(p);
            }
        }

        const path = if (self.path) |p| try allocator.dupe(u8, p) else blk: {
            const repos_dir = try defaultReposDir(allocator);
            optional_repos_dir_to_clean = repos_dir;
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ repos_dir, std.fs.path.basename(self.url) });
        };
        errdefer self.allocator.free(path);

        std.fs.accessAbsolute(path, std.fs.File.OpenFlags { .read = true }) catch {
            std.debug.print("Error: repository '{s}' does not exist\n", .{path});
            std.debug.print("       Run the following to clone it:\n", .{});
            const branch_args = if (self.branch) |b| &[2][]const u8 {" -b ", b} else &[2][]const u8 {"", ""};
            std.debug.print("       git clone {s}{s}{s} {s} && git -C {3s} checkout {s} -b for_zigup\n",
                .{self.url, branch_args[0], branch_args[1], path, self.sha});
            std.os.exit(1);
        };

        // TODO: check if the SHA matches an print a message and/or warning if it is different

        return path;
    }

    pub fn resolveOneFile(self: GitRepo, allocator: *std.mem.Allocator, index_sub_path: []const u8) ![]const u8 {
        const repo_path = try self.resolve(allocator);
        defer allocator.free(repo_path);
        return try std.fs.path.join(allocator, &[_][]const u8 { repo_path, index_sub_path });
    }
};
