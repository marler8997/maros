const std = @import("std");
const util = @import("util.zig");

pub fn makeDir(allocator: std.mem.Allocator, image_file: []const u8, sub_path: []const u8, perm: u9) !void {
    var perm_string_buf: [20]u8 = undefined;
    const perm_string = std.fmt.bufPrint(&perm_string_buf, "{o}", .{perm}) catch unreachable;
    const path_arg = std.fmt.allocPrint(allocator, "{s}:{s}", .{image_file, sub_path}) catch unreachable;
    defer allocator.free(path_arg);
    const result = try util.run(allocator, &.{
        "e2mkdir",
        "-G", "0",
        "-O", "0",
        "-P", perm_string,
        path_arg,
    });
    const failed = switch (result.term) {
        .Exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.log.err(
            "e2mkdir for directory '{s}' {}, stdout='{s}', stderr='{s}'",
            .{sub_path, util.fmtTerm(result.term), result.stdout, result.stderr},
        );
        return error.MakeFailed;
    }
}

pub fn installFile(allocator: std.mem.Allocator, image_file: []const u8, src: []const u8, dst: []const u8) !void {
    const dst_arg = std.fmt.allocPrint(allocator, "{s}:{s}", .{image_file, dst}) catch unreachable;
    defer allocator.free(dst_arg);
    const result = try util.run(allocator, &.{
        "e2cp",
        "-G", "0",
        "-O", "0",
        "-p",
        src,
        dst_arg,
    });
    const failed = switch (result.term) {
        .Exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.log.err(
            "e2cp '{s}' '{s}' {}, stdout='{s}', stderr='{s}'",
            .{src, dst, util.fmtTerm(result.term), result.stdout, result.stderr},
        );
        return error.MakeFailed;
    }
}

pub fn installSymLink(allocator: std.mem.Allocator, image_file: []const u8, target_path: []const u8, dst: []const u8) !void {
    const dst_arg = std.fmt.allocPrint(allocator, "{s}:{s}", .{image_file, dst}) catch unreachable;
    defer allocator.free(dst_arg);
    // NOTE: creating symlinks not implemented so we use a hack
    //const result = try util.run(allocator, &.{
    //    "e2ln",
    //    "-s",
    //    target_path,
    //    dst_arg,
    //});
    //const failed = switch (result.term) {
    //    .Exited => |code| code != 0,
    //    else => true,
    //};
    //if (failed) {
    //    std.log.err(
    //        "e2ln '{s}' '{s}' {}, stdout='{s}', stderr='{s}'",
    //        .{target_path, dst, util.fmtTerm(result.term), result.stdout, result.stderr},
    //    );
    //    return error.MakeFailed;
    //}
    {
        const tmp_file = try std.fs.cwd().createFile("tmp-symlink", .{});
        defer tmp_file.close();
        try tmp_file.writer().writeAll(target_path);
    }
    const result = try util.run(allocator, &.{
        "e2cp",
        "-G", "0",
        "-O", "0",
        "-P", "120000", // symlink permissions
        "tmp-symlink",
        dst_arg,
    });
    const failed = switch (result.term) {
        .Exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.log.err(
            "e2cp '{s}' '{s}' {}, stdout='{s}', stderr='{s}'",
            .{target_path, dst, util.fmtTerm(result.term), result.stdout, result.stderr},
        );
        return error.MakeFailed;
    }
    try std.fs.cwd().deleteFile("tmp-symlink");
}
