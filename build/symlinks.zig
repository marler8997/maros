const std = @import("std");

pub fn testSymlinkSupport(dir: std.fs.Dir) !bool {
    dir.deleteFile("test-symlink") catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    dir.symLink("test-target", "test-symlink", .{}) catch |err| switch (err) {
        error.AccessDenied => return false,
        else => |e| return e,
    };
    try dir.deleteFile("test-symlink");
    return true;
}

pub fn getSymlinkerFromFilesystemTest(
    b: *std.build.Builder,
    metadata_install_dir: std.build.InstallDir,
    metadata_dest_path: []const u8
) !Symlinker {
    // for some reason, build.zig make cache_root a relative path??
    const cache_root_full = b.pathFromRoot(b.cache_root.path.?);
    defer b.allocator.free(cache_root_full);
    try std.fs.cwd().makePath(cache_root_full);

    var cache_root = try std.fs.cwd().openDir(cache_root_full, .{});
    defer cache_root.close();

    if (try testSymlinkSupport(cache_root))
        return Symlinker.host_supports_symlinks;
    
    return Symlinker{ .host_does_not_support_symlinks = b.getInstallPath(metadata_install_dir, metadata_dest_path) };
}

pub const Symlinker = union(enum) {
    host_supports_symlinks: void,
    host_does_not_support_symlinks: []const u8,
    
    pub fn createInstallSymlinkStep(
        self: Symlinker,
        builder: *std.build.Builder,
        symlink_target: []const u8,
        dir: std.build.InstallDir,
        dest_rel_path: []const u8,
    ) *std.build.Step {
        const install_symlink_step = InstallSymlinkStep.create(
            builder,
            symlink_target,
            dir,
            dest_rel_path
        );
        switch (self) {
            .host_supports_symlinks => return &install_symlink_step.step,
            .host_does_not_support_symlinks => |metadata_file| {
                const install_metadata_symlink = InstallMetadataSymlinkStep.create(
                    install_symlink_step,
                    metadata_file,
                );
                return &install_metadata_symlink.step;
            },
        }
    }
};

pub const InstallSymlinkStep = struct {
    step: std.build.Step,
    builder: *std.build.Builder,
    symlink_target: []const u8,
    dir: std.build.InstallDir,
    dest_rel_path: []const u8,

    pub fn create(
        builder: *std.build.Builder,
        symlink_target: []const u8,
        dir: std.build.InstallDir,
        dest_rel_path: []const u8,
    ) *InstallSymlinkStep {
        const result = builder.allocator.create(InstallSymlinkStep) catch unreachable;
        result.* = .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "install symlink",
                .owner = builder,
                .makeFn = make,
            }),
            .builder = builder,
            .symlink_target = symlink_target,
            .dir = dir,
            .dest_rel_path = dest_rel_path,
        };
        return result;
    }

    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(InstallSymlinkStep, "step", step);
        const full_dest_path = self.builder.getInstallPath(self.dir, self.dest_rel_path);
        _ = try updateSymlink(self.symlink_target, full_dest_path, .{});
    }

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
};

pub const InstallMetadataSymlinkStep = struct {
    step: std.build.Step,
    install_symlink_step: *InstallSymlinkStep,
    metadata_file: []const u8,

    pub fn create(
        install_symlink_step: *InstallSymlinkStep,
        metadata_file: []const u8,
    ) *InstallMetadataSymlinkStep {
        const result = install_symlink_step.builder.allocator.create(InstallMetadataSymlinkStep) catch unreachable;
        result.* = .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "install metadata symlink",
                .owner = install_symlink_step.builder,
                .makeFn = make,
            }),
            .install_symlink_step = install_symlink_step,
            .metadata_file = metadata_file,
        };
        return result;
    }

    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(InstallMetadataSymlinkStep, "step", step);
        const full_dest_path = self.install_symlink_step.builder.getInstallPath(self.install_symlink_step.dir, self.install_symlink_step.dest_rel_path);
        std.log.info("TODO: write symlink '{s}' -> '{s}' to metadata file '{s}'", .{
            full_dest_path,
            self.install_symlink_step.symlink_target,
            self.metadata_file,
        });
    }
};
