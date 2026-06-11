//! admin/server.zig — 観測 UI / JSON API を提供する HTTP サーバー。
//!
//! NTRIP リスナーとは別ポート (既定: 127.0.0.1:8080) で動作する。
//! Basic 認証 (config: admin_user / admin_password) を行う。
//! 認証情報が空の場合は認証無効（bind を 127.0.0.1 限定する前提）。
//!
//! Phase A スコープ:
//!   - GET /              → "ok"（プレースホルダ。Phase B で UI HTML に置換）
//!   - GET /api/v1/status → JSON
//!   - GET /api/v1/sources → JSON
//!   - GET /api/v1/clients → JSON
//!
//! 設計:
//!   - 1 接続 1 スレッド（NTRIP 側と同様）
//!   - HTTP/1.0 風の最小実装。Connection: close で毎回切断
//!   - Phase B で /api/v1/events (SSE) と / (UI) を追加

const std = @import("std");
const server_mod = @import("../server.zig");
const stats = @import("stats.zig");

pub const VERSION = "0.2.1";

const INDEX_HTML = @embedFile("index.html");

/// admin 状態。listen() に共有メモリとして渡す。
pub const AdminState = struct {
    state: *server_mod.ServerState,
    /// "127.0.0.1" など
    bind: []const u8,
    port: u16,
    /// 空文字列なら認証無効
    user: []const u8,
    password: []const u8,
    /// サーバープロセスの起動時刻（uptime 計算用）
    server_started_at_ms: i64,

    /// listen() がポートを bind した瞬間に set される
    started_event: std.Thread.ResetEvent = .{},
    /// 実際にバインドされたアドレス
    listen_address: std.net.Address = undefined,
    /// active なリスナー（shutdown() で deinit + free）
    listener: ?*std.net.Server = null,
    /// shutdown() 時のリスナー free に使う
    alloc: std.mem.Allocator,

    pub fn shutdown(self: *AdminState) void {
        if (self.listener) |l| {
            std.posix.shutdown(l.stream.handle, .both) catch {};
            l.deinit();
            self.alloc.destroy(l);
            self.listener = null;
        }
    }
};

/// admin リスナーのメインループ。state.shutdown() を呼ぶと終了する。
pub fn listen(admin: *AdminState) !void {
    const listener_ptr = try admin.alloc.create(std.net.Server);
    errdefer admin.alloc.destroy(listener_ptr);

    const addr = try std.net.Address.parseIp(admin.bind, admin.port);
    listener_ptr.* = try addr.listen(.{ .reuse_address = true });
    admin.listen_address = listener_ptr.listen_address;
    admin.listener = listener_ptr;
    admin.started_event.set();

    admin.state.logger.info(
        "admin listening on {s}:{d} (auth={s})",
        .{ admin.bind, admin.port, if (admin.user.len > 0) "basic" else "none" },
    );

    while (true) {
        const conn = listener_ptr.accept() catch |err| {
            admin.state.logger.info("admin accept stopped: {}", .{err});
            break;
        };

        const args = ConnArgs{ .stream = conn.stream, .admin = admin };
        const t = std.Thread.spawn(.{}, handleConnection, .{args}) catch |err| {
            admin.state.logger.warn("admin Thread.spawn failed: {}", .{err});
            conn.stream.close();
            continue;
        };
        t.detach();
    }
}

const ConnArgs = struct {
    stream: std.net.Stream,
    admin: *AdminState,
};

fn handleConnection(args: ConnArgs) void {
    defer args.stream.close();
    handleRequest(args.stream, args.admin) catch |err| {
        args.admin.state.logger.warn("admin request error: {}", .{err});
    };
}

fn handleRequest(stream: std.net.Stream, admin: *AdminState) !void {
    var header_buf: [4096]u8 = undefined;
    const header_len = readHeader(stream, &header_buf) catch {
        try sendStatus(stream, 400, "Bad Request", "text/plain", "bad request\n");
        return;
    };
    const header = header_buf[0..header_len];

    const req = parseRequestLine(header) orelse {
        try sendStatus(stream, 400, "Bad Request", "text/plain", "bad request\n");
        return;
    };

    if (!std.mem.eql(u8, req.method, "GET")) {
        try sendStatus(stream, 405, "Method Not Allowed", "text/plain", "GET only\n");
        return;
    }

    // Basic auth
    if (admin.user.len > 0) {
        if (!checkBasicAuth(header, admin.user, admin.password)) {
            try sendUnauthorized(stream);
            return;
        }
    }

    if (std.mem.eql(u8, req.path, "/")) {
        try sendStatus(stream, 200, "OK", "text/html; charset=utf-8", INDEX_HTML);
        return;
    }
    if (std.mem.eql(u8, req.path, "/api/v1/status")) {
        try sendJsonBody(stream, admin, &writeStatusAdapter);
        return;
    }
    if (std.mem.eql(u8, req.path, "/api/v1/sources")) {
        try sendJsonBody(stream, admin, &writeSourcesAdapter);
        return;
    }
    if (std.mem.eql(u8, req.path, "/api/v1/clients")) {
        try sendJsonBody(stream, admin, &writeClientsAdapter);
        return;
    }
    if (std.mem.eql(u8, req.path, "/api/v1/events")) {
        try handleSse(stream, admin);
        return;
    }
    try sendStatus(stream, 404, "Not Found", "text/plain", "not found\n");
}

/// SSE: 1 秒間隔で composite snapshot を data: イベントで配信。
/// 書き込み失敗（クライアント切断）でループを抜ける。
fn handleSse(stream: std.net.Stream, admin: *AdminState) !void {
    const headers =
        "HTTP/1.0 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "Connection: close\r\n" ++
        "X-Accel-Buffering: no\r\n\r\n";
    stream.writeAll(headers) catch return;

    // 接続直後に retry ヒントを送る
    stream.writeAll("retry: 3000\n\n") catch return;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(admin.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var body = std.ArrayList(u8).empty;
        body.appendSlice(a, "data: ") catch return;
        stats.writeSnapshotJson(&body, a, admin.state, VERSION, admin.server_started_at_ms) catch |err| {
            admin.state.logger.warn("SSE serialize error: {}", .{err});
            return;
        };
        body.appendSlice(a, "\n\n") catch return;

        stream.writeAll(body.items) catch break;
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

const RequestLine = struct {
    method: []const u8,
    path: []const u8,
};

fn parseRequestLine(header: []const u8) ?RequestLine {
    const eol = std.mem.indexOfAny(u8, header, "\r\n") orelse return null;
    const line = header[0..eol];
    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return null;
    const path = it.next() orelse return null;
    return .{ .method = method, .path = path };
}

fn readHeader(stream: std.net.Stream, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
        if (std.mem.indexOf(u8, buf[0..total], "\n\n") != null) break;
    }
    return total;
}

/// Authorization: Basic <base64(user:pass)> をチェックする。
fn checkBasicAuth(header: []const u8, user: []const u8, password: []const u8) bool {
    // 行ごとに走査して "Authorization:" を探す（大文字小文字無視）
    var lines = std.mem.tokenizeAny(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "authorization")) continue;

        const prefix = "Basic ";
        if (value.len <= prefix.len) return false;
        if (!std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return false;
        const b64 = value[prefix.len..];

        var decoded: [256]u8 = undefined;
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(b64) catch return false;
        if (decoded_len > decoded.len) return false;
        decoder.decode(decoded[0..decoded_len], b64) catch return false;
        const cred = decoded[0..decoded_len];

        const sep = std.mem.indexOfScalar(u8, cred, ':') orelse return false;
        const u = cred[0..sep];
        const p = cred[sep + 1 ..];
        return std.mem.eql(u8, u, user) and std.mem.eql(u8, p, password);
    }
    return false;
}

fn sendUnauthorized(stream: std.net.Stream) !void {
    const body = "unauthorized\n";
    var buf: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.0 401 Unauthorized\r\n" ++
            "WWW-Authenticate: Basic realm=\"NtripCaster Admin\"\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{body.len},
    );
    try stream.writeAll(head);
    try stream.writeAll(body);
}

fn sendStatus(
    stream: std.net.Stream,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var buf: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.0 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ status, reason, content_type, body.len },
    );
    try stream.writeAll(head);
    try stream.writeAll(body);
}

const JsonWriter = fn (
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    admin: *AdminState,
) anyerror!void;

fn writeStatusAdapter(out: *std.ArrayList(u8), alloc: std.mem.Allocator, admin: *AdminState) anyerror!void {
    return stats.writeStatusJson(out, alloc, admin.state, VERSION, admin.server_started_at_ms);
}

fn writeSourcesAdapter(out: *std.ArrayList(u8), alloc: std.mem.Allocator, admin: *AdminState) anyerror!void {
    return stats.writeSourcesJson(out, alloc, admin.state);
}

fn writeClientsAdapter(out: *std.ArrayList(u8), alloc: std.mem.Allocator, admin: *AdminState) anyerror!void {
    return stats.writeClientsJson(out, alloc, admin.state);
}

fn sendJsonBody(stream: std.net.Stream, admin: *AdminState, writer: *const JsonWriter) !void {
    var arena = std.heap.ArenaAllocator.init(admin.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    var body = std.ArrayList(u8).empty;
    writer(&body, alloc, admin) catch |err| {
        try sendStatus(stream, 500, "Internal Server Error", "text/plain", "stats error\n");
        admin.state.logger.warn("stats writer error: {}", .{err});
        return;
    };

    var head_buf: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.0 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Connection: close\r\n\r\n",
        .{body.items.len},
    );
    try stream.writeAll(head);
    try stream.writeAll(body.items);
}
