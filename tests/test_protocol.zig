//! tests/test_protocol.zig — ntrip/protocol.zig のユニットテスト
//!
//! テスト対象:
//!   - parseRequest: SOURCE / GET / GET / / 不正コマンド
//!   - SourceLogin フィールド（password, mount, agent）
//!   - ClientGet フィールド（mount, auth_header, user_agent, is_v2）
//!   - isNtripAgent: 先頭5文字 "ntrip" 判定

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const protocol = ntripcaster.ntrip_protocol;

// ── SOURCE ────────────────────────────────────────────────────────────────────

test "parseRequest: SOURCE login basic" {
    const header = "SOURCE test_pass /BUCU0\r\n\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .source_login);
    try std.testing.expectEqualStrings("test_pass", req.source_login.password);
    try std.testing.expectEqualStrings("/BUCU0", req.source_login.mount);
    try std.testing.expect(req.source_login.agent == null);
}

test "parseRequest: SOURCE with Source-Agent header" {
    const header = "SOURCE mypass /MOUNT1\r\nSource-Agent: NTRIP BNC/2.12\r\n\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .source_login);
    try std.testing.expectEqualStrings("mypass", req.source_login.password);
    try std.testing.expectEqualStrings("/MOUNT1", req.source_login.mount);
    try std.testing.expect(req.source_login.agent != null);
    try std.testing.expectEqualStrings("NTRIP BNC/2.12", req.source_login.agent.?);
}

test "parseRequest: SOURCE password with special chars" {
    const header = "SOURCE s3cr3t_p@ss /MYREF\r\nSource-Agent: NTRIP str2str/2.4.3\r\n\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .source_login);
    try std.testing.expectEqualStrings("s3cr3t_p@ss", req.source_login.password);
    try std.testing.expectEqualStrings("/MYREF", req.source_login.mount);
}

// ── GET (client) ──────────────────────────────────────────────────────────────

test "parseRequest: GET /MOUNT client request" {
    const header = "GET /BUCU0 HTTP/1.0\r\n" ++
        "User-Agent: NTRIP rtkrcv/2.4.3\r\n" ++
        "Authorization: Basic dXNlcjE6cGFzc3dvcmQx\r\n" ++
        "\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .client_get);
    try std.testing.expectEqualStrings("/BUCU0", req.client_get.mount);
    try std.testing.expect(req.client_get.auth_header != null);
    try std.testing.expectEqualStrings("Basic dXNlcjE6cGFzc3dvcmQx", req.client_get.auth_header.?);
    try std.testing.expect(!req.client_get.is_v2);
}

test "parseRequest: GET /MOUNT without auth" {
    const header = "GET /PADO0 HTTP/1.0\r\nUser-Agent: NTRIP test/1.0\r\n\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .client_get);
    try std.testing.expectEqualStrings("/PADO0", req.client_get.mount);
    try std.testing.expect(req.client_get.auth_header == null);
    try std.testing.expect(!req.client_get.is_v2);
}

test "parseRequest: GET with User-Agent" {
    const header = "GET /MOUNT HTTP/1.0\r\nUser-Agent: NTRIP RTKLib/2.4.3\r\n\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .client_get);
    try std.testing.expect(req.client_get.user_agent != null);
    try std.testing.expectEqualStrings("NTRIP RTKLib/2.4.3", req.client_get.user_agent.?);
}

test "parseRequest: GET with Ntrip-Version header (v2 detection)" {
    const header = "GET /MOUNT HTTP/1.1\r\n" ++
        "Ntrip-Version: Ntrip/2.0\r\n" ++
        "User-Agent: NTRIP Test/1.0\r\n" ++
        "\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .client_get);
    try std.testing.expect(req.client_get.is_v2);
}

// ── GET / (sourcetable) ───────────────────────────────────────────────────────

test "parseRequest: GET / sourcetable request" {
    const header = "GET / HTTP/1.0\r\nUser-Agent: NTRIP rtkrcv/2.4.3\r\n\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .sourcetable_get);
}

test "parseRequest: GET / HTTP/1.1 also sourcetable" {
    const header = "GET / HTTP/1.1\r\nUser-Agent: NTRIP test\r\n\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .sourcetable_get);
}

// ── invalid ───────────────────────────────────────────────────────────────────

test "parseRequest: unknown command is invalid" {
    const header = "POST /something HTTP/1.1\r\n\r\n";
    const req = protocol.parseRequest(header);
    try std.testing.expect(req == .invalid);
}

test "parseRequest: empty header is invalid" {
    const req = protocol.parseRequest("");
    try std.testing.expect(req == .invalid);
}

test "parseRequest: DELETE is invalid" {
    const req = protocol.parseRequest("DELETE /mount HTTP/1.1\r\n\r\n");
    try std.testing.expect(req == .invalid);
}

// ── isNtripAgent ──────────────────────────────────────────────────────────────

test "isNtripAgent: NTRIP prefix uppercase" {
    try std.testing.expect(protocol.isNtripAgent("NTRIP str2str/1.0"));
}

test "isNtripAgent: ntrip prefix lowercase" {
    try std.testing.expect(protocol.isNtripAgent("ntrip test/0.1"));
}

test "isNtripAgent: mixed case" {
    try std.testing.expect(protocol.isNtripAgent("NtRiP BNC/2.12"));
}

test "isNtripAgent: non-NTRIP agent" {
    try std.testing.expect(!protocol.isNtripAgent("GPS SomeAgent"));
    try std.testing.expect(!protocol.isNtripAgent("curl/7.88.1"));
}

test "isNtripAgent: too short" {
    try std.testing.expect(!protocol.isNtripAgent("ntr"));
    try std.testing.expect(!protocol.isNtripAgent(""));
}
