//! io_lwip.zig — ESP-IDF / lwIP backend for io.Stream (see io.zig).
//!
//! Compiled ONLY when `-Dio-backend=lwip` (io.zig imports it behind a
//! comptime-false branch otherwise, so the host/posix build never parses it).
//!
//! This file does NOT @cImport the lwIP headers. Zig 0.16's translate-c cannot
//! resolve ESP-IDF newlib's `#include_next <sys/reent.h>` layering that
//! lwip/sockets.h pulls in, so the socket calls are implemented in a thin C
//! shim (components/ntripcaster/caster_net.c) compiled by the IDF GCC toolchain
//! and declared here as `extern fn`. See caster_shim.h for the ABI contract
//! (IPv4-only; addresses cross as a network-order u32, ports in host order).

const std = @import("std");

/// lwIP socket descriptor (an int fd, like a posix fd but from the shim).
pub const Handle = c_int;

// ── C shim (components/ntripcaster/caster_net.c) ─────────────────────────────
extern fn caster_sock_read(fd: Handle, buf: [*]u8, len: usize) c_long;
extern fn caster_sock_write(fd: Handle, buf: [*]const u8, len: usize) c_long;
extern fn caster_sock_close(fd: Handle) void;
extern fn caster_sock_shutdown(fd: Handle) void;
extern fn caster_sock_connect(host: [*:0]const u8, port: u16) Handle;
extern fn caster_sock_listen(ip_be: u32, port: u16) Handle;
extern fn caster_sock_accept(listen_fd: Handle, out_ip_be: *u32, out_port: *u16) Handle;
extern fn caster_sock_set_rcvtimeo_ms(fd: Handle, ms: u32) void;
extern fn caster_sock_set_sndtimeo_ms(fd: Handle, ms: u32) void;
extern fn caster_sock_keepalive(fd: Handle, idle_secs: c_int, intvl_secs: c_int, count: c_int) void;

pub fn read(handle: Handle, buffer: []u8) anyerror!usize {
    const n = caster_sock_read(handle, buffer.ptr, buffer.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

pub fn writeAll(handle: Handle, bytes: []const u8) anyerror!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = caster_sock_write(handle, bytes.ptr + sent, bytes.len - sent);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}

pub fn close(handle: Handle) void {
    caster_sock_close(handle);
}

/// Outbound connect (fkp/upstream uses this to rover into an upstream caster).
/// The shim does getaddrinfo + socket + connect. Caller owns the fd on ok.
pub fn tcpConnectToHost(alloc: std.mem.Allocator, name: []const u8, port: u16) anyerror!Handle {
    // name may not be null-terminated; dupe with a sentinel for the C call.
    const name_z = try alloc.dupeZ(u8, name);
    defer alloc.free(name_z);

    const fd = caster_sock_connect(name_z.ptr, port);
    if (fd < 0) return error.ConnectFailed;
    return fd;
}

// ── inbound listener / accept (rover-facing caster sockets) ──────────────────

/// bind + listen on `ip`:`port` (IPv4). Returns the listening socket fd.
/// `ip` octets are network order (ip[0] is the most-significant octet); the
/// @bitCast to u32 preserves that byte layout for struct in_addr.s_addr.
pub fn listen(ip: [4]u8, port: u16) anyerror!Handle {
    const fd = caster_sock_listen(@bitCast(ip), port);
    if (fd < 0) return error.BindFailed;
    return fd;
}

/// accept() の戻り: 接続 fd + peer の IPv4/port。io.zig 側で io.Address に包む。
pub const Accepted = struct { fd: Handle, ip: [4]u8, port: u16 };

pub fn accept(listen_fd: Handle) anyerror!Accepted {
    var ip_be: u32 = 0;
    var port: u16 = 0;
    const fd = caster_sock_accept(listen_fd, &ip_be, &port);
    if (fd < 0) return error.AcceptFailed;
    return .{ .fd = fd, .ip = @bitCast(ip_be), .port = port };
}

/// SHUT_RDWR: ブロック中の accept()/read() を叩き起こす。
pub fn shutdownBoth(handle: Handle) void {
    caster_sock_shutdown(handle);
}

// ── socket options ───────────────────────────────────────────────────────────

pub fn setSendTimeoutMs(handle: Handle, ms: u32) void {
    caster_sock_set_sndtimeo_ms(handle, ms);
}

pub fn setRecvTimeoutMs(handle: Handle, ms: u32) void {
    caster_sock_set_rcvtimeo_ms(handle, ms);
}

pub fn enableKeepAlive(handle: Handle, idle_secs: c_int, intvl_secs: c_int, count: c_int) void {
    caster_sock_keepalive(handle, idle_secs, intvl_secs, count);
}
