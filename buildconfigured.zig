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
        if (cpu_arch == .x86_64 or cpu_arch == .x86) {
            break :blk std.zig.CrossTarget{
                .cpu_arch = .x86,
                .os_tag = .freestanding,
                .abi = .code16,
            };
        }
        std.log.err("unhandled target", .{});
        std.os.exit(0xff);
    };

    const optimize = b.standardOptimizeOption(.{});

    try addUserSteps(b, target, optimize, config, symlinker);

    const alloc_image_step = try b.allocator.create(AllocImageStep);
    alloc_image_step.* = AllocImageStep.init(b, config.imageSize.byteValue());
    b.step("alloc-image", "Allocate the image file").dependOn(&alloc_image_step.step);

    const bootloader_image_size_step = try addBootloaderSteps(b, boot_target);

    const kernel_image_size_step = try b.allocator.create(GetFileSizeStep);
    switch (config.kernel) {
        .linux => |kernel| {
            kernel_image_size_step.* = GetFileSizeStep.init(b, .{ .path = kernel.image });
        },
        .maros => {
            const kernel = b.addExecutable(.{
                .name = "kernel",
                .root_source_file = .{ .path = "kernel/start.zig" },
                // TODO: for now we're only working with the boot target
                .target = boot_target,
                //.optimize = optimize,
                .optimize = .ReleaseSmall,
            });
            kernel.setLinkerScriptPath(.{ .path = "kernel/link.ld" });

            // TODO: in this change, override_dest_dir should affect installRaw
            //       https://github.com/ziglang/zig/pull/9975
            const install = kernel.addObjCopy(.{
                .basename = "kernel.raw",
                .format = .bin,
                //.dest_dir = .prefix,
            });
            //install.dest_dir = .prefix; // hack, this currently messes up the uninstall step

            const install_elf = b.addInstallArtifact(kernel, .{});
            b.getInstallStep().dependOn(&install_elf.step);

            _ = b.addInstallArtifact(kernel, .{}); // install an elf version also for debugging

            kernel_image_size_step.* = GetFileSizeStep.init(b, install.getOutput());
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

    const qemu = b.addSystemCommand(args.toOwnedSlice() catch unreachable);
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
    const bochs = b.addSystemCommand(args.toOwnedSlice() catch unreachable);
    bochs.step.dependOn(b.getInstallStep());
    b.step("bochs", "Run maros in the Bochs VM").dependOn(&bochs.step);
}

fn addBootloaderSteps(b: *Builder, boot_target: std.zig.CrossTarget) !*GetFileSizeStep {
    // compile this separately so that it can have a different release mode
    // it has to fit inside 446 bytes
    const use_zig_bootsector = if (b.option(bool, "zigboot", "enable experimental zig bootsector")) |o| o else false;
    var zigbootsector = b.addObject(.{
        .name = "zigbootsector",
        .root_source_file = .{ .path = "boot/bootsector.zig" },
        .target = boot_target,
        .optimize = .ReleaseSmall,
    });
    // TODO: install so we can look at it easily, but zig build doesn't like installing
    //       objects yet
    //zigbootsector.install();

    var asmbootsector = b.addObject(.{
        .name = "asmbootsector",
        .root_source_file = .{ .path = "boot/bootsector.S" },
        .target = boot_target,
        .optimize = .ReleaseSmall,
    });

    const bin = b.addExecutable(.{
        .name = "bootloader.elf",
        .root_source_file = .{ .path = "boot/zigboot.zig" },
        .target = boot_target,
        // this causes objdump to fail???
        //.optimize = .ReleaseSmall,
    });
    bin.addAssemblyFile(.{ .path = "boot/bootstage2.S" });
    if (use_zig_bootsector) {
        // zig bootsector may be a pipe dream
        bin.addObject(zigbootsector);
    } else {
        bin.addObject(asmbootsector);
    }
    bin.setLinkerScriptPath(.{ .path = "boot/link.ld" });

    // install elf file for debugging
    const install_elf = b.addInstallArtifact(bin, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_elf.step);

    const bin_install = bin.addObjCopy(.{
        .basename = "bootloader.raw",
        .format = .bin,
    });

    const size_step = try b.allocator.create(GetFileSizeStep);
    size_step.* = GetFileSizeStep.init(b, bin_install.getOutput());
    size_step.step.dependOn(&bin_install.step);
    return size_step;
}

const GetFileSizeStep = struct {
    step: std.build.Step,
    file_path: std.Build.LazyPath,
    size: u64,
    pub fn init(b: *Builder, file_path: std.Build.LazyPath) GetFileSizeStep {
        return .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "gets the size of a file",
                .owner = b,
                .makeFn = make,
            }),
            .file_path = file_path,
            .size = undefined,
        };
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(GetFileSizeStep, "step", step);
        const file_path = self.file_path.getPath2(step.owner, step);
        const file = std.fs.cwd().openFile(file_path, .{}) catch |e| {
            std.log.err("GetFileSizeStep failed to open '{s}': {}", .{file_path, e});
            return error.MakeFailed;
        };
        defer file.close();
        self.size = try file.getEndPos();
        std.log.debug("{s}: {} bytes", .{file_path, self.size});
    }

    // may only be called after this step has been executed
    pub fn getResultingSize(self: *GetFileSizeStep, who_wants_to_know: *const std.build.Step) u64 {
        if (!hasDependency(who_wants_to_know, &self.step))
            @panic("GetFileSizeStep.getResultingSize may only be called by steps that depend on it");
        return self.getResultingSizeNoDepCheck();
    }
    pub fn getResultingSizeNoDepCheck(self: *GetFileSizeStep) u64 {
        if (self.step.state != .success)
            @panic("GetFileSizeStep.getResultingSize was called before the step was successfully executed");
        return self.size;
    }
};

const InstallBootloaderStep = struct {
    step: std.build.Step,
    alloc_image_step: *AllocImageStep,
    bootloader_size_step: *GetFileSizeStep,
    pub fn create(
        b: *Builder,
        alloc_image_step: *AllocImageStep,
        bootloader_size_step: *GetFileSizeStep,
    ) *InstallBootloaderStep {
        const result = b.allocator.create(InstallBootloaderStep) catch @panic("OOM");
        result.* = .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "install the bootloader to the image",
                .owner = b,
                .makeFn = make,
            }),
            .alloc_image_step = alloc_image_step,
            .bootloader_size_step = bootloader_size_step,
        };
        result.step.dependOn(&alloc_image_step.step);
        result.step.dependOn(&bootloader_size_step.step);
        return result;
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(InstallBootloaderStep, "step", step);
        const bootloader_filename = self.bootloader_size_step.file_path.getPath2(step.owner, step);
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

        // NOTE: it looks like even though we only write to the image file we also need
        //       read permissions to mmap it?
        const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .mode = .read_write });
        defer image_file.close();
        const mapped_image = try MappedFile.init(image_file, bootloader_len, .read_write);
        defer mapped_image.deinit();

        const bootloader_ptr = mapped_bootloader.getPtr();
        const image_ptr = mapped_image.getPtr();

        @memcpy(image_ptr[0 .. mbr.bootstrap_len], bootloader_ptr);
        // don't overwrite the partition table between 446 and 510
        // separate memcpy so we can do the rest aligned
        @memcpy(image_ptr[510..512], bootloader_ptr + 510);
        @memcpy(image_ptr[512..][0..bootloader_len - 512], bootloader_ptr + 512);
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
    pub fn create(
        b: *Builder,
        alloc_image_step: *AllocImageStep,
        cmdline: []const u8,
    ) *InstallKernelCmdlineStep {
        if (cmdline.len > sector_len - 1) std.debug.panic(
            "kernel cmdline ({} bytes) is too long ({} bytes max) for the crytal bootloader",
            .{ cmdline.len, sector_len - 1 },
        );

        const result = b.allocator.create(InstallKernelCmdlineStep) catch @panic("OOM");
        result.* = .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "install kernel cmdline to image",
                .owner = b,
                .makeFn = make,
            }),
            .alloc_image_step = alloc_image_step,
            .cmdline = cmdline,
        };
        result.step.dependOn(&alloc_image_step.step);
        return result;
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(InstallKernelCmdlineStep, "step", step);

        // NOTE: it looks like even though we only write to the image file we also need
        //       read permissions to mmap it?
        const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .mode = .read_write });
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
            @memcpy(dest[0..self.cmdline.len], self.cmdline);
            dest[self.cmdline.len] = 0;
            std.log.debug("install-kernel-cmdline: done", .{});
        }
    }
};

const InstallKernelStep = struct {
    step: std.build.Step,
    kernel_image_size_step: *GetFileSizeStep,
    alloc_image_step: *AllocImageStep,
    pub fn create(
        b: *Builder,
        kernel_image_size_step: *GetFileSizeStep,
        alloc_image_step: *AllocImageStep,
    ) *InstallKernelStep {
        const result = b.allocator.create(InstallKernelStep) catch @panic("OOM");
        result.* = .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "install kernel to image",
                .owner = b,
                .makeFn = make,
            }),
            .kernel_image_size_step = kernel_image_size_step,
            .alloc_image_step = alloc_image_step,
        };
        result.step.dependOn(&kernel_image_size_step.step);
        result.step.dependOn(&alloc_image_step.step);
        return result;
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(InstallKernelStep, "step", step);

        const kernel_len = self.kernel_image_size_step.getResultingSize(step);

        const kernel_filename = self.kernel_image_size_step.file_path.getPath2(step.owner, step);
        const kernel_file = try std.fs.cwd().openFile(kernel_filename, .{});
        defer kernel_file.close();
        std.debug.assert(kernel_len == try kernel_file.getEndPos());
        const mapped_kernel = try MappedFile.init(kernel_file, kernel_len, .read_only);
        defer mapped_kernel.deinit();

        const kernel_off = getKernelSector() * sector_len;

        // NOTE: it looks like even though we only write to the image file we also need
        //       read permissions to mmap it?
        const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .mode = .read_write });
        defer image_file.close();
        const mapped_image = try MappedFile.init(image_file, kernel_off + kernel_len, .read_write);
        defer mapped_image.deinit();

        const kernel_ptr = mapped_kernel.getPtr();
        const image_ptr = mapped_image.getPtr();

        const dest = image_ptr + kernel_off;
        if (std.mem.eql(u8, dest[0..kernel_len], kernel_ptr[0..kernel_len])) {
            std.log.debug("install-kernel: already done", .{});
        } else {
            @memcpy(dest[0..kernel_len], kernel_ptr);
            std.log.debug("install-kernel: done", .{});
        }
    }
};

const GenerateCombinedToolsSourceStep = struct {
    step: std.build.Step,
    pub fn init(builder: *Builder) GenerateCombinedToolsSourceStep {
        return .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "generate tools.gen.zig",
                .owner = builder,
                .makeFn = make,
            }),
        };
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(GenerateCombinedToolsSourceStep, "step", step);

        const build_root = &self.step.owner.build_root.handle;

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
    optimize: std.builtin.Mode,
    config: *const Config,
    symlinker: symlinks.Symlinker,
) !void {
    const build_user_step = b.step("user", "Build userspace");
    const rootfs_install_dir = std.build.InstallDir { .custom = "rootfs" };
    if (config.combine_tools) {
        const gen_tools_file_step = try b.allocator.create(GenerateCombinedToolsSourceStep);
        gen_tools_file_step.* = GenerateCombinedToolsSourceStep.init(b);
        const exe = b.addExecutable(.{
            .name = "maros",
            .root_source_file = .{ .path = "user/combined_root.zig" },
            .target = target,
            .optimize = optimize,
        });
        const exe_install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = rootfs_install_dir },
        });
        exe.step.dependOn(&gen_tools_file_step.step);
        inline for (commandLineTools) |commandLineTool| {
            const install_symlink_step = symlinker.createInstallSymlinkStep(
                b,
                "maros",
                rootfs_install_dir,
                commandLineTool.name,
            );
            install_symlink_step.dependOn(&exe_install.step);
            build_user_step.dependOn(install_symlink_step);
        }
    } else {
        inline for (commandLineTools) |commandLineTool| {
            const exe = b.addExecutable(.{
                .name = commandLineTool.name,
                .root_source_file = .{ .path = "user/standalone_root.zig" },
                .target = target,
                .optimize = optimize,
            });
            exe.addModule("tool", b.createModule(.{
                .source_file = .{ .path = "user" ++ std.fs.path.sep_str ++ commandLineTool.name ++ ".zig" },
            }));
            const install = b.addInstallArtifact(exe, .{
                .dest_dir = .{ .override = rootfs_install_dir },
            });
            build_user_step.dependOn(&install.step);
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
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "truncate image file",
                .owner = b,
                .makeFn = make,
            }),
            .image_file = image_file,
            .image_len = image_len,
        };
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
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
    pub fn create(b: *Builder, image_file: []const u8, image_len: u64) *ZeroImageStep {
        const result = b.allocator.create(ZeroImageStep) catch @panic("OOM");
        result.* = .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = b.fmt("zero image file '{s}'", .{image_file}),
                .owner = b,
                .makeFn = make,
            }),
            .image_file = image_file,
            .image_len = image_len,
        };
        return result;
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(ZeroImageStep, "step", step);
        std.log.debug("zeroing image '{s}'", .{self.image_file});
        // NOTE: it looks like even though we only write to the image file we also need
        //       read permissions to mmap it?
        const file = try std.fs.cwd().openFile(self.image_file, .{ .mode = .read_write });
        defer file.close();
        try enforceImageLen(file, self.image_len);
        const mapped_file = try MappedFile.init(file, self.image_len, .read_write);
        defer mapped_file.deinit();

        @memset(mapped_file.getPtr()[0..self.image_len], 0);
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
    return @intCast(val);
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
    pub fn create(
        b: *Builder,
        config: *const Config,
        bootloader_size_step: *GetFileSizeStep,
        kernel_image_size_step: *GetFileSizeStep
    ) *PartitionImageStep {
        const result = b.allocator.create(PartitionImageStep) catch @panic("OOM");
        result.* = .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "partition image file",
                .owner = b,
                .makeFn = make,
            }),
            .image_file = b.getInstallPath(.prefix, "maros.img"),
            .config = config,
            .bootloader_size_step = bootloader_size_step,
            .kernel_image_size_step = kernel_image_size_step,
        };
        result.step.dependOn(&bootloader_size_step.step);
        result.step.dependOn(&kernel_image_size_step.step);
        return result;
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(PartitionImageStep, "step", step);

        // NOTE: it looks like even though we only write to the image file we also need
        //       read permissions to mmap it?
        const file = try std.fs.cwd().openFile(self.image_file, .{ .mode = .read_write });
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
        const mbr_ptr: *mbr.Sector = @ptrCast(image_ptr);

        // rootfs partition
        mbr_ptr.partitions[0] = .{
            .status = .bootable,
            .first_sector_chs = mbr.ChsAddress.zeros,
            .part_type = .linux,
            .last_sector_chs = mbr.ChsAddress.zeros,
            .first_sector_lba = mbr.LittleEndianOf(u32).fromNative(part1_sector_off),
            .sector_count     = mbr.LittleEndianOf(u32).fromNative(part1_sector_cnt),
        };
        // swap partition
        mbr_ptr.partitions[1] = .{
            .status = .none,
            .first_sector_chs = mbr.ChsAddress.zeros,
            .part_type = .linuxSwapOrSunContainer,
            .last_sector_chs = mbr.ChsAddress.zeros,
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

    const image_file = b.getInstallPath(.prefix, "maros.img");

    {
        const zero = ZeroImageStep.create(b, image_file, config.imageSize.byteValue());
        zero.step.dependOn(&alloc_image_step.step);
        b.step("zero-image", "Initialize image to zeros (depends on alloc-image)").dependOn(&zero.step);
    }

    {
        const install = InstallBootloaderStep.create(b, alloc_image_step, bootloader_size_step);
        b.getInstallStep().dependOn(&install.step);
        b.step("install-bootloader", "Install bootloader").dependOn(&install.step);
    }

    {
        const part = PartitionImageStep.create(b, config, bootloader_size_step, kernel_image_size_step);
        part.step.dependOn(&alloc_image_step.step);
        b.getInstallStep().dependOn(&part.step);
        b.step("partition", "Partition the image (depends on alloc-image)").dependOn(&part.step);
    }

    {
        const install = InstallKernelCmdlineStep.create(b, alloc_image_step, config.kernelCommandLine orelse "");
        b.getInstallStep().dependOn(&install.step);
        b.step("install-kernel-cmdline", "Install kernel cmdline to image").dependOn(&install.step);
    }

    {
        const install = InstallKernelStep.create(b, kernel_image_size_step, alloc_image_step);
        b.getInstallStep().dependOn(&install.step);
        b.step("install-kernel", "Install kernel to image").dependOn(&install.step);
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
//    CommandLineTool { .name = "mount" },
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
