const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.cwd);

comptime {
    if (builtin.os.tag != .macos) {
        @compileError("cwd.zig: proc_pidinfo API is macOS-specific. This module should only be compiled on macOS.");
    }
}

pub const CwdError = error{
    ProcessNotFound,
    BufferTooSmall,
    SystemError,
    OutOfMemory,
};

const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
});

pub fn getCwd(allocator: std.mem.Allocator, pid: std.c.pid_t) CwdError![]const u8 {
    var vnode_info: c.struct_proc_vnodepathinfo = undefined;

    const result = c.proc_pidinfo(
        @intCast(pid),
        c.PROC_PIDVNODEPATHINFO,
        0,
        &vnode_info,
        @sizeOf(c.struct_proc_vnodepathinfo),
    );

    if (result <= 0) {
        log.warn("failed to get cwd for pid {d}", .{pid});
        return error.ProcessNotFound;
    }

    const cwd_path = std.mem.sliceTo(&vnode_info.pvi_cdir.vip_path, 0);

    if (cwd_path.len == 0) {
        return error.ProcessNotFound;
    }

    return allocator.dupe(u8, cwd_path);
}

pub fn getBasename(path: []const u8) []const u8 {
    // std handles the component split; the guard restores this module's edge
    // behavior: root ("/") → "/" rather than "", and empty stays empty.
    const base = std.fs.path.basename(path);
    if (base.len > 0) return base;
    return if (path.len == 0) "" else "/";
}

test "getBasename - simple path" {
    try std.testing.expectEqualStrings("bar", getBasename("/foo/bar"));
    try std.testing.expectEqualStrings("baz", getBasename("/foo/bar/baz"));
}

test "getBasename - root" {
    try std.testing.expectEqualStrings("/", getBasename("/"));
}

test "getBasename - trailing slash" {
    try std.testing.expectEqualStrings("bar", getBasename("/foo/bar/"));
}

test "getBasename - no slash" {
    try std.testing.expectEqualStrings("foo", getBasename("foo"));
}

test "getBasename - empty" {
    try std.testing.expectEqualStrings("", getBasename(""));
}
