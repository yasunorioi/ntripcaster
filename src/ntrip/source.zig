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

/// ソース接続のエントリポイント。
///
/// 処理フロー:
///   1. encoder_password 検証
///   2. Source-Agent が NTRIP 準拠か検証（§2f BKG差異）
///   3. マウント二重登録チェック
///   4. "OK\r\n" 送信
///   5. RTCMデータ受信ループ → RingBuffer に writeChunk
///   6. 切断時にマウント解放、active=false でクライアントを通知
pub fn handleSource(
    stream: std.net.Stream,
    state: *server.ServerState,
    login: protocol.SourceLogin,
) void {
    // 1. パスワード検証
    if (!auth.authenticateSource(state.config, login.password)) {
        stream.writeAll("ERROR - Bad Password\r\n") catch {};
        state.logger.warn("source rejected: bad password for mount {s}", .{login.mount});
        return;
    }

    // 2. NTRIP エージェント検証（Source-Agent ヘッダー必須ではないが推奨）
    if (login.agent) |agent| {
        if (!protocol.isNtripAgent(agent)) {
            stream.writeAll("ERROR - Not NTRIP\r\n") catch {};
            state.logger.warn("source rejected: non-NTRIP agent '{s}'", .{agent});
            return;
        }
    }

    // 3. ソース数上限チェック
    if (state.sourceCount() >= state.config.max_sources) {
        stream.writeAll("ERROR - Too Many Sources\r\n") catch {};
        state.logger.warn("source rejected: max_sources ({d}) reached", .{state.config.max_sources});
        return;
    }

    // 4. Source オブジェクト作成
    const src = server.Source.create(state.alloc, login.mount) catch |err| {
        stream.writeAll("ERROR - Internal Error\r\n") catch {};
        state.logger.err("Source.create failed: {}", .{err});
        return;
    };

    // 5. マウント登録
    state.registerSource(src) catch {
        src.destroy();
        stream.writeAll("ERROR - Mount already in use\r\n") catch {};
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

    // 5. 成功応答
    stream.writeAll("OK\r\n") catch return;
    state.logger.info("source connected: mount={s}", .{login.mount});

    // 6. RTCMデータ受信ループ
    sourceLoop(stream, src);

    state.logger.info("source disconnected: mount={s}", .{login.mount});
}

/// メッセージタイプを Source に記録する（スレッドセーフ）。
fn recordMsgType(src: *server.Source, msg_type: u16) void {
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
fn sourceLoop(stream: std.net.Stream, src: *server.Source) void {
    var buf: [relay.RingBuffer.CHUNK_SIZE]u8 = undefined;
    // RTCM3 フレーム解析用バッファ（チャンク跨ぎ対応：最大 2 チャンク分）
    var parse_buf: [relay.RingBuffer.CHUNK_SIZE * 2]u8 = undefined;
    var parse_len: usize = 0;

    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break; // 接続閉鎖

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
