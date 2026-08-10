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
/// posix sockaddr に依存しない freestanding 表現 (IPv4 base kit) に差し替える。
/// ハンドラ側は `initIp4` / `parseIp4` / `parseIp` / `getPort` / `format` の
/// surface しか触らない (grep 実測)。`fromNet` は accept 境界 (Listener の
/// posix 枝) 専用なので lwip 表現には無い。
pub const Address = if (use_lwip) LwipAddress else PosixAddress;

const PosixAddress = struct {
    inner: std.net.Address,

    pub fn fromNet(a: std.net.Address) PosixAddress {
        return .{ .inner = a };
    }

    pub fn initIp4(addr: [4]u8, port: u16) PosixAddress {
        return .{ .inner = std.net.Address.initIp4(addr, port) };
    }

    pub fn parseIp4(name: []const u8, port: u16) !PosixAddress {
        return .{ .inner = try std.net.Address.parseIp4(name, port) };
    }

    pub fn parseIp(name: []const u8, port: u16) !PosixAddress {
        return .{ .inner = try std.net.Address.parseIp(name, port) };
    }

    pub fn getPort(self: PosixAddress) u16 {
        return self.inner.getPort();
    }

    /// "{f}" フォーマット指定子から呼ばれる (admin/stats.zig の appendAddr)。
    pub fn format(self: PosixAddress, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.inner.format(w);
    }
};

/// lwIP backend の Address。IPv4 のみ (base kit)。posix sockaddr / std.net に
/// 一切依存しない純粋な値型なので riscv32-freestanding でも成立する。
const LwipAddress = struct {
    addr: [4]u8 = .{ 0, 0, 0, 0 },
    port: u16 = 0,

    pub fn initIp4(addr: [4]u8, port: u16) LwipAddress {
        return .{ .addr = addr, .port = port };
    }

    /// "a.b.c.d" のドット4つ組をパース。ホスト名解決はしない (base kit は数値
    /// IP でバインドする)。
    pub fn parseIp4(name: []const u8, port: u16) !LwipAddress {
        var out: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, name, '.');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            if (i >= 4) return error.InvalidIPAddressFormat;
            out[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIPAddressFormat;
        }
        if (i != 4) return error.InvalidIPAddressFormat;
        return .{ .addr = out, .port = port };
    }

    pub fn parseIp(name: []const u8, port: u16) !LwipAddress {
        return parseIp4(name, port);
    }

    pub fn getPort(self: LwipAddress) u16 {
        return self.port;
    }

    /// posix 側 std.net.Address.format と同じ "a.b.c.d:port" 体裁で出力。
    pub fn format(self: LwipAddress, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}:{d}", .{
            self.addr[0], self.addr[1], self.addr[2], self.addr[3], self.port,
        });
    }
};

/// TCP リスナー。listen/accept は backend 固有。posix は std.net.Server を
/// 内包し、lwip は lwip_socket/bind/listen で立てた fd を持つ。ハンドラ側
/// (server.zig / admin/server.zig) はこの型だけを見る。
pub const Listener = struct {
    inner: if (use_lwip) LwipListener else std.net.Server,

    /// `host` (数値 IPv4 文字列) : `port` で listen する。SO_REUSEADDR 有効。
    pub fn bind(host: []const u8, port: u16) !Listener {
        if (use_lwip) return .{ .inner = try LwipListener.bind(host, port) };
        const a = try std.net.Address.parseIp(host, port);
        return .{ .inner = try a.listen(.{ .reuse_address = true }) };
    }

    /// 実際にバインドされたアドレス (started_event 通知後にログ用に読む)。
    pub fn listenAddress(self: *const Listener) Address {
        if (use_lwip) return self.inner.address;
        return Address.fromNet(self.inner.listen_address);
    }

    /// 1 接続を受理。backend の生 stream/addr を io 型に包んで返す。
    pub fn accept(self: *Listener) !Accepted {
        if (use_lwip) {
            const a = try lwip.accept(self.inner.fd);
            return .{ .stream = .{ .handle = a.fd }, .address = Address.initIp4(a.ip, a.port) };
        }
        const conn = try self.inner.accept();
        return .{ .stream = Stream.fromNet(conn.stream), .address = Address.fromNet(conn.address) };
    }

    /// ブロック中の accept() を叩き起こす (SHUT_RDWR)。shutdown シーケンス用。
    pub fn shutdownAccept(self: *Listener) void {
        if (use_lwip) {
            lwip.shutdownBoth(self.inner.fd);
            return;
        }
        std.posix.shutdown(self.inner.stream.handle, .both) catch {};
    }

    pub fn deinit(self: *Listener) void {
        if (use_lwip) {
            lwip.close(self.inner.fd);
            return;
        }
        self.inner.deinit();
    }
};

/// accept() の戻り値。接続 stream + peer アドレス。
pub const Accepted = struct {
    stream: Stream,
    address: Address,
};

/// lwip backend の listener 状態。fd + バインドアドレス (getsockname を避け、
/// bind 時の host/port をそのまま保持)。
const LwipListener = struct {
    fd: Handle,
    address: Address,

    fn bind(host: []const u8, port: u16) !LwipListener {
        const addr = try Address.parseIp(host, port);
        const fd = try lwip.listen(addr.addr, port);
        return .{ .fd = fd, .address = addr };
    }
};

/// source fd の強制 shutdown (evictStaleSource が古い基準局を kill する用)。
pub fn shutdownHandle(handle: Handle) void {
    if (use_lwip) {
        lwip.shutdownBoth(handle);
        return;
    }
    std.posix.shutdown(handle, .both) catch {};
}

// ── socket options (net/sockopt.zig + server の keep-alive がここ経由) ────────
// 長寿命ストリーミング接続の tuning。posix は std.posix.setsockopt、lwip は
// lwip_setsockopt (定数は SO_*/TCP_* 同名) に委譲する。失敗は握り潰す
// (古い kernel / 未サポート lwip オプションで die しないため)。

/// 送信タイムアウト (writeAll が詰まった client を drop)。ミリ秒精度。
pub fn setSendTimeoutMs(handle: Handle, ms: u32) void {
    if (use_lwip) return lwip.setSockTimeoutMs(handle, lwip.SO_SNDTIMEO, ms);
    setPosixTimeoutMs(handle, std.posix.SO.SNDTIMEO, ms);
}

/// 受信タイムアウト (keep-alive アイドル上限 / GGA 待ち)。ミリ秒精度。
pub fn setRecvTimeoutMs(handle: Handle, ms: u32) void {
    if (use_lwip) return lwip.setSockTimeoutMs(handle, lwip.SO_RCVTIMEO, ms);
    setPosixTimeoutMs(handle, std.posix.SO.RCVTIMEO, ms);
}

/// TCP keep-alive を有効化し半開放接続を kernel/lwip に検出させる。
pub fn enableKeepAlive(handle: Handle, idle_secs: c_int, intvl_secs: c_int, count: c_int) void {
    if (use_lwip) {
        lwip.enableKeepAlive(handle, idle_secs, intvl_secs, count);
        return;
    }
    const enable: c_int = 1;
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};
    // TCP_KEEP* は Linux でのみ設定 (他 OS は定数が無い / 意味が違う)。
    if (builtin.os.tag == .linux) {
        std.posix.setsockopt(handle, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPIDLE, std.mem.asBytes(&idle_secs)) catch {};
        std.posix.setsockopt(handle, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPINTVL, std.mem.asBytes(&intvl_secs)) catch {};
        std.posix.setsockopt(handle, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPCNT, std.mem.asBytes(&count)) catch {};
    }
}

fn setPosixTimeoutMs(handle: Handle, optname: u32, ms: u32) void {
    const tv = std.posix.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, optname, std.mem.asBytes(&tv)) catch {};
}

const builtin = @import("builtin");
