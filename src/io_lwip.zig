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

// ── inbound listener / accept (rover-facing caster sockets) ──────────────────

/// bind + listen on `ip`:`port` (IPv4). Returns the listening socket fd.
pub fn listen(ip: [4]u8, port: u16) anyerror!Handle {
    const fd = c.lwip_socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.lwip_close(fd);

    const one: c_int = 1;
    _ = c.lwip_setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));

    var sa = std.mem.zeroes(c.struct_sockaddr_in);
    sa.sin_family = c.AF_INET;
    sa.sin_port = std.mem.nativeToBig(u16, port);
    // sin_addr は network byte order。ip[0] が最上位オクテット。
    sa.sin_addr.s_addr = @bitCast(ip);

    if (c.lwip_bind(fd, @ptrCast(&sa), @sizeOf(@TypeOf(sa))) != 0) return error.BindFailed;
    if (c.lwip_listen(fd, 8) != 0) return error.ListenFailed;
    return fd;
}

/// accept() の戻り: 接続 fd + peer の IPv4/port。io.zig 側で io.Address に包む。
pub const Accepted = struct { fd: Handle, ip: [4]u8, port: u16 };

pub fn accept(listen_fd: Handle) anyerror!Accepted {
    var sa = std.mem.zeroes(c.struct_sockaddr_in);
    var len: c.socklen_t = @sizeOf(@TypeOf(sa));
    const fd = c.lwip_accept(listen_fd, @ptrCast(&sa), &len);
    if (fd < 0) return error.AcceptFailed;
    const ip: [4]u8 = @bitCast(sa.sin_addr.s_addr);
    return .{ .fd = fd, .ip = ip, .port = std.mem.bigToNative(u16, sa.sin_port) };
}

/// SHUT_RDWR: ブロック中の accept()/read() を叩き起こす。
pub fn shutdownBoth(handle: Handle) void {
    _ = c.lwip_shutdown(handle, c.SHUT_RDWR);
}

// ── socket options ───────────────────────────────────────────────────────────
// ESP-IDF の lwIP は SO_RCVTIMEO/SO_SNDTIMEO を struct timeval で受ける
// (LWIP_SO_RCVTIMEO=1)。定数名は BSD と同じ。

pub const SO_RCVTIMEO = c.SO_RCVTIMEO;
pub const SO_SNDTIMEO = c.SO_SNDTIMEO;

pub fn setSockTimeoutMs(handle: Handle, optname: c_int, ms: u32) void {
    const tv = c.struct_timeval{ .tv_sec = @intCast(ms / 1000), .tv_usec = @intCast((ms % 1000) * 1000) };
    _ = c.lwip_setsockopt(handle, c.SOL_SOCKET, optname, &tv, @sizeOf(@TypeOf(tv)));
}

pub fn enableKeepAlive(handle: Handle, idle_secs: c_int, intvl_secs: c_int, count: c_int) void {
    const one: c_int = 1;
    _ = c.lwip_setsockopt(handle, c.SOL_SOCKET, c.SO_KEEPALIVE, &one, @sizeOf(c_int));
    _ = c.lwip_setsockopt(handle, c.IPPROTO_TCP, c.TCP_KEEPIDLE, &idle_secs, @sizeOf(c_int));
    _ = c.lwip_setsockopt(handle, c.IPPROTO_TCP, c.TCP_KEEPINTVL, &intvl_secs, @sizeOf(c_int));
    _ = c.lwip_setsockopt(handle, c.IPPROTO_TCP, c.TCP_KEEPCNT, &count, @sizeOf(c_int));
}
