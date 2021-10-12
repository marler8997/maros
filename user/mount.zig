const std = @import("std");
const io = @import("io.zig");
const cmdopt = @import("cmdopt.zig");

fn usage() void {
    io.printStdout(
        \\Usage: mount [-options] source target
        \\Options:
        \\  -t     file system type
        \\  --allow-non-empty-target
        \\
    );
}
pub fn maros_tool_main(all_args: [:null] ?[*:0]u8) !u8 {

    var fstypes_opt: ?[*:0]u8 = null;
    var mount_options: ?[*:0]u8 = null;

    const args = blk: {
        const args = all_args[1..];
        var new_args_len: usize = 0;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.spanZ(args[i].?);
            if (arg[0] != '-') {
                args[new_args_len] = arg;
                new_args_len += 1;
            } else if (std.mem.eql(u8, arg, "-t")) {
                fstypes_opt = cmdopt.getOptArgOrExit(args, &i);
            } else if (std.mem.eql(u8, arg, "-o")) {
                mount_options = cmdopt.getOptArgOrExit(args, &i);
            } else {
                try io.printStdout("unknown command-line option '{s}'", .{arg});
                return 1;
            }
        }
        break :blk args[0..new_args_len];
    };

    if (args.len != 2) {
        try io.printStderr("expected 2 non-option command line arguments but got {}", .{args.len});
        return 1;
    }
    const source = args[0].?;
    const target = args[1].?;

    const fstypes = fstypes_opt orelse {
        try io.printStderr("no -t is not implemented", .{});
        return 1;
    };
    var it = FsTypeIterator { .str = fstypes };
    while (it.next()) |fstype| {
        fstype.ptr[fstype.len] = 0; // make it null-terminated
        const result = std.os.linux.mount(
            source,
            target,
            std.meta.assumeSentinel(fstype.ptr, 0),
            0,
            @ptrToInt(mount_options)
        );
        switch (std.os.errno(result)) {
            .SUCCESS => return 0,
            else => |e| {
                std.log.warn("failed to mount as type \"{s}\" with {}", .{fstype, e});
            },
        }
    }
    return 1;
}

const FsTypeIterator = struct {
    str: [*:0]u8,

    pub fn next(self: *FsTypeIterator) ?[]u8 {
        if (self.str[0] == 0)
            return null;

        const fstype = self.str;
        while (true) {
            if (self.str[0] == ',') {
                const result = fstype[0 .. @ptrToInt(self.str) - @ptrToInt(fstype)];
                self.str += 1;
                return result;
            }
            self.str += 1;
            if (self.str[0] == 0) {
                return fstype[0 .. @ptrToInt(self.str) - @ptrToInt(fstype)];
            }
        }
    }
};
