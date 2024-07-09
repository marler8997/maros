const std = @import("std");
const Build = std.Build;
const builtin = @import("builtin");

const buildconfig = @import("buildconfig.zig");
const Config = buildconfig.Config;
const Filesystem = buildconfig.Filesystem;
const MemoryUnit = buildconfig.MemoryUnit;
const MemorySize = buildconfig.MemorySize;

const MappedFile = @import("MappedFile.zig");
const mbr = @import("mbr.zig");

const util = @import("build/util.zig");
const symlinks = @import("build/symlinks.zig");
const e2tools = @import("build/e2tools.zig");

pub fn build(b: *Build) !void {
    const config = try b.allocator.create(Config);
    config.* = try @import("config.zig").makeConfig();

    const symlinker = try symlinks.getSymlinkerFromFilesystemTest(b, .prefix, "rootfs.metadta");

    const target = b.standardTargetOptions(.{
        .default_target = .{
            .os_tag = .linux
        },
    });
    if (target.result.os.tag != .linux) {
        std.log.err("unsupported os '{s}', only linux is supported", .{@tagName(target.result.os.tag)});
        std.process.exit(0xff);
    }
    const boot_target = blk: {
        if (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .x86) {
            break :blk b.resolveTargetQuery(std.zig.CrossTarget{
                .cpu_arch = .x86,
                .os_tag = .freestanding,
                .abi = .code16,
            });
        }
        std.log.err("unhandled target", .{});
        std.process.exit(0xff);
    };
    const userspace_target = blk: {
        if (target.result.cpu.arch == .x86_64) {
            break :blk b.resolveTargetQuery(std.Target.Query{
                .cpu_arch = .x86_64,
                .os_tag = switch (config.kernel) {
                    .linux => .linux,
                    .maros => .freestanding,
                },
            });
        }
        std.log.err("unhandled target", .{});
        std.process.exit(0xff);
    };

    const optimize = b.standardOptimizeOption(.{});

    const user_step = try addUserSteps(b, userspace_target, optimize, config, symlinker);

    const alloc_image_step = try b.allocator.create(AllocImageStep);
    alloc_image_step.* = AllocImageStep.init(b, config.imageSize.byteValue());
    b.step("alloc-image", "Allocate the image file").dependOn(&alloc_image_step.step);

    const bootloader_image_size_step = try addBootloaderSteps(b, boot_target);

    const kernel_image_size_step = try b.allocator.create(GetFileSizeStep);
    switch (config.kernel) {
        .linux => |kernel| {
            kernel_image_size_step.* = GetFileSizeStep.init(b, b.path(kernel.image));
        },
        .maros => {
            const kernel = b.addExecutable(.{
                .name = "kernel",
                .root_source_file = b.path("kernel/start.zig"),
                // TODO: for now we're only working with the boot target
                .target = boot_target,
                //.optimize = optimize,
                .optimize = .ReleaseSmall,
            });
            kernel.setLinkerScriptPath(b.path("kernel/link.ld"));

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

    try addImageSteps(
        b,
        config,
        alloc_image_step,
        bootloader_image_size_step,
        kernel_image_size_step,
        user_step,
    );
    try addQemuStep(b, alloc_image_step.image_file);
    try addBochsStep(b, alloc_image_step.image_file);
}



// currently the bootloader relies on a hardcoded size to find the
// kernel comand line and kernel image locations
// the bootloader should be enhanced to not need these hard-codings
const bootloader_reserve_sector_count = 16;

fn addQemuStep(b: *Build, image_file: []const u8) !void {
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

fn addBochsStep(b: *Build, image_file: []const u8) !void {
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

fn addBootloaderSteps(b: *Build, boot_target: std.Build.ResolvedTarget) !*GetFileSizeStep {
    // compile this separately so that it can have a different release mode
    // it has to fit inside 446 bytes
    const use_zig_bootsector = if (b.option(bool, "zigboot", "enable experimental zig bootsector")) |o| o else false;
    const zigbootsector = b.addObject(.{
        .name = "zigbootsector",
        .root_source_file = b.path("boot/bootsector.zig"),
        .target = boot_target,
        .optimize = .ReleaseSmall,
    });
    // TODO: install so we can look at it easily, but zig build doesn't like installing
    //       objects yet
    //zigbootsector.install();

    const asmbootsector = b.addObject(.{
        .name = "asmbootsector",
        .target = boot_target,
        .optimize = .ReleaseSmall,
    });
    asmbootsector.addAssemblyFile(b.path("boot/bootsector.S"));

    const bin = b.addExecutable(.{
        .name = "bootloader.elf",
        .root_source_file = b.path("boot/zigboot.zig"),
        .target = boot_target,
        // this causes objdump to fail???
        //.optimize = .ReleaseSmall,
    });
    bin.addAssemblyFile(b.path("boot/bootstage2.S"));
    if (use_zig_bootsector) {
        // zig bootsector may be a pipe dream
        bin.addObject(zigbootsector);
    } else {
        bin.addObject(asmbootsector);
    }
    bin.setLinkerScriptPath(b.path("boot/link.ld"));

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
    step: Build.Step,
    file_path: Build.LazyPath,
    size: u64,
    pub fn init(b: *Build, file_path: Build.LazyPath) GetFileSizeStep {
        return .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "gets the size of a file",
                .owner = b,
                .makeFn = make,
            }),
            .file_path = file_path,
            .size = undefined,
        };
    }
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *GetFileSizeStep = @fieldParentPtr("step", step);
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
    pub fn getResultingSize(self: *GetFileSizeStep, who_wants_to_know: *const Build.Step) u64 {
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
    step: Build.Step,
    alloc_image_step: *AllocImageStep,
    bootloader_size_step: *GetFileSizeStep,
    pub fn create(
        b: *Build,
        alloc_image_step: *AllocImageStep,
        bootloader_size_step: *GetFileSizeStep,
    ) *InstallBootloaderStep {
        const result = b.allocator.create(InstallBootloaderStep) catch @panic("OOM");
        result.* = .{
            .step = Build.Step.init(.{
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
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *InstallBootloaderStep = @fieldParentPtr("step", step);
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

fn hasDependency(step: *const Build.Step, dep_candidate: *const Build.Step) bool {
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
    step: Build.Step,
    alloc_image_step: *AllocImageStep,
    cmdline: []const u8,
    sector_len: u32,
    pub fn create(
        b: *Build,
        alloc_image_step: *AllocImageStep,
        cmdline: []const u8,
        sector_len: u32,
    ) *InstallKernelCmdlineStep {
        if (cmdline.len > sector_len - 1) std.debug.panic(
            "kernel cmdline ({} bytes) is too long ({} bytes max) for the crytal bootloader",
            .{ cmdline.len, sector_len - 1 },
        );

        const result = b.allocator.create(InstallKernelCmdlineStep) catch @panic("OOM");
        result.* = .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "install kernel cmdline to image",
                .owner = b,
                .makeFn = make,
            }),
            .alloc_image_step = alloc_image_step,
            .cmdline = cmdline,
            .sector_len = sector_len,
        };
        result.step.dependOn(&alloc_image_step.step);
        return result;
    }
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *InstallKernelCmdlineStep = @fieldParentPtr("step", step);

        // NOTE: it looks like even though we only write to the image file we also need
        //       read permissions to mmap it?
        const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .mode = .read_write });
        defer image_file.close();

        const kernel_cmdline_off = @as(usize, getKernelCmdlineSector()) * @as(usize, self.sector_len);
        const end: usize = kernel_cmdline_off + self.sector_len;

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

// TODO: create a generic InstallFileToImageStep
//       will need a LazyOffset
//       maybe Zig build should have a general fn Lazy(comptime T: type)?
const InstallKernelStep = struct {
    step: Build.Step,
    kernel_image_size_step: *GetFileSizeStep,
    alloc_image_step: *AllocImageStep,
    sector_len: u32,
    pub fn create(
        b: *Build,
        kernel_image_size_step: *GetFileSizeStep,
        alloc_image_step: *AllocImageStep,
        sector_len: u32,
    ) *InstallKernelStep {
        const result = b.allocator.create(InstallKernelStep) catch @panic("OOM");
        result.* = .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "install kernel to image",
                .owner = b,
                .makeFn = make,
            }),
            .kernel_image_size_step = kernel_image_size_step,
            .alloc_image_step = alloc_image_step,
            .sector_len = sector_len,
        };
        result.step.dependOn(&kernel_image_size_step.step);
        result.step.dependOn(&alloc_image_step.step);
        return result;
    }
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *InstallKernelStep = @fieldParentPtr("step", step);

        const kernel_len = self.kernel_image_size_step.getResultingSize(step);

        const kernel_filename = self.kernel_image_size_step.file_path.getPath2(step.owner, step);
        const kernel_file = try std.fs.cwd().openFile(kernel_filename, .{});
        defer kernel_file.close();
        std.debug.assert(kernel_len == try kernel_file.getEndPos());
        const mapped_kernel = try MappedFile.init(kernel_file, kernel_len, .read_only);
        defer mapped_kernel.deinit();

        const kernel_off = @as(usize, getKernelSector()) * @as(usize, self.sector_len);

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

const rootfs_bin_sub_path = "rootfs/bin";

const InstallRootfsStep = struct {
    step: Build.Step,
    kernel_image_size_step: *GetFileSizeStep,
    alloc_image_step: *AllocImageStep,
    image_file: []const u8,
    image_len: u64,
    sector_len: u32,
    fstype: Filesystem,
    pub fn create(
        b: *Build,
        kernel_image_size_step: *GetFileSizeStep,
        alloc_image_step: *AllocImageStep,
        image_len: u64,
        user_step: *Build.Step,
        sector_len: u32,
        fstype: Filesystem,
    ) *InstallRootfsStep {
        const result = b.allocator.create(InstallRootfsStep) catch @panic("OOM");
        result.* = .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "install rootfs to image",
                .owner = b,
                .makeFn = make,
            }),
            .kernel_image_size_step = kernel_image_size_step,
            .alloc_image_step = alloc_image_step,
            .image_file = b.getInstallPath(.prefix, b.fmt("rootfs.{s}", .{fstype.ext()})),
            .image_len = image_len,
            .sector_len = sector_len,
            .fstype = fstype,
        };
        result.step.dependOn(&kernel_image_size_step.step);
        result.step.dependOn(&alloc_image_step.step);
        result.step.dependOn(user_step);
        return result;
    }
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *InstallRootfsStep = @fieldParentPtr("step", step);

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

        {
            var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_instance.deinit();
            const alloc = arena_instance.allocator();
            try makefs(self.fstype, alloc, self.image_file, self.image_len);
            try fsimage.makeDir(self.fstype, alloc, self.image_file, "dev" , 0o775);
            try fsimage.makeDir(self.fstype, alloc, self.image_file, "proc", 0o555);
            try fsimage.makeDir(self.fstype, alloc, self.image_file, "sys" , 0o555);
            try fsimage.makeDir(self.fstype, alloc, self.image_file, "var" , 0o755);
            try fsimage.makeDir(self.fstype, alloc, self.image_file, "tmp" , 0o777);
            try fsimage.makeDir(self.fstype, alloc, self.image_file, "sbin" , 0o777);
            const rootfs_bin = step.owner.pathJoin(&.{ step.owner.install_path, rootfs_bin_sub_path });
            try installDir(self.fstype, alloc, self.image_file, rootfs_bin, "sbin");
        }

        //
        // TODO: move this code to another more general InstallFileToImageStep
        //
        const kernel_image_size = self.kernel_image_size_step.getResultingSize(step);
        const rootfs_sector = getRootfsSector(self.sector_len, kernel_image_size);
        const rootfs_sector_count = getRootfsSectorCount(self.sector_len, self.image_len);

        const rootfs_offset: usize = @as(usize, rootfs_sector) * @as(usize, self.sector_len);
        const rootfs_limit: usize = rootfs_offset + (@as(usize, rootfs_sector_count) * @as(usize, self.sector_len));

        const rootfs_file = try std.fs.cwd().openFile(self.image_file, .{});
        defer rootfs_file.close();
        const mapped_rootfs = try MappedFile.init(rootfs_file, self.image_len, .read_only);
        defer mapped_rootfs.deinit();

        // NOTE: it looks like even though we only write to the image file we also need
        //       read permissions to mmap it?
        const image_file = try std.fs.cwd().openFile(self.alloc_image_step.image_file, .{ .mode = .read_write });
        defer image_file.close();
        const mapped_image = try MappedFile.init(image_file, rootfs_limit, .read_write);
        defer mapped_image.deinit();

        const rootfs_ptr = mapped_rootfs.getPtr();
        const dest = mapped_image.getPtr() + rootfs_offset;
        if (std.mem.eql(u8, dest[0..self.image_len], rootfs_ptr[0..self.image_len])) {
            std.log.debug("install-rootfs: already done", .{});
        } else {
            @memcpy(dest[0..self.image_len], rootfs_ptr);
            std.log.debug("install-rootfs: done", .{});
        }
    }

    fn makefs(fs: Filesystem, allocator: std.mem.Allocator, image_file: []const u8, len: usize) !void {
        switch (fs) {
            .ext => {
                const block_size = 4096;

                var block_size_string_buf: [20]u8 = undefined;
                const block_size_string = std.fmt.bufPrint(&block_size_string_buf, "{}", .{block_size}) catch unreachable;

                const block_count = @divTrunc(len, block_size);
                if (block_count * block_size != len) {
                    std.log.warn("rootfs len {} is not a multiple of the block size {}", .{len, block_size});
                }
                var block_count_string_buf: [20]u8 = undefined;
                const block_count_string = std.fmt.bufPrint(&block_count_string_buf, "{}", .{block_count}) catch unreachable;

                const result = try util.run(allocator, &.{
                    "mkfs.ext3",
                    "-F",
                    "-b", block_size_string,
                    image_file,
                    block_count_string,
                });
                const failed = switch (result.term) {
                    .Exited => |code| code != 0,
                    else => true,
                };
                if (failed) {
                    std.log.err(
                        "mkfs.ext3 for for rootfs image '{s}' {}, stdout='{s}' stderr='{s}'",
                        .{image_file, util.fmtTerm(result.term), result.stdout, result.stderr},
                    );
                    return error.MakeFailed;
                }
            },
            .fat32 => @panic("todo"),
        }
    }

    fn installDir(
        fs: Filesystem,
        allocator: std.mem.Allocator,
        image_file: []const u8,
        src_dir_path: []const u8,
        dst_dir: []const u8,
    ) !void {
        var src_dir = try std.fs.cwd().openDir(src_dir_path, .{.iterate=true});
        defer src_dir.close();

        var it = src_dir.iterate();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const entry_path = std.fs.path.join(allocator, &.{src_dir_path, entry.name}) catch @panic("OOM");
                    defer allocator.free(entry_path);
                    try fsimage.installFile(fs, allocator, image_file, entry_path, dst_dir);
                },
                .sym_link => {
                    var target_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                    const target = try src_dir.readLink(entry.name, &target_buf);
                    const dst = std.fs.path.join(allocator, &.{dst_dir, entry.name}) catch @panic("OOM");
                    defer allocator.free(dst);
                    try fsimage.installSymLink(fs, allocator, image_file, target, dst);
                },
                else => @panic("todo"),
            }
        }
    }
};

const fsimage = struct {
    fn makeDir(fs: Filesystem, allocator: std.mem.Allocator, image_file: []const u8, sub_path: []const u8, perm: u9) !void {
        switch (fs) {
            .ext => try e2tools.makeDir(allocator, image_file, sub_path, perm),
            .fat32 => @panic("todo"),
        }
    }

    fn installFile(fs: Filesystem, allocator: std.mem.Allocator, image_file: []const u8, src: []const u8, dst: []const u8) !void {
        switch (fs) {
            .ext => try e2tools.installFile(allocator, image_file, src, dst),
            .fat32 => @panic("todo"),
        }
    }

    fn installSymLink(fs: Filesystem, allocator: std.mem.Allocator, image_file: []const u8, target_path: []const u8, dst: []const u8) !void {
        switch (fs) {
            .ext => try e2tools.installSymLink(allocator, image_file, target_path, dst),
            .fat32 => @panic("todo"),
        }
    }
};


const GenerateCombinedToolsSourceStep = struct {
    step: Build.Step,
    pub fn init(builder: *Build) GenerateCombinedToolsSourceStep {
        return .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "generate tools.gen.zig",
                .owner = builder,
                .makeFn = make,
            }),
        };
    }
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *GenerateCombinedToolsSourceStep = @fieldParentPtr("step", step);

        const build_root = &self.step.owner.build_root.handle;

        // TODO: only generate and/or update the file if it was modified
        const file = try build_root.createFile("user" ++ std.fs.path.sep_str ++ "tools.gen.zig", .{});
        defer file.close();

        const writer = file.writer();
        try writer.writeAll("pub const tool_names = [_][]const u8 {\n");
        inline for (cmdline_tools) |commandLineTool| {
            try writer.print("    \"{s}\",\n", .{commandLineTool.name});
        }
        try writer.writeAll("};\n");
        inline for (cmdline_tools) |commandLineTool| {
            try writer.print("pub const {s} = @import(\"{0s}.zig\");\n", .{commandLineTool.name});
        }
    }
};

fn addUserSteps(
    b: *Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    config: *const Config,
    symlinker: symlinks.Symlinker,
) !*Build.Step {
    const build_user_step = b.step("user", "Build userspace");
    const rootfs_install_bin_dir = Build.InstallDir { .custom = rootfs_bin_sub_path };
    if (config.combine_tools) {
        const gen_tools_file_step = try b.allocator.create(GenerateCombinedToolsSourceStep);
        gen_tools_file_step.* = GenerateCombinedToolsSourceStep.init(b);
        const exe = b.addExecutable(.{
            .name = "maros",
            .root_source_file = b.path("user/combined_root.zig"),
            .target = target,
            .optimize = optimize,
        });
        const exe_install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = rootfs_install_bin_dir },
        });
        exe.step.dependOn(&gen_tools_file_step.step);
        inline for (cmdline_tools) |commandLineTool| {
            const install_symlink_step = symlinker.createInstallSymlinkStep(
                b,
                "maros",
                rootfs_install_bin_dir,
                commandLineTool.name,
            );
            install_symlink_step.dependOn(&exe_install.step);
            build_user_step.dependOn(install_symlink_step);
        }
    } else {
        inline for (cmdline_tools) |commandLineTool| {
            const exe = b.addExecutable(.{
                .name = commandLineTool.name,
                .root_source_file = b.path("user/standalone_root.zig"),
                .target = target,
                .optimize = optimize,
            });
            exe.root_module.addImport("tool", b.createModule(.{
                .root_source_file = b.path("user" ++ std.fs.path.sep_str ++ commandLineTool.name ++ ".zig"),
            }));
            const install = b.addInstallArtifact(exe, .{
                .dest_dir = .{ .override = rootfs_install_bin_dir },
            });
            build_user_step.dependOn(&install.step);
        }
    }
    b.getInstallStep().dependOn(build_user_step);
    return build_user_step;
}

const AllocImageStep = struct {
    step: Build.Step,
    image_file: []const u8,
    image_len: u64,
    pub fn init(b: *Build, image_len: u64) AllocImageStep {
        const image_file = b.getInstallPath(.prefix, "maros.img");
        b.pushInstalledFile(.prefix, "maros.img");
        return .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "truncate image file",
                .owner = b,
                .makeFn = make,
            }),
            .image_file = image_file,
            .image_len = image_len,
        };
    }
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *AllocImageStep = @fieldParentPtr("step", step);
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
    step: Build.Step,
    image_file: []const u8,
    image_len: u64,
    pub fn create(b: *Build, image_file: []const u8, image_len: u64) *ZeroImageStep {
        const result = b.allocator.create(ZeroImageStep) catch @panic("OOM");
        result.* = .{
            .step = Build.Step.init(.{
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
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *ZeroImageStep = @fieldParentPtr("step", step);
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

fn getRootfsSector(sector_len: u64, kernel_image_len: u64) u32 {
    return getKernelSector() + downcast(u32, buildconfig.getMinSectorsToHold(sector_len, kernel_image_len), "kernel sector count");
}
fn getRootfsSectorCount(sector_len: u64, rootfs_image_len: u64) u32 {
    return downcast(u32, buildconfig.getMinSectorsToHold(sector_len, rootfs_image_len), "rootfs sector count");
}

const PartitionImageStep = struct {
    step: Build.Step,
    image_file: []const u8,
    config: *const Config,
    bootloader_size_step: *GetFileSizeStep,
    kernel_image_size_step: *GetFileSizeStep,
    pub fn create(
        b: *Build,
        config: *const Config,
        bootloader_size_step: *GetFileSizeStep,
        kernel_image_size_step: *GetFileSizeStep,
    ) *PartitionImageStep {
        const result = b.allocator.create(PartitionImageStep) catch @panic("OOM");
        result.* = .{
            .step = Build.Step.init(.{
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
    fn make(step: *Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const self: *PartitionImageStep = @fieldParentPtr("step", step);

        // NOTE: it looks like even though we only write to the image file we also need
        //       read permissions to mmap it?
        const file = try std.fs.cwd().openFile(self.image_file, .{ .mode = .read_write });
        defer file.close();
        const image_len = self.config.imageSize.byteValue();
        try enforceImageLen(file, image_len);
        std.log.debug("partitioning image '{s}'", .{self.image_file});

        const bootloader_bin_size = self.bootloader_size_step.getResultingSize(step);
        const kernel_image_size = self.kernel_image_size_step.getResultingSize(step);

        const sector_len: u32 = @intCast(self.config.sectorSize.byteValue());
        const bootloader_reserve_len: usize = @as(usize, sector_len) * @as(usize, bootloader_reserve_sector_count);
        if (bootloader_bin_size > bootloader_reserve_len) {
            std.debug.panic("bootloader size {} is too big (max is {})", .{bootloader_bin_size, bootloader_reserve_len});
        }

        const part1_sector_off = getRootfsSector(sector_len, kernel_image_size);
        const part1_sector_cnt = getRootfsSectorCount(sector_len, self.config.rootfsPart.size.byteValue());
        // TODO: initramfs would go next
        const part2_sector_off = part1_sector_off + part1_sector_cnt;
        const part2_sector_cnt = downcast(u32, buildconfig.getMinSectorsToHold(sector_len, self.config.swapSize.byteValue()), "MBR part2 sector count");

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
    b: *Build,
    config: *const Config,
    alloc_image_step: *AllocImageStep,
    bootloader_size_step: *GetFileSizeStep,
    kernel_image_size_step: *GetFileSizeStep,
    user_step: *Build.Step,
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
        const install = InstallKernelCmdlineStep.create(
            b,
            alloc_image_step,
            config.kernelCommandLine orelse "",
            @intCast(config.sectorSize.byteValue()),
        );
        b.getInstallStep().dependOn(&install.step);
        b.step("install-kernel-cmdline", "Install kernel cmdline to image").dependOn(&install.step);
    }

    {
        const install = InstallKernelStep.create(
            b,
            kernel_image_size_step,
            alloc_image_step,
            @intCast(config.sectorSize.byteValue()),
        );
        b.getInstallStep().dependOn(&install.step);
        b.step("install-kernel", "Install kernel to image").dependOn(&install.step);
    }

    {
        const install = InstallRootfsStep.create(
            b,
            kernel_image_size_step,
            alloc_image_step,
            config.rootfsPart.size.byteValue(),
            user_step,
            @intCast(config.sectorSize.byteValue()),
            config.rootfsPart.fstype,
        );
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

const cmdline_tools = [_]CommandLineTool {
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
