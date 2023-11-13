const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

const buildconfig = @import("buildconfig.zig");
const Config = buildconfig.Config;
const MemoryUnit = buildconfig.MemoryUnit;
const MemorySize = buildconfig.MemorySize;

const MappedFile = @import("MappedFile.zig");
const mbr = @import("mbr.zig");

const symlinks = @import("build/symlinks.zig");

pub fn build(b: *Builder) !void {
    const config = try b.allocator.create(Config);
    config.* = try @import("config.zig").makeConfig();

    const symlinker = try symlinks.getSymlinkerFromFilesystemTest(b, .prefix, "rootfs.metadta");

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
    const boot_target = blk: {
        var cpu_arch = if (target.cpu_arch) |a| a else builtin.target.cpu.arch;
        if (cpu_arch == .x86_64 or cpu_arch == .i386) {
            break :blk std.zig.CrossTarget{
                .cpu_arch = .i386,
                .os_tag = .freestanding,
                .abi = .code16,
            };
        }
        std.log.err("unhandled target", .{});
        std.os.exit(0xff);
    };

    const mode = b.standardReleaseOptions();

    try addUserSteps(b, target, mode, config, symlinker);

    const alloc_image_step = try b.allocator.create(AllocImageStep);
    alloc_image_step.* = AllocImageStep.init(b, config.imageSize.byteValue());
    b.step("alloc-image", "Allocate the image file").dependOn(&alloc_image_step.step);

    const bootloader_image_size_step = try addBootloaderSteps(b, boot_target);

    const kernel_image_size_step = try b.allocator.create(GetFileSizeStep);
    switch (config.kernel) {
        .linux => |kernel| {
            kernel_image_size_step.* = GetFileSizeStep.init(b, kernel.image);
        },
        .maros => {
            const kernel = b.addExecutable("kernel", "kernel/start.zig");
            // TODO: for now we're only working with the boot target
            kernel.setTarget(boot_target);
            //kernel.setBuildMode(mode);
            kernel.setBuildMode(.ReleaseSmall);
            kernel.setLinkerScriptPath(.{ .path = "kernel/link.ld" });
            kernel.override_dest_dir = .prefix;

            // TODO: in this change, override_dest_dir should affect installRaw
            //       https://github.com/ziglang/zig/pull/9975
            const install = b.addInstallRaw(kernel, "kernel.raw", .{});
            install.dest_dir = .prefix; // hack, this currently messes up the uninstall step

            const install_elf = b.addInstallArtifact(kernel);
            b.getInstallStep().dependOn(&install_elf.step);

            kernel.install(); // install an elf version also for debugging

            kernel_image_size_step.* = GetFileSizeStep.init(b, b.getInstallPath(install.dest_dir, install.dest_filename));
            kernel_image_size_step.step.dependOn(&install.step);
        },
    }

    try addImageSteps(b, config, alloc_image_step, bootloader_image_size_step, kernel_image_size_step);
    try addQemuStep(b, alloc_image_step.image_file);
    try addBochsStep(b, alloc_image_step.image_file);
}



// currently the bootloader relies on a hardcoded size to find the
// kernel comand line and kernel image locations
// the bootloader should be enhanced to not need these hard-codings
const bootloader_reserve_sector_count = 16;
const sector_len = 512;
const bootloader_reserve_len = sector_len * bootloader_reserve_sector_count;

fn addQemuStep(b: *Builder, image_file: []const u8) !void {
    var args = std.ArrayList([]const u8).init(b.allocator);

    const qemu_prog_name = "qemu-system-x86_64";
    try args.append(qemu_prog_name);
    try args.append("-m");
    try args.append("2048");
    try args.append("-drive");
    try args.append(b.fmt("format=raw,file={s}", .{image_file}));
    // TODO: make this an option
    //try args.append("--enable-kvm");

    // TODO: add support for more serial options
    try args.append("--serial");
    try args.append("stdio");

    if (if (b.option(bool, "debugger", "enable the qemu debugger")) |o| o else false) {
        // gdb instructions:
        //     (gdb) target remote :1234
        // to break in the bootsector code
        //     (gdb) break *0x7c00
        // to break in the stage2 code
        //     (gdb) break *0x7e00
        //
        // go into assembly mode:
        //     (gdb) layout asm
        //
        // TODO: get these working
        //     (gdb) set architecture i8086
        //     (gdb) add-symbol-file maros/zig-out/bootloader.elf
        try args.append("-S"); // prevent cpu from starting automatically
                               // send the "continue" command to begin execution
        try args.append("-gdb");
        try args.append("tcp::1234");
    }

    const qemu = b.addSystemCommand(args.toOwnedSlice());
    qemu.step.dependOn(b.getInstallStep());

    b.step("qemu", "Run maros in the Qemu VM").dependOn(&qemu.step);
}

fn addBochsStep(b: *Builder, image_file: []const u8) !void {
    var args = std.ArrayList([]const u8).init(b.allocator);
    try args.append("bochs");
    try args.append("-f");
    try args.append("/dev/null");
    try args.append("memory: guest=1024, host=1024");
    try args.append("boot: disk");
    try args.append(b.fmt("ata0-master: type=disk, path={s}, mode=flat", .{image_file}));
    const bochs = b.addSystemCommand(args.toOwnedSlice());
    bochs.step.dependOn(b.getInstallStep());
    b.step("bochs", "Run maros in the Bochs VM").dependOn(&bochs.step);
}

fn addBootloaderSteps(b: *Builder, boot_target: std.zig.CrossTarget) !*GetFileSizeStep {
    // compile this separately so that it can have a different release mode
    // it has to fit inside 446 bytes
    const use_zig_bootsector = if (b.option(bool, "zigboot", "enable experimental zig bootsector")) |o| o else false;
    var zigbootsector = b.addObject("zigbootsector", "boot/bootsector.zig");
    zigbootsector.setTarget(boot_target);
    zigbootsector.setBuildMode(.ReleaseSmall);
    // TODO: install so we can look at it easily, but zig build doesn't like installing
    //       objects yet
    //zigbootsector.install();

    var asmbootsector = b.addObject("asmbootsector", "boot/bootsector.S");
    asmbootsector.setTarget(boot_target);
    asmbootsector.setBuildMode(.ReleaseSmall);

    const bin = b.addExecutable("bootloader.elf", "boot/zigboot.zig");
    bin.setTarget(boot_target);
    // this causes objdump to fail???
    //bin.setBuildMode(.ReleaseSmall);
    bin.addAssemblyFile("boot/bootstage2.S");
    if (use_zig_bootsector) {
        // zig bootsector may be a pipe dream
        bin.addObject(zigbootsector);
    } else {
        bin.addObject(asmbootsector);
    }
    bin.setLinkerScriptPath(.{ .path = "boot/link.ld" });

    bin.override_dest_dir = .prefix;

    // install elf file for debugging
    const install_elf = b.addInstallArtifact(bin);
    b.getInstallStep().dependOn(&install_elf.step);

    //bin.installRaw("bootloader.raw");
    //const bin_install = b.addInstallRaw(bin, "bootloader.raw");
    const bin_install = std.build.InstallRawStep.create(b, bin, "bootloader.raw", .{
        .format = .bin,
    });
    // TODO: remove this workaround
    bin_install.dest_dir = .prefix;


    const size_step = try b.allocator.create(GetFileSizeStep);
    size_step.* = GetFileSizeStep.init(b, b.getInstallPath(bin_install.dest_dir, bin_install.dest_filename));
    size_step.step.dependOn(&bin_install.step);
    return size_step;
}

const GetFileSizeStep = struct {
    step: std.build.Step,
    filename: []const u8,
    size: u64,
    pub fn init(b: *Builder, filename: []const u8) GetFileSizeStep {
        return .{
            .step = std.build.Step.init(.custom, "gets the size of a file", b.allocator, make),
            .filename = filename,
            .size = undefined,
        };
    }
    fn make(step: *std.build.Step) !void {
        std.debug.assert(!step.done_flag); // make sure my assumption is correct about this
        const self = @fieldParentPtr(GetFileSizeStep, "step", step);
        const file = std.fs.cwd().openFile(self.filename, .{}) catch |e| {
            std.log.err("GetFileSizeStep failed to open '{s}': {}", .{self.filename, e});
            std.os.exit(1);
        };
        defer file.close();
        self.size = try file.getEndPos();
        std.log.debug("{s}: {} bytes", .{self.filename, self.size});
    }

    // may only be called after this step has been executed
    pub fn getResultingSize(self: *GetFileSizeStep, who_wants_to_know: *const std.build.Step) u64 {
        if (!hasDependency(who_wants_to_know, &self.step))
            @panic("GetFileSizeStep.getResultingSize may only be called by steps that depend on it");
        return self.getResultingSizeNoDepCheck();
    }
    pub fn getResultingSizeNoDepCheck(self: *GetFileSizeStep) u64 {
        if (!self.step.done_flag)
            @panic("GetFileSizeStep.getResultingSize was called before the step was executed");
        return self.size;
    }
};

const InstallBootloaderStep = struct {
    step: std.build.Step,
    alloc_image_step: *AllocImageStep,
    bootloader_size_step: *GetFileSizeStep,
    pub fn init(b: *Builder, alloc_image_step: *AllocImageStep, bootloader_size_step: *GetFileSizeStep) InstallBootloaderStep {
        var result = .{
            .step = std.build.Step.init(.custom, "install the bootloader to the image", b.allocator, make),
            .alloc_image_step = alloc_image_step,
            .bootloader_size_step = bootloader_size_step,
        };
        result.step.dependOn(&alloc_image_step.step);
        result.step.dependOn(&bootloader_size_step.step);
        return result;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(InstallBootloaderStep, "step", step);
        const bootloader_filename = self.bootloader_size_step.filename;
        std.log.debug("installing bootloader '{s}' to '{s}'", .{
            bootloader_filename,
            self.alloc_image_step.image_file
        });

        const bootloader_file = try std.fs.cwd().openFile(bootloader_filename, .{});
        defer bootloader_file.close();
        const bootloader_len = self.bootloader_size_step.getResultingSize(step);
        std.debug.assert(bootloader_len == try bootloader_file.getEndPos());
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

fn hasDependency(step: *const std.build.Step, dep_candidate: *const std.build.Step) bool {
    for (step.dependencies.items) |dep| {
        // TODO: should probably use step.loop_flag to prevent infinite recursion
        //       when a circular reference is encountered, or maybe keep track of
        //       the steps encounterd with a hash set
        if (dep == dep_candidate or hasDependency(dep, dep_candidate))
            return true;
    }
    return false;
}

const InstallKernelCmdlineStep = struct {
    step: std.build.Step,
    alloc_image_step: *AllocImageStep,
    cmdline: []const u8,
    pub fn init(
        b: *Builder,
        alloc_image_step: *AllocImageStep,
        cmdline: []const u8,
    ) InstallKernelCmdlineStep {
        if (cmdline.len > sector_len - 1) std.debug.panic(
            "kernel cmdline ({} bytes) is too long ({} bytes max) for the crytal bootloader",
            .{ cmdline.len, sector_len - 1 },
        );

        var result = .{
            .step = std.build.Step.init(.custom, "install kernel cmdline to image", b.allocator, make),
            .alloc_image_step = alloc_image_step,
            .cmdline = cmdline,
        };
        result.step.dependOn(&alloc_image_step.step);
        return result;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(InstallKernelCmdlineStep, "step", step);

        const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .write = true });
        defer image_file.close();

        const kernel_cmdline_off = getKernelCmdlineSector() * sector_len;
        const end = kernel_cmdline_off + sector_len;

        const mapped_image = try MappedFile.init(image_file, end, .read_write);
        defer mapped_image.deinit();
        const dest = mapped_image.getPtr()[kernel_cmdline_off..end];
        std.debug.assert(dest.len >= self.cmdline.len + 1);
        if (std.mem.eql(u8, dest[0..self.cmdline.len], self.cmdline) and dest[self.cmdline.len] == 0) {
            std.log.debug("install-kernel-cmdline: already done", .{});
        } else {
            @memcpy(dest.ptr, self.cmdline.ptr, self.cmdline.len);
            dest[self.cmdline.len] = 0;
            std.log.debug("install-kernel-cmdline: done", .{});
        }
    }
};

const InstallKernelStep = struct {
    step: std.build.Step,
    kernel_image_size_step: *GetFileSizeStep,
    alloc_image_step: *AllocImageStep,
    pub fn init(b: *Builder, kernel_image_size_step: *GetFileSizeStep, alloc_image_step: *AllocImageStep) InstallKernelStep {
        var result = .{
            .step = std.build.Step.init(.custom, "install kernel to image", b.allocator, make),
            .kernel_image_size_step = kernel_image_size_step,
            .alloc_image_step = alloc_image_step,
        };
        result.step.dependOn(&kernel_image_size_step.step);
        result.step.dependOn(&alloc_image_step.step);
        return result;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(InstallKernelStep, "step", step);

        const kernel_len = self.kernel_image_size_step.getResultingSize(step);

        const kernel_file = try std.fs.cwd().openFile(self.kernel_image_size_step.filename, .{});
        defer kernel_file.close();
        std.debug.assert(kernel_len == try kernel_file.getEndPos());
        const mapped_kernel = try MappedFile.init(kernel_file, kernel_len, .read_only);
        defer mapped_kernel.deinit();

        const kernel_off = getKernelSector() * sector_len;

        const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .write = true });
        defer image_file.close();
        const mapped_image = try MappedFile.init(image_file, kernel_off + kernel_len, .read_write);
        defer mapped_image.deinit();

        const kernel_ptr = mapped_kernel.getPtr();
        const image_ptr = mapped_image.getPtr();

        const dest = image_ptr + kernel_off;
        if (std.mem.eql(u8, dest[0..kernel_len], kernel_ptr[0..kernel_len])) {
            std.log.debug("install-kernel: already done", .{});
        } else {
            @memcpy(dest, kernel_ptr, kernel_len);
            std.log.debug("install-kernel: done", .{});
        }
    }
};

const InstallRootfsStep = struct {
    step: std.build.Step,
    kernel_image_size_step: *GetFileSizeStep,
    alloc_image_step: *AllocImageStep,
    image_file: []const u8,
    image_len: u64,
    pub fn init(
        b: *Builder,
        kernel_image_size_step: *GetFileSizeStep,
        alloc_image_step: *AllocImageStep,
        image_len: u64,
    ) InstallRootfsStep {
        var result = .{
            .step = std.build.Step.init(.custom, "install rootfs to image", b.allocator, make),
            .kernel_image_size_step = kernel_image_size_step,
            .alloc_image_step = alloc_image_step,
            .image_file = b.getInstallPath(.prefix, "rootfs.ext3"),
            .image_len = image_len,
        };
        result.step.dependOn(&kernel_image_size_step.step);
        result.step.dependOn(&alloc_image_step.step);
        return result;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(InstallRootfsStep, "step", step);

        //const kernel_image_size = self.kernel_image_size_step.getResultingSize(step);
        //const kernel_off = getKernelSector() * sector_len;

        // allocate ext3 image file
        {
            if (std.fs.path.dirname(self.image_file)) |dirname| {
                try std.fs.cwd().makePath(dirname);
            }
            const file = try std.fs.cwd().createFile(self.image_file, .{ .truncate = false });
            defer file.close();
            const pos = try file.getEndPos();
            if (pos == self.image_len) {
                std.log.debug("rootfs: image file already allocated ({} bytes, {s})", .{self.image_len, self.image_file});
            } else {
                std.log.debug("rootfs: allocating image file ({} bytes, {s})", .{self.image_len, self.image_file});
                try file.setEndPos(self.image_len);
            }
        }



        //const part1_sector_off: u32 = getKernelSector() + downcast(
        //    u32, self.config.getMinSectorsToHold(.{.value=kernel_image_size,.unit=.byte}), "kernel sector count"
        //);
        //const part1_sector_cnt = downcast(u32, self.config.getMinSectorsToHold(self.config.rootfsPart.size), "MBR part1 sector count");
        //const part2_sector_off = part1_sector_off + part1_sector_cnt;

        // !!!

        //const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .write = true });
        //defer image_file.close();
        //const mapped_image = try MappedFile.init(image_file, kernel_off + kernel_len, .read_write);
        //defer mapped_image.deinit();

        //const kernel_ptr = mapped_kernel.getPtr();
        //const image_ptr = mapped_image.getPtr();
        //const dest = image_ptr + kernel_off;
        //if (std.mem.eql(u8, dest[0..kernel_len], kernel_ptr[0..kernel_len])) {
        //std.log.debug("install-kernel: already done", .{});
        //} else {
        //@memcpy(dest, kernel_ptr, kernel_len);
        //std.log.debug("install-kernel: done", .{});
        //}
    }
};

const GenerateCombinedToolsSourceStep = struct {
    step: std.build.Step,
    builder: *Builder,
    pub fn init(builder: *Builder) GenerateCombinedToolsSourceStep {
        return .{
            .step = std.build.Step.init(.custom, "generate tools.gen.zig", builder.allocator, make),
            .builder = builder,
        };
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(GenerateCombinedToolsSourceStep, "step", step);

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

fn addUserSteps(
    b: *Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
    config: *const Config,
    symlinker: symlinks.Symlinker,
) !void {
    const build_user_step = b.step("user", "Build userspace");
    const rootfs_install_dir = std.build.InstallDir { .custom = "rootfs" };
    if (config.combine_tools) {
        const gen_tools_file_step = try b.allocator.create(GenerateCombinedToolsSourceStep);
        gen_tools_file_step.* = GenerateCombinedToolsSourceStep.init(b);
        const exe = b.addExecutable("maros", "user" ++ std.fs.path.sep_str ++ "combined_root.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.override_dest_dir = rootfs_install_dir;
        exe.install();
        exe.step.dependOn(&gen_tools_file_step.step);
        inline for (commandLineTools) |commandLineTool| {
            const install_symlink_step = symlinker.createInstallSymlinkStep(
                b,
                "maros",
                rootfs_install_dir,
                commandLineTool.name,
            );
            install_symlink_step.dependOn(&exe.install_step.?.step);
            build_user_step.dependOn(install_symlink_step);
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
            exe.override_dest_dir = rootfs_install_dir;
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
        if (std.fs.path.dirname(self.image_file)) |dirname| {
            try std.fs.cwd().makePath(dirname);
        }
        const file = try std.fs.cwd().createFile(self.image_file, .{ .truncate = false });
        defer file.close();

        const pos = try file.getEndPos();
        if (pos == self.image_len) {
            std.log.debug("alloc-image: already done ({} bytes, {s})", .{self.image_len, self.image_file});
        } else {
            std.log.debug("alloc-image: allocating {} bytes, {s}", .{self.image_len, self.image_file});
            try file.setEndPos(self.image_len);
        }
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

// TODO: this will probably take the bootloader size in the future
fn getKernelCmdlineSector() u32 {
    return bootloader_reserve_sector_count;
}
fn getKernelSector() u32 {
    return bootloader_reserve_sector_count + 1; // +1 for kernel command line
}

const PartitionImageStep = struct {
    step: std.build.Step,
    image_file: []const u8,
    config: *const Config,
    bootloader_size_step: *GetFileSizeStep,
    kernel_image_size_step: *GetFileSizeStep,
    pub fn init(
        b: *Builder,
        config: *const Config,
        bootloader_size_step: *GetFileSizeStep,
        kernel_image_size_step: *GetFileSizeStep
    ) PartitionImageStep {
        var result = .{
            .step = std.build.Step.init(.custom, "truncate image file", b.allocator, make),
            .image_file = b.getInstallPath(.prefix, "maros.img"),
            .config = config,
            .bootloader_size_step = bootloader_size_step,
            .kernel_image_size_step = kernel_image_size_step,
        };
        result.step.dependOn(&bootloader_size_step.step);
        result.step.dependOn(&kernel_image_size_step.step);
        return result;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(PartitionImageStep, "step", step);

        const file = try std.fs.cwd().openFile(self.image_file, .{ .write = true });
        defer file.close();
        const image_len = self.config.imageSize.byteValue();
        try enforceImageLen(file, image_len);
        std.log.debug("partitioning image '{s}'", .{self.image_file});

        const bootloader_bin_size = self.bootloader_size_step.getResultingSize(step);
        const kernel_image_size = self.kernel_image_size_step.getResultingSize(step);

        if (bootloader_bin_size > bootloader_reserve_len) {
            std.debug.panic("bootloader size {} is too big (max is {})", .{bootloader_bin_size, bootloader_reserve_len});
        }

        const part1_sector_off: u32 =
            getKernelSector() +
            downcast(u32, self.config.getMinSectorsToHold(.{.value=kernel_image_size,.unit=.byte}), "kernel sector count");
        // TODO: initramfs would go next
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
fn addImageSteps(
    b: *Builder,
    config: *const Config,
    alloc_image_step: *AllocImageStep,
    bootloader_size_step: *GetFileSizeStep,
    kernel_image_size_step: *GetFileSizeStep,
) !void {
    {
        const zero_image_step = try b.allocator.create(ZeroImageStep);
        zero_image_step.* = ZeroImageStep.init(b, config.imageSize.byteValue());
        zero_image_step.step.dependOn(&alloc_image_step.step);
        b.step("zero-image", "Initialize image to zeros (depends on alloc-image)").dependOn(&zero_image_step.step);
    }

    {
        const install_bootloader = try b.allocator.create(InstallBootloaderStep);
        install_bootloader.* = InstallBootloaderStep.init(b, alloc_image_step, bootloader_size_step);
        b.getInstallStep().dependOn(&install_bootloader.step);
        b.step("install-bootloader", "Install bootloader").dependOn(&install_bootloader.step);
    }

    {
        const partition_step = try b.allocator.create(PartitionImageStep);
        partition_step.* = PartitionImageStep.init(b, config, bootloader_size_step, kernel_image_size_step);
        partition_step.step.dependOn(&alloc_image_step.step);
        b.getInstallStep().dependOn(&partition_step.step);
        b.step("partition", "Partition the image (depends on alloc-image)").dependOn(&partition_step.step);
    }

    {
        const install = try b.allocator.create(InstallKernelCmdlineStep);
        install.* = InstallKernelCmdlineStep.init(b, alloc_image_step, config.kernelCommandLine orelse "");
        b.getInstallStep().dependOn(&install.step);
        b.step("install-kernel-cmdline", "Install kernel cmdline to image").dependOn(&install.step);
    }

    {
        const install_kernel_step = try b.allocator.create(InstallKernelStep);
        install_kernel_step.* = InstallKernelStep.init(b, kernel_image_size_step, alloc_image_step);
        b.getInstallStep().dependOn(&install_kernel_step.step);
        b.step("install-kernel", "Install kernel to image").dependOn(&install_kernel_step.step);
    }

    {
        const install = try b.allocator.create(InstallRootfsStep);
        install.* = InstallRootfsStep.init(b, kernel_image_size_step, alloc_image_step, config.rootfsPart.size.byteValue());
        b.getInstallStep().dependOn(&install.step);
        b.step("install-rootfs", "Install rootfs to image").dependOn(&install.step);
    }
}

fn enforce(condition: bool, comptime fmt: []const u8, args: anytype) !void {
    if (!condition) {
        std.log.err(fmt, args);
        return error.AlreadyReported;
    }
}

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
