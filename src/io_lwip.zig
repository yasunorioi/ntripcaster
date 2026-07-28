//! io_lwip.zig — ESP-IDF / lwIP backend for io.Stream (see io.zig).
//!
//! Compiled ONLY when `-Dio-backend=lwip` (io.zig imports it behind a
//! comptime-false branch otherwise, so the host/posix build never parses it).
//!
//! Requires lwIP headers on the include path. Those are provided by the
//! ESP-IDF build that compiles this Zig tree as a static library and links it
//! into the firmware — so this file is NOT verifiable with a plain `zig build`
//! on a host without lwIP. It is a skeleton for the embedded (Tab5) target.
//!
//! Scope: the socket byte-stream ops (read / writeAll / close) and outbound
//! connect. The inbound listener/accept path is intentionally NOT here yet —
//! that plus a freestanding Address representation is the remaining embedded
//! caster work (M2+). For a local-wired base (Mosaic USB CDC), the rover-facing
//! sockets are what these back; the base itself feeds via source.runLocalSource,
//! not through a socket at all.

const std = @import("std");

// lwIP's BSD-style socket API. Names match lwip/sockets.h + lwip/netdb.h.
const c = @cImport({
    @cInclude("lwip/sockets.h");
    @cInclude("lwip/netdb.h");
});

/// lwIP socket descriptor (an int, like a posix fd but from lwip_socket()).
pub const Handle = c_int;

pub fn read(handle: Handle, buffer: []u8) anyerror!usize {
    const n = c.lwip_read(handle, buffer.ptr, buffer.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

pub fn writeAll(handle: Handle, bytes: []const u8) anyerror!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = c.lwip_write(handle, bytes.ptr + sent, bytes.len - sent);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}

pub fn close(handle: Handle) void {
    _ = c.lwip_close(handle);
}

/// Outbound connect (fkp/upstream uses this to rover into an upstream caster).
/// getaddrinfo + socket + connect. Caller frees nothing; we own the fd on ok.
pub fn tcpConnectToHost(alloc: std.mem.Allocator, name: []const u8, port: u16) anyerror!Handle {
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrintZ(&port_buf, "{d}", .{port});

    // name may not be null-terminated; dupe with a sentinel for the C call.
    const name_z = try alloc.dupeZ(u8, name);
    defer alloc.free(name_z);

    var hints = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_INET; // lwIP: IPv4 base kit
    hints.ai_socktype = c.SOCK_STREAM;

    var res: ?*c.struct_addrinfo = null;
    if (c.lwip_getaddrinfo(name_z.ptr, port_str.ptr, &hints, &res) != 0 or res == null) {
        return error.DnsFailed;
    }
    defer c.lwip_freeaddrinfo(res);

    const ai = res.?;
    const fd = c.lwip_socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.lwip_close(fd);

    if (c.lwip_connect(fd, ai.ai_addr, ai.ai_addrlen) != 0) {
        return error.ConnectFailed;
    }
    return fd;
}
