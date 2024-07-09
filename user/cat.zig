// TODO: maybe implement sendfile

const std = @import("std");
const io = @import("io.zig");

var buffer: [std.mem.page_size]u8 = undefined;

pub fn maros_tool_main(args: [:null] ?[*:0]u8) !u8 {
    if (args.len <= 1) {
        try cat(std.posix.STDIN_FILENO);
    } else {
        for (args[1..]) |arg| {
            const fd = std.posix.openZ(arg.?, .{}, undefined) catch |e| {
                try io.printStderr("cat: {s}: open failed with {}", .{arg.?, e});
                return 0xff;
            };
            try cat(fd);
            std.posix.close(fd);
        }
    }
    return 0;
}

fn cat(fd: std.posix.fd_t) !void {
    while (true) {
        const read_result = std.posix.read(fd, &buffer) catch |e| {
            try io.printStderr("cat: read failed with {}", .{e});
            std.process.exit(0xff);
        };
        if (read_result == 0) {
            break;
        }
        const write_result = std.posix.write(std.posix.STDOUT_FILENO, buffer[0 .. read_result]) catch |e| {
            try io.printStderr("cat: write to stdout failed with {}", .{e});
            std.process.exit(0xff);
        };
        if (write_result != read_result) {
            try io.printStderr("cat: write {} to stdout only wrote {}", .{read_result, write_result});
            std.process.exit(0xff);
        }
    }
}
