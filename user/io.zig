const std = @import("std");
//pub fn fdWrite(fd: std.os.fd_t, bytes: []const u8) WriteError!usize {
//    return std.os.write(fd, bytes);
//}
//pub const FdWriter = std.io.Writer(std.os.fd_t, std.fs.File.WriteError, fdWrite);

const Nothing = struct {};
fn stdoutWrite(_: Nothing, bytes: []const u8) std.fs.File.WriteError!usize {
    return std.os.write(std.os.STDOUT_FILENO, bytes);
}
fn stderrWrite(_: Nothing, bytes: []const u8) std.fs.File.WriteError!usize {
    return std.os.write(std.os.STDERR_FILENO, bytes);
}
pub const StdoutWriter = std.io.Writer(Nothing, std.fs.File.WriteError, stdoutWrite);
pub const StderrWriter = std.io.Writer(Nothing, std.fs.File.WriteError, stderrWrite);

pub fn printStdout(comptime fmt: []const u8, args: anytype) !void {
    return (StdoutWriter { .context = .{} }).print(fmt, args);
}
pub fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    return (StderrWriter { .context = .{} }).print(fmt, args);
}
