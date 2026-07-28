//! ntrip/source.zig — NTRIPソース（基準局）接続ハンドラ
//!
//! 原典 source.c の source_login() / source_func() / add_chunk() を Zig で再実装。
//! SOURCE コマンドで接続した基準局からRTCMデータを受信し、リングバッファに格納する。
//! 受信データを並行して RTCM3 フレーム解析し、メッセージタイプ統計を Source に蓄積する。

const std = @import("std");
const io = @import("../io.zig");
const server = @import("../server.zig");
const auth = @import("../auth/basic.zig");
const protocol = @import("protocol.zig");
const relay = @import("../relay/engine.zig");
const rtcm3 = @import("rtcm3.zig");
const sockopt = @import("../net/sockopt.zig");
const sourcetable = @import("sourcetable.zig");

/// 既存 mount との衝突時、何ミリ秒以上 idle なら旧 source を強制 evict するか。
/// 30 秒は RTCM 基準局の典型送出間隔 (1Hz) より十分大きく、かつ caster 側
/// 回線瞬断からの reconnect を待つには短い、を狙った値。
pub const STALE_SOURCE_IDLE_MS: i64 = 30_000;

/// マウントポイントに接続中のソース（基準局）。
pub const Source = struct {
    mount: []const u8,
    ring: relay.RingBuffer,
    /// false になるとクライアントループが終了する
    active: std.atomic.Value(bool),
    /// 現在接続中のクライアント数。destroy() はゼロになるまで待機する
    client_count: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    /// RTCM3 ストリームを検出したら true（sourceLoop が設定）
    rtcm_detected: bool,
    /// 観測済み RTCM3 メッセージタイプ → カウント（sourceLoop が更新）
    msg_types: std.AutoHashMapUnmanaged(u16, u32),
    /// msg_types / bytes_in / last_data_at_ms をまとめて保護する Mutex。
    /// 32-bit ARM/MIPSEL で 64-bit atomic が無いため、Mutex で u64/i64 を直接保護する。
    msg_lock: std.Thread.Mutex,

    // ── Telemetry ───────────────────────────────────────────────────────
    /// 接続元アドレス（accept() 時点）
    peer_addr: io.Address,
    /// 受信累積バイト数（msg_lock で保護）
    bytes_in: u64,
    /// 接続確立ミリ秒タイムスタンプ
    started_at_ms: i64,
    /// 最後にデータを受信したミリ秒タイムスタンプ（msg_lock で保護）
    last_data_at_ms: i64,
    /// RTCM3 1005/1006 から抽出した基準局座標。未受信の場合 null
    /// （msg_lock で保護）
    station: ?rtcm3.StationCoord,
    /// このソース由来で client が BufferOverrun (= ring buffer 追従失敗)
    /// で切断された累積回数
    overrun_disconnects: std.atomic.Value(u64),
    /// このソースの TCP ストリームの fd。新規 SOURCE がこの mount に
    /// 来たとき、既存接続を外から shutdown して reconnect を即時通すために
    /// 持っておく。null の場合は handleSource がまだ設定していない瞬間。
    stream_handle: std.atomic.Value(io.Handle),

    pub fn create(
        alloc: std.mem.Allocator,
        mount: []const u8,
        peer_addr: io.Address,
    ) !*Source {
        const s = try alloc.create(Source);
        const now = std.time.milliTimestamp();
        s.* = .{
            .mount = try alloc.dupe(u8, mount),
            .ring = .{},
            .active = std.atomic.Value(bool).init(true),
            .client_count = std.atomic.Value(u32).init(0),
            .alloc = alloc,
            .rtcm_detected = false,
            .msg_types = .{},
            .msg_lock = .{},
            .peer_addr = peer_addr,
            .bytes_in = 0,
            .started_at_ms = now,
            .last_data_at_ms = now,
            .station = null,
            .overrun_disconnects = std.atomic.Value(u64).init(0),
            .stream_handle = std.atomic.Value(io.Handle).init(-1),
        };
        return s;
    }

    pub fn destroy(self: *Source) void {
        self.active.store(false, .seq_cst);
        self.msg_types.deinit(self.alloc);
        self.alloc.free(self.mount);
        self.alloc.destroy(self);
    }
};

/// V1 / V2 共通のエラー応答。V1: 平文 "ERROR - ..." 、V2: HTTP/1.1 ステータスライン。
fn writeSourceError(stream: io.Stream, is_v2: bool, v1_msg: []const u8, v2_status: []const u8) void {
    if (is_v2) {
        var buf: [256]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf,
            "HTTP/1.1 {s}\r\n" ++
            "Server: NTRIP NtripCaster/{s}\r\n" ++
            "Ntrip-Version: Ntrip/2.0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
            .{ v2_status, sourcetable.CASTER_VERSION },
        ) catch return;
        stream.writeAll(resp) catch {};
    } else {
        stream.writeAll(v1_msg) catch {};
    }
}

/// ソース接続のエントリポイント。
///
/// 処理フロー (V1 SOURCE / V2 POST 共通):
///   1. パスワード検証 (V1: inline password / V2: Basic auth_header)
///   2. Source-Agent が NTRIP 準拠か検証（§2f BKG差異）
///   3. マウント二重登録チェック
///   4. V2 の場合: Expect: 100-continue があれば "HTTP/1.1 100 Continue" を先送り
///   5. 成功応答 (V1: "OK\r\n" / V2: "HTTP/1.1 200 OK" + headers)
///   6. RTCMデータ受信ループ → RingBuffer に writeChunk
///   7. 切断時にマウント解放、active=false でクライアントを通知
pub fn handleSource(
    stream: io.Stream,
    state: *server.ServerState,
    login: protocol.SourceLogin,
    peer_addr: io.Address,
) void {
    // 1. パスワード検証
    var pw_ok = false;
    if (login.is_v2) {
        // V2: Authorization: Basic <base64(user:pass)> から password を取り出して照合
        if (login.auth_header) |ah| {
            var cred_buf: [512]u8 = undefined;
            if (auth.extractCredentials(ah, &cred_buf)) |cred| {
                pw_ok = auth.authenticateSource(state.config, cred.pass);
            } else |_| {}
        }
    } else {
        // V1: inline password
        pw_ok = auth.authenticateSource(state.config, login.password);
    }
    if (!pw_ok) {
        writeSourceError(stream, login.is_v2, "ERROR - Bad Password\r\n", "401 Unauthorized");
        state.logger.warn("source rejected: bad password for mount {s}", .{login.mount});
        return;
    }

    // 2. NTRIP エージェント検証（Source-Agent ヘッダー必須ではないが推奨）
    if (login.agent) |agent| {
        if (!protocol.isNtripAgent(agent)) {
            writeSourceError(stream, login.is_v2, "ERROR - Not NTRIP\r\n", "400 Bad Request");
            state.logger.warn("source rejected: non-NTRIP agent '{s}'", .{agent});
            return;
        }
    }

    // 3. ソース数上限チェック
    if (state.sourceCount() >= state.config.max_sources) {
        writeSourceError(stream, login.is_v2, "ERROR - Too Many Sources\r\n", "503 Service Unavailable");
        state.logger.warn("source rejected: max_sources ({d}) reached", .{state.config.max_sources});
        return;
    }

    // 4. Source オブジェクト作成
    const src = Source.create(state.alloc, login.mount, peer_addr) catch |err| {
        writeSourceError(stream, login.is_v2, "ERROR - Internal Error\r\n", "500 Internal Server Error");
        state.logger.err("Source.create failed: {}", .{err});
        return;
    };

    // 5. マウント登録
    //   先に旧 source の stale 判定 + 強制 evict。caster 側回線瞬断後の
    //   reconnect で「half-open の旧接続が mount 枠を握ったまま」となるのを
    //   防ぐ。新 SOURCE は即座にこの mount を取り返せる。
    if (state.evictStaleSource(login.mount, STALE_SOURCE_IDLE_MS)) {
        state.logger.warn(
            "source {s}: evicted stale connection (idle > {d}ms), accepting new",
            .{ login.mount, STALE_SOURCE_IDLE_MS },
        );
    }
    state.registerSource(src) catch {
        src.destroy();
        writeSourceError(stream, login.is_v2, "ERROR - Mount already in use\r\n", "409 Conflict");
        state.logger.warn("source rejected: mount {s} already in use", .{login.mount});
        return;
    };

    // evict 経路から外から shutdown するため、struct に fd を published。
    src.stream_handle.store(stream.handle, .seq_cst);

    defer {
        // 新 SOURCE が evict 経由で同じ mount を既に握ってる場合、ここで
        // 新エントリを誤って消さないよう "自分が登録した src と一致するときだけ
        // 外す"。
        state.unregisterSourceIfSame(login.mount, src);
        // 全クライアントが clientLoop を抜けるまで待機（最大 2 秒）
        var waited: u32 = 0;
        while (src.client_count.load(.seq_cst) > 0 and waited < 200) : (waited += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        src.destroy();
    }

    // half-open 検出: 75 秒 (60+5*3) で kernel が死亡判定 → 次の read で
    // エラーを返してこのスレッドが defer 経由で cleanup できる。
    sockopt.configureStreamingSocket(stream);

    // 6. 成功応答
    if (login.is_v2) {
        // V2: 認証通過 + Expect: 100-continue があれば "100 Continue" を先送りしてから body 受信
        if (login.expects_100) {
            stream.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return;
        }
        var resp_buf: [256]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Server: NTRIP NtripCaster/{s}\r\n" ++
            "Ntrip-Version: Ntrip/2.0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
            .{sourcetable.CASTER_VERSION},
        ) catch return;
        stream.writeAll(resp) catch return;
    } else {
        stream.writeAll("OK\r\n") catch return;
    }
    state.logger.info("source connected: mount={s} v2={}", .{ login.mount, login.is_v2 });

    // 7. RTCMデータ受信ループ
    //
    // 注意: V2 POST body は "Transfer-Encoding: chunked" のはずだが、本実装は
    // chunked decode をしない。RTCM3 フレームスキャンが先頭から自前で同期する
    // ため、chunk size 行を「未知バイト列」として読み飛ばしても 99% 正常動作する
    // (str2str など主要 V2 pusher は chunked headers なしに raw stream を流す
    // 実装も多い)。厳密 chunked 対応は将来 issue。
    sourceLoop(stream, src);

    state.logger.info("source disconnected: mount={s}", .{login.mount});
}

/// メッセージタイプを Source に記録する（スレッドセーフ）。
fn recordMsgType(src: *Source, msg_type: u16) void {
    src.msg_lock.lock();
    defer src.msg_lock.unlock();
    const gop = src.msg_types.getOrPut(src.alloc, msg_type) catch return;
    if (gop.found_existing) {
        gop.value_ptr.* += 1;
    } else {
        gop.value_ptr.* = 1;
    }
}

/// チャンク跨ぎの RTCM3 パース状態を保持しつつ、受信バイトを Source に流す
/// 共有プリミティブ。network SOURCE (sourceLoop) と、ローカル配線 base
/// (runLocalSource) の両方がこの feed を通す。これにより UART/USB fed の
/// embedded base でも、msg_types 統計・基準局座標・rtcm_detected が network
/// source と全く同じに埋まる（admin / sourcetable に反映される）。
pub const SourceFeeder = struct {
    /// RTCM3 フレーム解析用バッファ（チャンク跨ぎ対応：最大 2 チャンク分）
    parse_buf: [relay.RingBuffer.CHUNK_SIZE * 2]u8 = undefined,
    parse_len: usize = 0,

    /// 受信 1 チャンクを処理する: ring へ透過転送 + telemetry + RTCM3 スキャン。
    ///
    /// 注意: ring.writeChunk は raw バイトをそのまま流すので rover への中継は
    /// 常にロスレス。一方 scanFrames による統計 (msg_types / rtcm_detected /
    /// station) は best-effort — 読み取り境界で「6 バイト以上の不完全フレーム」が
    /// 末尾に来ると scanFrames が preamble を読み飛ばすため、そのフレームは統計に
    /// 数え漏れることがある (rtcm3.scanFrames:131 の既存挙動)。中継には影響しない。
    /// USB/UART の小さめ read では TCP MTU read より起きやすい。
    pub fn feed(self: *SourceFeeder, src: *Source, chunk: []const u8) void {
        if (chunk.len == 0) return;

        // Telemetry: 受信バイト数と最終受信時刻を更新（msg_lock 保護下で u64 を書き換え）
        const now_ms = std.time.milliTimestamp();
        src.msg_lock.lock();
        src.bytes_in += chunk.len;
        src.last_data_at_ms = now_ms;
        src.msg_lock.unlock();

        // リングバッファに透過転送（既存動作）
        src.ring.writeChunk(chunk);

        // parse_buf に追記（溢れ防止）
        if (self.parse_len + chunk.len <= self.parse_buf.len) {
            @memcpy(self.parse_buf[self.parse_len .. self.parse_len + chunk.len], chunk);
            self.parse_len += chunk.len;
        } else {
            // バッファ溢れ: 新データで先頭から上書き
            const copy_len = @min(chunk.len, self.parse_buf.len);
            @memcpy(self.parse_buf[0..copy_len], chunk[0..copy_len]);
            self.parse_len = copy_len;
        }

        // RTCM3 フレームスキャン
        const scan = rtcm3.scanFrames(self.parse_buf[0..self.parse_len]);

        if (scan.count > 0 and !src.rtcm_detected) {
            src.rtcm_detected = true;
        }

        for (scan.msg_types[0..scan.count]) |mt| {
            recordMsgType(src, mt);
        }

        // 1005/1006 が見つかったら基準局座標を更新（同じ source なら通常は固定値）
        if (scan.station) |sc| {
            src.msg_lock.lock();
            src.station = sc;
            src.msg_lock.unlock();
        }

        // 消費済みバイトをシフト（重なり対応のため copyForwards を使用）
        const remaining = self.parse_len - scan.consumed;
        if (remaining > 0 and scan.consumed > 0) {
            std.mem.copyForwards(u8, self.parse_buf[0..remaining], self.parse_buf[scan.consumed..self.parse_len]);
        }
        self.parse_len = remaining;
    }
};

/// RTCMデータを受信してリングバッファに書き込むループ。
/// 並行して RTCM3 フレーム解析を行い、メッセージタイプ統計を蓄積する。
fn sourceLoop(stream: io.Stream, src: *Source) void {
    var buf: [relay.RingBuffer.CHUNK_SIZE]u8 = undefined;
    var feeder = SourceFeeder{};

    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break; // 接続閉鎖
        feeder.feed(src, buf[0..n]);
    }

    // ソース切断をクライアントループに通知
    src.active.store(false, .seq_cst);
}

// ── ローカル配線 base (embedded: Mosaic USB CDC / UART) ──────────────────────

/// ローカル配線された基準局のバイト源。NTRIP SOURCE (socket) ではなく、
/// USB CDC / UART からの生 RTCM3 を Source に流し込むための抽象。
/// read_fn の戻り値: >0 = 受信バイト数、0 = まだデータ無し (継続)、
/// <0 = 恒久エラー (ループ終了)。
pub const ByteReader = struct {
    ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, buf: []u8) isize,
};

/// ローカル base を Source として登録し、reader からバイトを吸って ring に流す。
/// NTRIP SOURCE のハンドシェイク (auth/HTTP) を踏まない — 物理配線された基準局
/// は認証不要で信頼するため。embedded build で USB/UART の RTCM3 を mount として
/// rover に配信する入口。src.active=false になるまでブロックする。
pub fn runLocalSource(
    state: *server.ServerState,
    mount: []const u8,
    reader: ByteReader,
) !void {
    const src = try Source.create(state.alloc, mount, io.Address.initIp4(.{ 0, 0, 0, 0 }, 0));
    state.registerSource(src) catch |err| {
        src.destroy();
        return err;
    };
    defer {
        state.unregisterSourceIfSame(mount, src);
        // 全クライアントが clientLoop を抜けるまで待機（最大 2 秒）
        var waited: u32 = 0;
        while (src.client_count.load(.seq_cst) > 0 and waited < 200) : (waited += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        src.destroy();
    }

    var feeder = SourceFeeder{};
    var buf: [relay.RingBuffer.CHUNK_SIZE]u8 = undefined;
    while (src.active.load(.seq_cst)) {
        const n = reader.read_fn(reader.ctx, &buf);
        if (n < 0) break; // 恒久エラー
        if (n == 0) {
            // まだデータ無し（StreamBuffer timeout 等）。CPU を明け渡して継続。
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }
        feeder.feed(src, buf[0..@intCast(n)]);
    }

    src.active.store(false, .seq_cst);
}

// ── テスト ─────────────────────────────────────────────────────────────────

/// テスト用の CRC-24Q 付き有効 RTCM3 フレームを組む（payload はゼロ埋め）。
fn buildTestFrame(buf: []u8, msg_type: u16, payload_len: usize) usize {
    buf[0] = rtcm3.PREAMBLE;
    buf[1] = @truncate((payload_len >> 8) & 0x03);
    buf[2] = @truncate(payload_len & 0xFF);
    buf[3] = @truncate(msg_type >> 4);
    buf[4] = @truncate((msg_type & 0x0F) << 4);
    for (buf[5 .. 3 + payload_len]) |*b| b.* = 0;
    const crc = rtcm3.crc24q(buf[0 .. 3 + payload_len]);
    buf[3 + payload_len] = @truncate(crc >> 16);
    buf[3 + payload_len + 1] = @truncate(crc >> 8);
    buf[3 + payload_len + 2] = @truncate(crc);
    return 3 + payload_len + 3;
}

test "SourceFeeder.feed: tallies msg types and flags rtcm_detected" {
    const alloc = std.testing.allocator;
    const src = try Source.create(alloc, "/LOCAL", io.Address.initIp4(.{ 0, 0, 0, 0 }, 0));
    defer src.destroy();

    var buf: [64]u8 = undefined;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(alloc);
    const l1 = buildTestFrame(&buf, 1005, 19);
    try bytes.appendSlice(alloc, buf[0..l1]);
    const l2 = buildTestFrame(&buf, 1077, 30);
    try bytes.appendSlice(alloc, buf[0..l2]);

    var feeder = SourceFeeder{};
    feeder.feed(src, bytes.items);

    try std.testing.expect(src.rtcm_detected);
    try std.testing.expect(src.msg_types.get(1005) != null);
    try std.testing.expect(src.msg_types.get(1077) != null);
}

test "SourceFeeder.feed: resyncs past leading garbage" {
    const alloc = std.testing.allocator;
    const src = try Source.create(alloc, "/LOCAL", io.Address.initIp4(.{ 0, 0, 0, 0 }, 0));
    defer src.destroy();

    // 先頭にゴミ（非 0xD3）を置いても scanFrames は preamble まで読み飛ばす。
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(alloc);
    try bytes.appendSlice(alloc, &[_]u8{ 0x00, 0xFF, 0x12, 0x34 });
    var buf: [64]u8 = undefined;
    const len = buildTestFrame(&buf, 1077, 30);
    try bytes.appendSlice(alloc, buf[0..len]);

    var feeder = SourceFeeder{};
    feeder.feed(src, bytes.items);
    try std.testing.expect(src.msg_types.get(1077) != null);
}

const RegProbe = struct {
    state: *server.ServerState,
    saw_registered: bool = false,
    fn read(ctx: *anyopaque, buf: []u8) isize {
        _ = buf;
        const self: *RegProbe = @ptrCast(@alignCast(ctx));
        if (self.state.getSource("/LOCAL") != null) self.saw_registered = true;
        return -1; // 即終了
    }
};

test "runLocalSource: registers a local source and cleans up" {
    const parser = @import("../config/parser.zig");
    const alloc = std.testing.allocator;
    var config = try parser.parse(alloc, "");
    defer config.deinit();
    var state = server.ServerState.init(alloc, &config, ".");
    defer state.deinit();

    var probe = RegProbe{ .state = &state };
    const reader = ByteReader{ .ctx = &probe, .read_fn = RegProbe.read };
    try runLocalSource(&state, "/LOCAL", reader);

    try std.testing.expect(probe.saw_registered);
    // runLocalSource の defer で unregister 済みのはず。
    try std.testing.expect(state.getSource("/LOCAL") == null);
}
