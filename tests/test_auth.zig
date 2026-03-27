//! tests/test_auth.zig — auth/basic.zig のユニットテスト
//!
//! テスト対象:
//!   - decodeBase64: 正常デコード・不正 Base64・バッファ過小
//!   - parseCredentials: 正常・コロンなし・空パスワード
//!   - extractCredentials: 正常・プレフィックスなし・不正 Base64
//!   - authenticateClient: 認証成功・パスワード誤り・マウント不明・オープンマウント
//!   - authenticateSource: 正常・不一致

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const auth = ntripcaster.auth;
const parser = ntripcaster.config;

// ── decodeBase64 ──────────────────────────────────────────────────────────────

test "decodeBase64: known value" {
    // "user1:password1" → dXNlcjE6cGFzc3dvcmQx
    var buf: [128]u8 = undefined;
    const decoded = try auth.decodeBase64("dXNlcjE6cGFzc3dvcmQx", &buf);
    try std.testing.expectEqualStrings("user1:password1", decoded);
}

test "decodeBase64: empty string" {
    var buf: [128]u8 = undefined;
    const decoded = try auth.decodeBase64("", &buf);
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "decodeBase64: invalid base64 chars" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidBase64, auth.decodeBase64("!@#$%^", &buf));
}

test "decodeBase64: buffer too small" {
    // "user1:password1" デコードには 15 バイト必要
    var buf: [4]u8 = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        auth.decodeBase64("dXNlcjE6cGFzc3dvcmQx", &buf),
    );
}

// ── parseCredentials ──────────────────────────────────────────────────────────

test "parseCredentials: normal user:pass" {
    const cred: auth.Credentials = auth.parseCredentials("alice:s3cr3t") orelse return error.NullResult;
    try std.testing.expectEqualStrings("alice", cred.user);
    try std.testing.expectEqualStrings("s3cr3t", cred.pass);
}

test "parseCredentials: empty password" {
    const cred: auth.Credentials = auth.parseCredentials("alice:") orelse return error.NullResult;
    try std.testing.expectEqualStrings("alice", cred.user);
    try std.testing.expectEqualStrings("", cred.pass);
}

test "parseCredentials: password contains colon" {
    // "user:pass:with:colons" → user="user", pass="pass:with:colons"
    const cred: auth.Credentials = auth.parseCredentials("user:pass:with:colons") orelse return error.NullResult;
    try std.testing.expectEqualStrings("user", cred.user);
    try std.testing.expectEqualStrings("pass:with:colons", cred.pass);
}

test "parseCredentials: no colon returns null" {
    try std.testing.expect(auth.parseCredentials("nocoion") == null);
}

// ── extractCredentials ────────────────────────────────────────────────────────

test "extractCredentials: valid Basic header" {
    // "user1:password1" → dXNlcjE6cGFzc3dvcmQx
    var buf: [128]u8 = undefined;
    const cred = try auth.extractCredentials("Basic dXNlcjE6cGFzc3dvcmQx", &buf);
    try std.testing.expectEqualStrings("user1", cred.user);
    try std.testing.expectEqualStrings("password1", cred.pass);
}

test "extractCredentials: missing Basic prefix" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(
        error.InvalidHeader,
        auth.extractCredentials("Bearer token123", &buf),
    );
}

test "extractCredentials: invalid base64 in value" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(
        error.InvalidBase64,
        auth.extractCredentials("Basic !!!invalid!!!", &buf),
    );
}

test "extractCredentials: trailing whitespace trimmed" {
    var buf: [128]u8 = undefined;
    const cred = try auth.extractCredentials("Basic dXNlcjE6cGFzc3dvcmQx  \r\n", &buf);
    try std.testing.expectEqualStrings("user1", cred.user);
}

// ── authenticateClient ────────────────────────────────────────────────────────

/// テスト用 Config を構築するヘルパー
fn makeTestConfig(allocator: std.mem.Allocator) !parser.Config {
    const content =
        \\encoder_password test_encoder_pass
        \\/BUCU0:user1:password1,user2:password2
        \\/PADO0
    ;
    return parser.parse(allocator, content);
}

test "authenticateClient: correct user and password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    try std.testing.expect(auth.authenticateClient(&cfg, "/BUCU0", "user1", "password1"));
    try std.testing.expect(auth.authenticateClient(&cfg, "/BUCU0", "user2", "password2"));
}

test "authenticateClient: wrong password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    try std.testing.expect(!auth.authenticateClient(&cfg, "/BUCU0", "user1", "wrong_pass"));
}

test "authenticateClient: unknown user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    try std.testing.expect(!auth.authenticateClient(&cfg, "/BUCU0", "attacker", "password1"));
}

test "authenticateClient: unknown mount returns false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    try std.testing.expect(!auth.authenticateClient(&cfg, "/NONEXISTENT", "user1", "password1"));
}

test "authenticateClient: open mount allows any credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    // オープンマウントは user/pass 問わず許可
    try std.testing.expect(auth.authenticateClient(&cfg, "/PADO0", "", ""));
    try std.testing.expect(auth.authenticateClient(&cfg, "/PADO0", "anyone", "anything"));
}

// ── authenticateSource ────────────────────────────────────────────────────────

test "authenticateSource: correct encoder password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    try std.testing.expect(auth.authenticateSource(&cfg, "test_encoder_pass"));
}

test "authenticateSource: wrong encoder password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try makeTestConfig(arena.allocator());
    defer cfg.deinit();

    try std.testing.expect(!auth.authenticateSource(&cfg, "wrong_pass"));
}
