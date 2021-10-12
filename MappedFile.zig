const MappedFile = @This();
const std = @import("std");
const builtin = @import("builtin");

pub const Access = enum {
    read_only,
    read_write,
};

data: if (builtin.os.tag == .windows) struct {
    mapping: std.os.windows.HANDLE,
    ptr: [*]align(std.mem.page_size) u8,
} else struct {
    slice: []align(std.mem.page_size) u8,
},

pub fn init(file: std.fs.File, len: usize, access: Access) !MappedFile {
    if (builtin.os.tag == .windows) {
        const mapping = win32.CreateFileMappingW(
            file.handle,
            null,
            switch (access) {
                .read_only => win32.PAGE_READONLY,
                .read_write => win32.PAGE_READWRITE,
            },
            0,
            0,
            null,
        ) orelse return switch (win32.GetLastError()) {
            // TODO: insert error handling
            else => |err| std.os.windows.unexpectedError(err),
        };
        errdefer std.debug.assert(0 != win32.CloseHandle(mapping));
        const ptr = win32.MapViewOfFile(
            mapping,
            switch (access) {
                .read_only => win32.FILE_MAP_READ,
                .read_write => win32.FILE_MAP_READ | win32.FILE_MAP_WRITE,
            },
            0,
            0,
            len,
        ) orelse switch (win32.GetLastError()) {
            else => |err| return std.os.windows.unexpectedError(err),
        };
        return MappedFile { .data = .{ .mapping = mapping, .ptr = ptr } };
    } else {
        return MappedFile { .data = .{ .slice = try std.os.mmap(
            null,
            len,
            switch (access) {
                .read_only => std.os.PROT.READ,
                .read_write => std.os.PROT.READ | std.os.PROT.WRITE,
            },
            std.os.MAP.SHARED,
            file.handle,
            0
        )}};
    }
}

pub fn deinit(self: MappedFile) void {
    if (builtin.os.tag == .windows) {
        std.debug.assert(0 != win32.UnmapViewOfFile(self.data.ptr));
        std.debug.assert(0 != win32.CloseHandle(self.data.mapping));
    } else {
        std.os.munmap(self.data.slice);
    }
}

pub fn getPtr(self: MappedFile) [*]align(std.mem.page_size) u8 {
    if (builtin.os.tag == .windows) {
        return self.data.ptr;
    }
    return self.data.slice.ptr;
}

const win32 = if (builtin.os.tag == .windows) struct {
    pub const GetLastError = std.os.windows.kernel32.GetLastError;
    pub const CloseHandle = std.os.windows.kernel32.CloseHandle;
    pub const PAGE_READONLY = 0x02;
    pub const PAGE_READWRITE = 0x04;
    pub extern "KERNEL32" fn CreateFileMappingW(
        hFile: ?std.os.windows.HANDLE,
        lpFileMappingAttributes: ?*c_void,
        flProtect: u32,
        dwMaximumSizeHigh: u32,
        dwMaximumSizeLow: u32,
        lpName: ?[*:0]const u16,
    ) callconv(@import("std").os.windows.WINAPI) ?std.os.windows.HANDLE;
    pub const FILE_MAP_WRITE = 0x02;
    pub const FILE_MAP_READ  = 0x04;
    pub extern "KERNEL32" fn MapViewOfFile(
        hFileMappingObject: ?std.os.windows.HANDLE,
        dwDesiredAccess: u32,
        dwFileOffsetHigh: u32,
        dwFileOffsetLow: u32,
        dwNumberOfBytesToMap: usize,
    ) callconv(std.os.windows.WINAPI) ?[*]align(std.mem.page_size) u8;
    pub extern "KERNEL32" fn UnmapViewOfFile(
        lpBaseAddress: ?*const c_void,
    ) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
};
