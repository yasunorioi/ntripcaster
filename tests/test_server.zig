//! tests/test_server.zig — server.zig / source.zig / client.zig の統合テスト
//!
//! テスト内容:
//!   - GET / → SOURCETABLE 200 OK
//!   - 不正リクエスト → 400 Bad Request
//!   - SOURCE 不正パスワード → ERROR
//!   - SOURCE 正常接続 → OK
//!   - CLIENT マウント不存在 → 404
//!   - CLIENT 認証失敗 → 401
//!   - SOURCE + CLIENT → RTCMリレー
//!   - オープンマウント → 認証なしで接続可能

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const parser = ntripcaster.config;
const server_mod = ntripcaster.server_mod;

// ── テストヘルパー ────────────────────────────────────────────────────────────

fn makeTestConfig(alloc: std.mem.Allocator) !parser.Config {
    const content =
        \\encoder_password testpass
        \\/RELAY:user1:pass1
        \\/OPEN
    ;
    return parser.parse(alloc, content);
}

/// サーバーを起動し、listen() の準備完了まで待ってスレッドを返す。
fn startServer(state: *server_mod.ServerState) !std.Thread {
    const t = try std.Thread.spawn(.{}, server_mod.listen, .{state});
    try state.started_event.timedWait(2 * std.time.ns_per_s);
    return t;
}

/// バインドされた実際のポート番号を返す（started_event 後に呼ぶこと）。
fn boundPort(state: *const server_mod.ServerState) u16 {
    return state.listen_address.in.getPort();
}

/// 接続して request を送り、レスポンスの先頭を resp_buf に読む。
fn reqResp(port: u16, request: []const u8, resp_buf: []u8) !usize {
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var conn = try std.net.tcpConnectToAddress(addr);
    defer conn.close();
    try conn.writeAll(request);
    std.time.sleep(60 * std.time.ns_per_ms);
    return conn.read(resp_buf);
}

// ── sourcetable ───────────────────────────────────────────────────────────────

test "GET / returns SOURCETABLE 200 OK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    var buf: [512]u8 = undefined;
    const n = try reqResp(
        boundPort(&state),
        "GET / HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "SOURCETABLE 200 OK"));
}

// ── 不正リクエスト ─────────────────────────────────────────────────────────────

test "invalid request returns 400" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    var buf: [128]u8 = undefined;
    const n = try reqResp(
        boundPort(&state),
        "GARBAGE\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 400"));
}

// ── SOURCE 不正パスワード ──────────────────────────────────────────────────────

test "SOURCE wrong password returns ERROR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    var buf: [64]u8 = undefined;
    const n = try reqResp(
        boundPort(&state),
        "SOURCE wrongpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "ERROR"));
}

// ── SOURCE 正常接続 ────────────────────────────────────────────────────────────

test "SOURCE correct password returns OK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    const port = boundPort(&state);
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var src = try std.net.tcpConnectToAddress(addr);
    defer src.close();

    try src.writeAll("SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");

    var buf: [16]u8 = undefined;
    const n = try src.read(&buf);
    try std.testing.expectEqualStrings("OK\r\n", buf[0..n]);
}

// ── CLIENT マウント不存在 ──────────────────────────────────────────────────────

test "client unknown mount returns 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    var buf: [128]u8 = undefined;
    const n = try reqResp(
        boundPort(&state),
        "GET /NOMOUNT HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 404"));
}

// ── CLIENT 認証失敗 ────────────────────────────────────────────────────────────

test "client wrong credentials returns 401" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    const port = boundPort(&state);
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    // ソース接続
    var src = try std.net.tcpConnectToAddress(addr);
    defer src.close();
    try src.writeAll("SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok: [8]u8 = undefined;
    _ = try src.read(&ok); // "OK\r\n"

    // 不正クレデンシャル "bad:wrong" = YmFkOndyb25n
    var buf: [128]u8 = undefined;
    const n = try reqResp(
        port,
        "GET /RELAY HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\nAuthorization: Basic YmFkOndyb25n\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 401"));
}

// ── SOURCE → CLIENT RTCMリレー ────────────────────────────────────────────────

test "source to client RTCM relay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    const port = boundPort(&state);
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    // ── ソース接続 ────────────────────────────────────────────────────────────
    var src = try std.net.tcpConnectToAddress(addr);
    defer src.close();
    try src.writeAll("SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok: [8]u8 = undefined;
    const ok_n = try src.read(&ok);
    try std.testing.expectEqualStrings("OK\r\n", ok[0..ok_n]);

    // ── クライアント接続（user1:pass1 = dXNlcjE6cGFzczE=） ──────────────────
    var cli = try std.net.tcpConnectToAddress(addr);
    defer cli.close();
    try cli.writeAll(
        "GET /RELAY HTTP/1.0\r\n" ++
            "User-Agent: NTRIP test/1.0\r\n" ++
            "Authorization: Basic dXNlcjE6cGFzczE=\r\n" ++
            "\r\n",
    );
    var icy: [32]u8 = undefined;
    const icy_n = try cli.read(&icy);
    try std.testing.expect(std.mem.startsWith(u8, icy[0..icy_n], "ICY 200 OK"));

    // ── RTCMデータ送信 → 受信確認 ─────────────────────────────────────────────
    const rtcm: []const u8 = &.{ 0xD3, 0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD };
    try src.writeAll(rtcm);
    std.time.sleep(80 * std.time.ns_per_ms);

    var data: [64]u8 = undefined;
    const data_n = try cli.read(&data);
    try std.testing.expectEqualSlices(u8, rtcm, data[0..data_n]);
}

// ── オープンマウント ──────────────────────────────────────────────────────────

test "open mount allows unauthenticated client" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    const port = boundPort(&state);
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    // ソース接続
    var src = try std.net.tcpConnectToAddress(addr);
    defer src.close();
    try src.writeAll("SOURCE testpass /OPEN\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok: [8]u8 = undefined;
    _ = try src.read(&ok);

    // 認証なしクライアント
    var cli = try std.net.tcpConnectToAddress(addr);
    defer cli.close();
    try cli.writeAll("GET /OPEN HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n");
    std.time.sleep(60 * std.time.ns_per_ms);

    var resp: [32]u8 = undefined;
    const n = try cli.read(&resp);
    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "ICY 200 OK"));
}
