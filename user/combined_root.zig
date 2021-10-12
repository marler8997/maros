const std = @import("std");
const tools = @import("tools.gen.zig");
const io = @import("io.zig");

pub fn main() u8 {
    const args = @bitCast([:null] ?[*:0]u8, std.os.argv);
    const arg0 = std.fs.path.basename(std.mem.spanZ(args[0].?));
    //
    // TODO: would a comptimeStringMap be better here??
    //       should do some perf testing
    //
    inline for (tools.tool_names) |tool_name| {
        if (std.mem.eql(u8, arg0, tool_name)) {
            return @field(tools, tool_name).maros_tool_main(args)
                catch |e| std.debug.panic("{}", .{e});
        }
    }
    io.printStderr("{s}: command not found\n", .{arg0}) catch |e| std.debug.panic("{}", .{e});
    return 0xff;
}
