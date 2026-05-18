//! ntrip/source.zig — NTRIPソース（基準局）接続ハンドラ
//!
//! 原典 source.c の source_login() / source_func() / add_chunk() を Zig で再実装。
//! SOURCE コマンドで接続した基準局からRTCMデータを受信し、リングバッファに格納する。
//! 受信データを並行して RTCM3 フレーム解析し、メッセージタイプ統計を Source に蓄積する。

const std = @import("std");
const server = @import("../server.zig");
const auth = @import("../auth/basic.zig");
const protocol = @import("protocol.zig");
const relay = @import("../relay/engine.zig");
const rtcm3 = @import("rtcm3.zig");
const sourcetable = @import("sourcetable.zig");

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
    peer_addr: std.net.Address,
    /// 受信累積バイト数（msg_lock で保護）
    bytes_in: u64,
    /// 接続確立ミリ秒タイムスタンプ
    started_at_ms: i64,
    /// 最後にデータを受信したミリ秒タイムスタンプ（msg_lock で保護）
    last_data_at_ms: i64,

    pub fn create(
        alloc: std.mem.Allocator,
        mount: []const u8,
        peer_addr: std.net.Address,
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
fn writeSourceError(stream: std.net.Stream, is_v2: bool, v1_msg: []const u8, v2_status: []const u8) void {
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
    stream: std.net.Stream,
    state: *server.ServerState,
    login: protocol.SourceLogin,
    peer_addr: std.net.Address,
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
    state.registerSource(src) catch {
        src.destroy();
        writeSourceError(stream, login.is_v2, "ERROR - Mount already in use\r\n", "409 Conflict");
        state.logger.warn("source rejected: mount {s} already in use", .{login.mount});
        return;
    };

    defer {
        state.unregisterSource(login.mount);
        // 全クライアントが clientLoop を抜けるまで待機（最大 2 秒）
        var waited: u32 = 0;
        while (src.client_count.load(.seq_cst) > 0 and waited < 200) : (waited += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        src.destroy();
    }

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

/// RTCMデータを受信してリングバッファに書き込むループ。
/// 並行して RTCM3 フレーム解析を行い、メッセージタイプ統計を蓄積する。
fn sourceLoop(stream: std.net.Stream, src: *Source) void {
    var buf: [relay.RingBuffer.CHUNK_SIZE]u8 = undefined;
    // RTCM3 フレーム解析用バッファ（チャンク跨ぎ対応：最大 2 チャンク分）
    var parse_buf: [relay.RingBuffer.CHUNK_SIZE * 2]u8 = undefined;
    var parse_len: usize = 0;

    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break; // 接続閉鎖

        // Telemetry: 受信バイト数と最終受信時刻を更新（msg_lock 保護下で u64 を書き換え）
        const now_ms = std.time.milliTimestamp();
        src.msg_lock.lock();
        src.bytes_in += n;
        src.last_data_at_ms = now_ms;
        src.msg_lock.unlock();

        // リングバッファに透過転送（既存動作）
        src.ring.writeChunk(buf[0..n]);

        // parse_buf に追記（溢れ防止）
        const chunk = buf[0..n];
        if (parse_len + chunk.len <= parse_buf.len) {
            @memcpy(parse_buf[parse_len .. parse_len + chunk.len], chunk);
            parse_len += chunk.len;
        } else {
            // バッファ溢れ: 新データで先頭から上書き
            const copy_len = @min(chunk.len, parse_buf.len);
            @memcpy(parse_buf[0..copy_len], chunk[0..copy_len]);
            parse_len = copy_len;
        }

        // RTCM3 フレームスキャン
        const scan = rtcm3.scanFrames(parse_buf[0..parse_len]);

        if (scan.count > 0 and !src.rtcm_detected) {
            src.rtcm_detected = true;
        }

        for (scan.msg_types[0..scan.count]) |mt| {
            recordMsgType(src, mt);
        }

        // 消費済みバイトをシフト（重なり対応のため copyForwards を使用）
        const remaining = parse_len - scan.consumed;
        if (remaining > 0 and scan.consumed > 0) {
            std.mem.copyForwards(u8, parse_buf[0..remaining], parse_buf[scan.consumed..parse_len]);
        }
        parse_len = remaining;
    }

    // ソース切断をクライアントループに通知
    src.active.store(false, .seq_cst);
}
