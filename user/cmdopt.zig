const std = @import("std");
const io = @import("io.zig");
const fatal = @import("fatal.zig");

pub fn getOptArgOrExit(args: [:null] ?[*:0]u8, i: *usize) [*:0]u8 {
    i.* += 1;
    if (i.* >= args.len)
        fatal.fatal("option '{s}' requires an argument\n", .{args[i.* - 1]});
    if (args[i.*]) |arg| return arg;
    unreachable;
}
