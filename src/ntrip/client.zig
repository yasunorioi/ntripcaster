//! ntrip/client.zig — NTRIPクライアント接続ハンドラ + Client 構造体
//!
//! 原典 client.c の client_login() / greet_client() / source_write_to_client() を
//! Zig で再実装。
//!
//! V1 クライアント: "ICY 200 OK" 応答後、リングバッファから RTCM を生バイト送信。
//! V2 クライアント: "HTTP/1.1 200 OK" + Transfer-Encoding: chunked 応答後、
//! RTCM フレームを chunked encoding で送信。
//!
//! ソース切断またはバッファオーバーランで接続を切断する。
//!
//! Client 構造体は接続中クライアントを ServerState から追跡するためのレコード。

const std = @import("std");
const io = @import("../io.zig");
const os = @import("../os.zig");
const server = @import("../server.zig");
const auth = @import("../auth/basic.zig");
const protocol = @import("protocol.zig");
const relay = @import("../relay/engine.zig");
const sockopt = @import("../net/sockopt.zig");
const sourcetable = @import("sourcetable.zig");

/// 接続中の NTRIP クライアント (rover) を表す。
pub const Client = struct {
    id: u64,
    /// 購読中のマウント名（heap 上、Client が所有）
    mount: []const u8,
    alloc: std.mem.Allocator,

    // ── Telemetry ───────────────────────────────────────────────────────
    /// 接続元アドレス（accept() 時点）
    peer_addr: io.Address,
    /// 送信累積バイト数（stat_lock で保護。32-bit 環境で 64-bit atomic が無いため Mutex 使用）
    bytes_out: u64,
    /// stat_lock: bytes_out を保護する
    stat_lock: os.Mutex,
    /// 接続確立ミリ秒タイムスタンプ
    started_at_ms: i64,

    pub fn create(
        alloc: std.mem.Allocator,
        id: u64,
        mount: []const u8,
        peer_addr: io.Address,
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
            .started_at_ms = os.milliTimestamp(),
        };
        return c;
    }

    pub fn destroy(self: *Client) void {
        self.alloc.free(self.mount);
        self.alloc.destroy(self);
    }
};

/// HTTP エラー応答を V1 / V2 で出し分ける。
/// V1: HTTP/1.0、V2: HTTP/1.1 + Server ヘッダー。
fn writeErrorResponse(stream: io.Stream, is_v2: bool, status_line: []const u8, extra_headers: []const u8) void {
    const http_ver = if (is_v2) "HTTP/1.1 " else "HTTP/1.0 ";
    const iov: [5][]const u8 = .{
        http_ver,
        status_line,
        "\r\n",
        extra_headers,
        "\r\n",
    };
    for (iov) |s| {
        stream.writeAll(s) catch return;
    }
}

/// V2 クライアントへのストリーム開始ヘッダー（HTTP/1.1 200 OK + chunked）。
fn writeV2StreamHeaders(stream: io.Stream) !void {
    var buf: [256]u8 = undefined;
    const headers = try std.fmt.bufPrint(&buf,
        "HTTP/1.1 200 OK\r\n" ++
        "Server: NTRIP NtripCaster/{s}\r\n" ++
        "Ntrip-Version: Ntrip/2.0\r\n" ++
        "Cache-Control: no-store, no-cache, max-age=0\r\n" ++
        "Pragma: no-cache\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: gnss/data\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n",
        .{sourcetable.CASTER_VERSION},
    );
    try stream.writeAll(headers);
}

/// HTTP/1.1 chunked encoding でデータを 1 チャンク送信する。
/// 形式: "<hex-size>\r\n<data>\r\n"
fn writeChunked(stream: io.Stream, data: []const u8) !void {
    if (data.len == 0) return;
    var size_buf: [24]u8 = undefined;
    const size_line = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
    try stream.writeAll(size_line);
    try stream.writeAll(data);
    try stream.writeAll("\r\n");
}

/// クライアント接続のエントリポイント。
///
/// 処理フロー:
///   1. Basic認証 or オープンマウント判定
///   2. マウント探索（ソースが存在しない場合は 404）
///   3. V1: "ICY 200 OK"  /  V2: "HTTP/1.1 200 OK" + chunked ヘッダー
///   4. Client 登録 → RingBuffer からデータを読み取り → クライアントに送信
///   5. ソース切断 / バッファオーバーラン / 送信エラーで接続終了
pub fn handleClient(
    stream: io.Stream,
    state: *server.ServerState,
    get: protocol.ClientGet,
    peer_addr: io.Address,
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
        writeErrorResponse(stream, get.is_v2, "404 Not Found", "");
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
        writeErrorResponse(stream, get.is_v2, "401 Unauthorized", "WWW-Authenticate: Basic realm=\"NtripCaster\"\r\n");
        state.logger.warn("client rejected: unauthorized for mount {s}", .{get.mount});
        return;
    }

    // 3. ソースあたりクライアント数上限チェック
    if (src.client_count.load(.seq_cst) >= state.config.max_clients_per_source) {
        writeErrorResponse(stream, get.is_v2, "503 Service Unavailable", "");
        state.logger.warn("client rejected: max_clients_per_source ({d}) reached for mount {s}", .{ state.config.max_clients_per_source, get.mount });
        return;
    }

    // 4. 成功応答（V1 は ICY、V2 は HTTP/1.1 + chunked ヘッダー）
    if (get.is_v2) {
        writeV2StreamHeaders(stream) catch return;
    } else {
        stream.writeAll("ICY 200 OK\r\n\r\n") catch return;
    }

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

    state.logger.info("client connected: id={d} mount={s} v2={}", .{ id, get.mount, get.is_v2 });

    // 6. データ配信ループ
    // LTE/Starlink rover 向けの socket 設定 (詰まり打ち切り + half-open 検出)
    sockopt.configureStreamingSocket(stream);
    clientLoop(stream, src, client, get.is_v2, state);

    // V2 は終端 chunk "0\r\n\r\n" を送って streamed body を閉じる（best-effort）
    if (get.is_v2) {
        stream.writeAll("0\r\n\r\n") catch {};
    }

    state.logger.info("client disconnected: id={d} mount={s}", .{ id, get.mount });
}

/// リングバッファからデータを読み取ってクライアントに送信するループ。
/// ソース切断 / バッファオーバーラン / 送信エラーで終了する。
fn clientLoop(stream: io.Stream, src: *server.Source, client: *Client, is_v2: bool, state: *server.ServerState) void {
    _ = src.client_count.fetchAdd(1, .seq_cst);
    defer _ = src.client_count.fetchSub(1, .seq_cst);

    var read_pos = src.ring.currentWritePos();
    var buf: [relay.RingBuffer.CHUNK_SIZE]u8 = undefined;

    // src.active が最初から false の場合の検出用 (clientLoop が一度も
    // 走らずに帰ってる病理症状を切り分ける)。
    if (!src.active.load(.seq_cst)) {
        state.logger.warn(
            "client {d} (mount {s}) disconnected: src.active was false on entry",
            .{ client.id, client.mount },
        );
        return;
    }

    while (src.active.load(.seq_cst)) {
        const result = src.ring.readChunk(read_pos, &buf) catch {
            // BufferOverrun: クライアントが ring buffer 追従に失敗。
            // 「黙って切断」を避けて log + 集計に残す (admin で観測可能に)。
            const n = src.overrun_disconnects.fetchAdd(1, .seq_cst) + 1;
            state.logger.warn(
                "client {d} (mount {s}) disconnected: BufferOverrun (source overruns total={d})",
                .{ client.id, client.mount, n },
            );
            break;
        };

        if (result) |r| {
            if (is_v2) {
                writeChunked(stream, buf[0..r.len]) catch |err| {
                    state.logger.warn(
                        "client {d} (mount {s}) disconnected: writeChunked failed: {}",
                        .{ client.id, client.mount, err },
                    );
                    break;
                };
            } else {
                stream.writeAll(buf[0..r.len]) catch |err| {
                    state.logger.warn(
                        "client {d} (mount {s}) disconnected: writeAll failed: {}",
                        .{ client.id, client.mount, err },
                    );
                    break;
                };
            }
            client.stat_lock.lock();
            client.bytes_out += r.len;
            client.stat_lock.unlock();
            read_pos = r.next_pos;
        } else {
            // データ待ち: CPU を占有しないよう短時間スリープ
            os.sleep(10 * std.time.ns_per_ms);
        }
    }

    // 通常終了 (src.active=false で while を抜けた) ケースも識別できるよう
    // 終了理由を info で残す。
    if (!src.active.load(.seq_cst)) {
        state.logger.info(
            "client {d} (mount {s}) loop exit: src.active=false (source closing)",
            .{ client.id, client.mount },
        );
    }
}
