//! ntrip/client.zig — NTRIPクライアント接続ハンドラ + Client 構造体
//!
//! 原典 client.c の client_login() / greet_client() / source_write_to_client() を
//! Zig で再実装。
//!
//! クライアントは "ICY 200 OK" の後、ソースのリングバッファからRTCMデータを受信する。
//! ソース切断またはバッファオーバーランで接続を切断する。
//!
//! Client 構造体は接続中クライアントを ServerState から追跡するためのレコード。
//! Phase C 時点では id と mount のみ。Phase A で telemetry (peer / bytes / 時刻) を追加。

const std = @import("std");
const server = @import("../server.zig");
const auth = @import("../auth/basic.zig");
const protocol = @import("protocol.zig");
const relay = @import("../relay/engine.zig");

/// 接続中の NTRIP クライアント (rover) を表す。
pub const Client = struct {
    id: u64,
    /// 購読中のマウント名（heap 上、Client が所有）
    mount: []const u8,
    alloc: std.mem.Allocator,

    // ── Telemetry ───────────────────────────────────────────────────────
    /// 接続元アドレス（accept() 時点）
    peer_addr: std.net.Address,
    /// 送信累積バイト数（stat_lock で保護。32-bit 環境で 64-bit atomic が無いため Mutex 使用）
    bytes_out: u64,
    /// stat_lock: bytes_out を保護する
    stat_lock: std.Thread.Mutex,
    /// 接続確立ミリ秒タイムスタンプ
    started_at_ms: i64,

    pub fn create(
        alloc: std.mem.Allocator,
        id: u64,
        mount: []const u8,
        peer_addr: std.net.Address,
    ) !*Client {
        const c = try alloc.create(Client);
        errdefer alloc.destroy(c);
        c.* = .{
            .id = id,
            .mount = try alloc.dupe(u8, mount),
            .alloc = alloc,
            .peer_addr = peer_addr,
            .bytes_out = 0,
            .stat_lock = .{},
            .started_at_ms = std.time.milliTimestamp(),
        };
        return c;
    }

    pub fn destroy(self: *Client) void {
        self.alloc.free(self.mount);
        self.alloc.destroy(self);
    }
};

/// クライアント接続のエントリポイント。
///
/// 処理フロー:
///   1. Basic認証 or オープンマウント判定
///   2. マウント探索（ソースが存在しない場合は 404）
///   3. "ICY 200 OK\r\n\r\n" 送信
///   4. Client 登録 → RingBuffer からデータを読み取り → クライアントに送信
///   5. ソース切断 / バッファオーバーラン / 送信エラーで接続終了
pub fn handleClient(
    stream: std.net.Stream,
    state: *server.ServerState,
    get: protocol.ClientGet,
    peer_addr: std.net.Address,
) void {
    // 0. VRS mountpoint なら専用ハンドラに丸投げ (双方向 TCP + GGA 受信が必要)
    if (state.vrs) |vh| {
        if (vh.matches_fn(vh.ctx, get.mount)) {
            vh.handle_fn(vh.ctx, stream, peer_addr);
            return;
        }
    }

    // 1. ソース探索（アクティブなソースがなければ 404）
    const src = state.getSource(get.mount) orelse {
        stream.writeAll("HTTP/1.0 404 Not Found\r\n\r\n") catch {};
        state.logger.warn("client rejected: mount {s} not found", .{get.mount});
        return;
    };

    // 2. 認証判定
    var auth_ok = false;

    // Authorization ヘッダーがある場合: Basic デコード → パスワード照合
    if (get.auth_header) |ah| {
        var cred_buf: [512]u8 = undefined;
        if (auth.extractCredentials(ah, &cred_buf)) |cred| {
            auth_ok = auth.authenticateClient(state.config, get.mount, cred.user, cred.pass);
        } else |_| {}
    }

    // Authorization がない場合もオープンマウントは許可
    if (!auth_ok) {
        auth_ok = auth.authenticateClient(state.config, get.mount, "", "");
    }

    if (!auth_ok) {
        stream.writeAll(
            "HTTP/1.0 401 Unauthorized\r\n" ++
                "WWW-Authenticate: Basic realm=\"NtripCaster\"\r\n" ++
                "\r\n",
        ) catch {};
        state.logger.warn("client rejected: unauthorized for mount {s}", .{get.mount});
        return;
    }

    // 3. ソースあたりクライアント数上限チェック
    if (src.client_count.load(.seq_cst) >= state.config.max_clients_per_source) {
        stream.writeAll("HTTP/1.0 503 Service Unavailable\r\n\r\n") catch {};
        state.logger.warn("client rejected: max_clients_per_source ({d}) reached for mount {s}", .{ state.config.max_clients_per_source, get.mount });
        return;
    }

    // 4. ICY 200 OK 応答
    stream.writeAll("ICY 200 OK\r\n\r\n") catch return;

    // 5. Client 登録
    const id = state.nextClientId();
    const client = Client.create(state.alloc, id, get.mount, peer_addr) catch |err| {
        state.logger.err("Client.create failed: {}", .{err});
        return;
    };
    state.registerClient(client) catch |err| {
        state.logger.err("registerClient failed: {}", .{err});
        client.destroy();
        return;
    };
    defer {
        state.unregisterClient(id);
        client.destroy();
    }

    state.logger.info("client connected: id={d} mount={s}", .{ id, get.mount });

    // 6. データ配信ループ
    clientLoop(stream, src, client);

    state.logger.info("client disconnected: id={d} mount={s}", .{ id, get.mount });
}

/// リングバッファからデータを読み取ってクライアントに送信するループ。
/// ソース切断 / バッファオーバーラン / 送信エラーで終了する。
fn clientLoop(stream: std.net.Stream, src: *server.Source, client: *Client) void {
    _ = src.client_count.fetchAdd(1, .seq_cst);
    defer _ = src.client_count.fetchSub(1, .seq_cst);

    var read_pos = src.ring.currentWritePos();
    var buf: [relay.RingBuffer.CHUNK_SIZE]u8 = undefined;

    while (src.active.load(.seq_cst)) {
        const result = src.ring.readChunk(read_pos, &buf) catch {
            // BufferOverrun: クライアントが遅延しすぎ
            break;
        };

        if (result) |r| {
            stream.writeAll(buf[0..r.len]) catch break;
            client.stat_lock.lock();
            client.bytes_out += r.len;
            client.stat_lock.unlock();
            read_pos = r.next_pos;
        } else {
            // データ待ち: CPU を占有しないよう短時間スリープ
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
}
