//! io.zig — バックエンド差し替え可能な I/O 抽象層。
//!
//! caster のハンドラ群 (ntrip/source, ntrip/client, fkp/vrs, fkp/upstream,
//! admin/server) はこれまで `std.net.Stream` / `std.net.Address` を引数として
//! 末端まで貫通させていた。ESP32-P4 (M5Stack Tab5: ESP-IDF + lwIP + FreeRTOS)
//! へ移植する際、`std.net.Stream` は posix ソケットに、`std.net.Address` は
//! posix sockaddr に依存するため riscv32-freestanding では成立しない。
//!
//! そこで薄い newtype をここに挟み、ハンドラ側は `io.Stream` / `io.Address`
//! だけを見るようにする。backend は build option `-Dio-backend` で選ぶ:
//!
//!   - posix (default): host / Linux / クラウド caster。std.net へ 1:1 委譲。
//!   - lwip (TODO)    : ESP-IDF。io_lwip.zig が lwip_read/write/close で実装。
//!
//! Stream に対して実際に呼ばれる surface は writeAll / read / close / handle の
//! 4 つだけ (grep 実測)。listen / accept は backend 固有なので listener 側
//! (現状 server.zig の std.net.Server) で生成し、accept 境界で
//! `Stream.fromNet` / `Address.fromNet` に変換して以降は io 型で流す。

const std = @import("std");
const build_options = @import("build_options");

/// true なら ESP-IDF/lwIP backend。
pub const use_lwip = build_options.io_backend == .lwip;

/// lwip backend の実装。posix build では comptime-false 分岐に置くことで
/// io_lwip.zig (lwIP ヘッダ依存) が parse されないようにする。
const lwip = if (use_lwip) @import("io_lwip.zig") else struct {};

/// ソケットハンドル型。posix=fd_t、lwip=c_int (lwip socket descriptor)。
/// source.zig が reconnect の外部 shutdown 用に atomic で保持する型でもある。
pub const Handle = if (use_lwip) lwip.Handle else std.posix.fd_t;

/// 双方向 TCP ストリーム。ハンドラ群が末端まで貫通させる型。
///
/// surface は writeAll / read / close と、setsockopt/shutdown 用に生 fd を
/// 取り出す `handle` フィールドのみ。
pub const Stream = struct {
    handle: Handle,

    /// std.net.Server.accept() が返す std.net.Stream を io.Stream に包む。
    /// posix backend 専用 (accept 境界でのみ使う)。
    pub fn fromNet(s: std.net.Stream) Stream {
        return .{ .handle = s.handle };
    }

    /// posix backend の委譲先。std.net.Stream は handle 1 フィールドのみなので
    /// その場で再構築できる (net.zig:1902-1910 で確認)。
    inline fn asNet(self: Stream) std.net.Stream {
        return .{ .handle = self.handle };
    }

    // 戻り値の error set は backend 非依存にするため anyerror。ハンドラ側は
    // どこも catch/return するだけで error 種別を検査しないので実害なし。
    pub fn read(self: Stream, buffer: []u8) anyerror!usize {
        if (use_lwip) return lwip.read(self.handle, buffer);
        return self.asNet().read(buffer);
    }

    pub fn writeAll(self: Stream, bytes: []const u8) anyerror!void {
        if (use_lwip) return lwip.writeAll(self.handle, bytes);
        return self.asNet().writeAll(bytes);
    }

    pub fn close(self: Stream) void {
        if (use_lwip) {
            lwip.close(self.handle);
            return;
        }
        self.asNet().close();
    }
};

/// 発信 TCP 接続 (fkp/upstream が上流 caster へ rover 接続するのに使う)。
/// posix backend は std.net の DNS 解決 + connect に委譲。lwip backend では
/// lwip の getaddrinfo/connect に置換する。
pub fn tcpConnectToHost(alloc: std.mem.Allocator, name: []const u8, port: u16) !Stream {
    if (use_lwip) return Stream{ .handle = try lwip.tcpConnectToHost(alloc, name, port) };
    const s = try std.net.tcpConnectToHost(alloc, name, port);
    return Stream.fromNet(s);
}

/// IP アドレス + port を持つ純粋な値型 (I/O はしない)。
///
/// posix backend では std.net.Address を内包。lwip backend では
/// sockaddr_in ベースの小さな表現に差し替える (posix sockaddr に依存しない)。
pub const Address = struct {
    inner: std.net.Address,

    pub fn fromNet(a: std.net.Address) Address {
        return .{ .inner = a };
    }

    pub fn initIp4(addr: [4]u8, port: u16) Address {
        return .{ .inner = std.net.Address.initIp4(addr, port) };
    }

    pub fn parseIp4(name: []const u8, port: u16) !Address {
        return .{ .inner = try std.net.Address.parseIp4(name, port) };
    }

    pub fn parseIp(name: []const u8, port: u16) !Address {
        return .{ .inner = try std.net.Address.parseIp(name, port) };
    }

    pub fn getPort(self: Address) u16 {
        return self.inner.getPort();
    }

    /// "{f}" フォーマット指定子から呼ばれる (admin/stats.zig の appendAddr)。
    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.inner.format(w);
    }
};
