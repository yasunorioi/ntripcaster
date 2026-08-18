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
const server_mod = ntripcaster.server;

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
    std.Thread.sleep(60 * std.time.ns_per_ms);
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
    std.Thread.sleep(80 * std.time.ns_per_ms);

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
    std.Thread.sleep(60 * std.time.ns_per_ms);

    var resp: [32]u8 = undefined;
    const n = try cli.read(&resp);
    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "ICY 200 OK"));
}

// ── 接続数制限 ────────────────────────────────────────────────────────────────

test "connection rejected when max_clients exceeded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    state.config.max_clients = 1; // 上限1
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    const port = boundPort(&state);
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    // 1つ目: SOURCE接続で active_handlers = 1
    var src = try std.net.tcpConnectToAddress(addr);
    defer src.close();
    try src.writeAll("SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok: [8]u8 = undefined;
    _ = try src.read(&ok); // "OK\r\n"

    // 2つ目: max_clients(1)超過 → "ERROR - Too Many Clients"
    var buf: [64]u8 = undefined;
    const n = try reqResp(
        port,
        "GET / HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "ERROR - Too Many Clients"));
}

test "client rejected when max_clients_per_source exceeded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    state.config.max_clients_per_source = 1; // 上限1
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

    // クライアント1: ICY 200 OK 受信 → client_count = 1 になる
    var cli1 = try std.net.tcpConnectToAddress(addr);
    defer cli1.close();
    try cli1.writeAll("GET /OPEN HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n");
    var icy: [32]u8 = undefined;
    const icy_n = try cli1.read(&icy);
    try std.testing.expect(std.mem.startsWith(u8, icy[0..icy_n], "ICY 200 OK"));

    // client_count が 1 になるまで待つ
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // クライアント2: max_clients_per_source(1)超過 → 503
    var buf: [64]u8 = undefined;
    const n = try reqResp(
        port,
        "GET /OPEN HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 503"));
}

test "source rejected when max_sources exceeded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    var state = server_mod.ServerState.init(arena.allocator(), &cfg, "conf");
    state.logger.stderr = false;
    state.config.port = 0;
    state.config.max_sources = 1; // 上限1
    defer state.deinit();

    const t = try startServer(&state);
    defer { state.shutdown(); t.join(); }

    const port = boundPort(&state);
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    // ソース1: OK
    var src1 = try std.net.tcpConnectToAddress(addr);
    defer src1.close();
    try src1.writeAll("SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok1: [8]u8 = undefined;
    _ = try src1.read(&ok1);

    // ソース2: max_sources(1)超過 → "ERROR - Too Many Sources"
    var buf: [64]u8 = undefined;
    const n = try reqResp(
        port,
        "SOURCE testpass /OTHER\r\nSource-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "ERROR - Too Many Sources"));
}

// ── NTRIP v2 統合テスト ────────────────────────────────────────────────────────

test "v2: GET / sourcetable returns HTTP/1.1 200 + Ntrip-Version" {
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
    var buf: [4096]u8 = undefined;
    const n = try reqResp(
        port,
        "GET / HTTP/1.1\r\nNtrip-Version: Ntrip/2.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    const resp = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Ntrip-Version: Ntrip/2.0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Type: gnss/sourcetable; charset=UTF-8\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ENDSOURCETABLE") != null);
}

test "v2: GET stream returns HTTP/1.1 200 + chunked" {
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

    // 先にソースを接続
    var src = try std.net.tcpConnectToAddress(addr);
    defer src.close();
    try src.writeAll("SOURCE testpass /OPEN\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok: [8]u8 = undefined;
    _ = try src.read(&ok);
    std.Thread.sleep(30 * std.time.ns_per_ms);

    // V2 クライアント接続
    var buf: [512]u8 = undefined;
    const n = try reqResp(
        port,
        "GET /OPEN HTTP/1.1\r\nNtrip-Version: Ntrip/2.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    const resp = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Transfer-Encoding: chunked\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Type: gnss/data\r\n") != null);
}

test "v2: POST source with Basic auth succeeds" {
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
    // base64("x:testpass") = "eDp0ZXN0cGFzcw=="
    var buf: [256]u8 = undefined;
    const n = try reqResp(
        port,
        "POST /V2MOUNT HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Ntrip-Version: Ntrip/2.0\r\n" ++
            "Source-Agent: NTRIP test/1.0\r\n" ++
            "Authorization: Basic eDp0ZXN0cGFzcw==\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n",
        &buf,
    );
    const resp = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Ntrip-Version: Ntrip/2.0\r\n") != null);
}

test "v2: POST source with bad password returns 401" {
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
    // base64("x:wrong") = "eDp3cm9uZw=="
    var buf: [256]u8 = undefined;
    const n = try reqResp(
        port,
        "POST /M HTTP/1.1\r\n" ++
            "Ntrip-Version: Ntrip/2.0\r\n" ++
            "Source-Agent: NTRIP test/1.0\r\n" ++
            "Authorization: Basic eDp3cm9uZw==\r\n" ++
            "\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 401"));
}

test "v2: POST with Expect 100-continue emits 100 then 200" {
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
    var buf: [512]u8 = undefined;
    const n = try reqResp(
        port,
        "POST /CONT HTTP/1.1\r\n" ++
            "Ntrip-Version: Ntrip/2.0\r\n" ++
            "Source-Agent: NTRIP test/1.0\r\n" ++
            "Authorization: Basic eDp0ZXN0cGFzcw==\r\n" ++
            "Expect: 100-continue\r\n" ++
            "\r\n",
        &buf,
    );
    const resp = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 100 Continue\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 200 OK\r\n") != null);
}

test "v1 regression: SOURCE still returns OK after v2 changes" {
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
    var buf: [64]u8 = undefined;
    const n = try reqResp(
        port,
        "SOURCE testpass /V1MOUNT\r\nSource-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "OK\r\n"));
}

test "v1 regression: GET / sourcetable still returns SOURCETABLE 200 OK" {
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
    var buf: [4096]u8 = undefined;
    const n = try reqResp(
        port,
        "GET / HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "SOURCETABLE 200 OK\r\n"));
}

// ── SOURCE takeover (mount reclaim) ──────────────────────────────────────────
// reboot/WiFi 瞬断で残った half-open は、その fd から RTCM が止まった時点で
// caster 側の source idle が伸び続ける。認証済みの再接続は正当な基準局なので、
// idle が SOURCE_TAKEOVER_IDLE_MS を超えていれば旧接続を即 evict して mount を
// 取り返せる（"Mount already in use" backoff ~30-45s の解消）。実 TCP で確認。

const TAKEOVER_MS = ntripcaster.ntrip.source.SOURCE_TAKEOVER_IDLE_MS;

test "SOURCE takeover: authenticated reconnect evicts an idle source, reclaims mount" {
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

    // 旧接続: SOURCE で mount を握るが以後データを送らない（half-open 相当）。
    var old = try std.net.tcpConnectToAddress(addr);
    defer old.close();
    try old.writeAll("SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok1: [8]u8 = undefined;
    const ok1_n = try old.read(&ok1);
    try std.testing.expectEqualStrings("OK\r\n", ok1[0..ok1_n]);

    // idle が takeover grace を超えるまで待つ（旧接続はデータを送らないので
    // last_data_at_ms は登録時刻のまま伸び続ける）。
    std.Thread.sleep(@as(u64, @intCast(TAKEOVER_MS + 500)) * std.time.ns_per_ms);

    // 新接続: 同 mount へ再接続 → takeover で即 OK が返るはず。
    var new = try std.net.tcpConnectToAddress(addr);
    defer new.close();
    try new.writeAll("SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok2: [16]u8 = undefined;
    const ok2_n = try new.read(&ok2);
    try std.testing.expectEqualStrings("OK\r\n", ok2[0..ok2_n]);

    // 旧接続の socket は caster に shutdown され、read は EOF(0) で返るはず。
    var drain: [64]u8 = undefined;
    const old_n = old.read(&drain) catch 0; // reset ならエラー → 同義で evicted
    try std.testing.expectEqual(@as(usize, 0), old_n);
}

test "SOURCE takeover: a live source is NOT evicted (anti-flap)" {
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

    // 現役接続: 直前に登録された（idle ≈ 0 << grace）。
    var live = try std.net.tcpConnectToAddress(addr);
    defer live.close();
    try live.writeAll("SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n");
    var ok1: [8]u8 = undefined;
    const ok1_n = try live.read(&ok1);
    try std.testing.expectEqualStrings("OK\r\n", ok1[0..ok1_n]);

    // grace 内に別 SOURCE が来ても現役は evict されず、新参が弾かれる。
    var buf: [64]u8 = undefined;
    const n = try reqResp(
        port,
        "SOURCE testpass /RELAY\r\nSource-Agent: NTRIP test/1.0\r\n\r\n",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "in use") != null);
}
