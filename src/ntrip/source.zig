//! ntrip/source.zig — NTRIPソース（基準局）接続ハンドラ
//!
//! 原典 source.c の source_login() / source_func() / add_chunk() を Zig で再実装。
//! SOURCE コマンドで接続した基準局からRTCMデータを受信し、リングバッファに格納する。

const std = @import("std");
const server = @import("../server.zig");
const auth = @import("../auth/basic.zig");
const protocol = @import("protocol.zig");
const relay = @import("../relay/engine.zig");

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

    // 3. Source オブジェクト作成
    const src = server.Source.create(state.alloc, login.mount) catch |err| {
        stream.writeAll("ERROR - Internal Error\r\n") catch {};
        state.logger.err("Source.create failed: {}", .{err});
        return;
    };

    // 4. マウント登録
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
            std.time.sleep(10 * std.time.ns_per_ms);
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

/// RTCMデータを受信してリングバッファに書き込むループ。
fn sourceLoop(stream: std.net.Stream, src: *server.Source) void {
    var buf: [relay.RingBuffer.CHUNK_SIZE]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break; // 接続閉鎖
        src.ring.writeChunk(buf[0..n]);
    }
    // ソース切断をクライアントループに通知
    src.active.store(false, .seq_cst);
}
