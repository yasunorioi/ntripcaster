//! tests/test_config.zig — config/parser.zig のユニットテスト
//!
//! テスト対象:
//!   - キーバリューパース（port, max_clients, server_name, encoder_password, ...）
//!   - マウント認証行（有認証・オープン）
//!   - コメント・空行の無視
//!   - 未知キーの無視（前方互換性）
//!   - 原典 ntripcaster.conf.dist の実パース

const std = @import("std");
const parser = @import("ntripcaster").config;

// ── ヘルパー: テスト用 Arena ──────────────────────────────────────────────────

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

// ── 基本パース ────────────────────────────────────────────────────────────────

test "parse: port" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "port 2101\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 2101), cfg.port);
}

test "parse: max_clients" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "max_clients 200\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 200), cfg.max_clients);
}

test "parse: max_sources" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "max_sources 10\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 10), cfg.max_sources);
}

test "parse: encoder_password" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "encoder_password my_secret\n");
    defer cfg.deinit();

    try std.testing.expectEqualStrings("my_secret", cfg.encoder_password);
}

test "parse: server_name" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "server_name caster.example.com\n");
    defer cfg.deinit();

    try std.testing.expectEqualStrings("caster.example.com", cfg.server_name);
}

test "parse: logdir and logfile" {
    var arena = testArena();
    defer arena.deinit();

    const content =
        \\logdir /var/log/ntripcaster
        \\logfile ntrip.log
    ;
    var cfg = try parser.parse(arena.allocator(), content);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("/var/log/ntripcaster", cfg.logdir);
    try std.testing.expectEqualStrings("ntrip.log", cfg.logfile);
}

// ── デフォルト値 ──────────────────────────────────────────────────────────────

test "parse: empty content uses defaults" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 2101), cfg.port);
    try std.testing.expectEqual(@as(u32, 100), cfg.max_clients);
    try std.testing.expectEqual(@as(u32, 40), cfg.max_sources);
    try std.testing.expectEqualStrings("sesam01", cfg.encoder_password);
}

// ── コメント・空行 ────────────────────────────────────────────────────────────

test "parse: comments and blank lines are ignored" {
    var arena = testArena();
    defer arena.deinit();

    const content =
        \\# This is a comment
        \\
        \\  # Indented comment
        \\port 8000
        \\
    ;
    var cfg = try parser.parse(arena.allocator(), content);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 8000), cfg.port);
}

// ── 未知キー（前方互換性） ────────────────────────────────────────────────────

test "parse: unknown keys are ignored" {
    var arena = testArena();
    defer arena.deinit();

    const content =
        \\port 2101
        \\future_setting some_value
        \\another_future_key 42
    ;
    var cfg = try parser.parse(arena.allocator(), content);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 2101), cfg.port);
}

// ── マウント認証行 ────────────────────────────────────────────────────────────

test "parse: authenticated mount with two users" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "/BUCU0:user1:password1,user2:password2\n");
    defer cfg.deinit();

    const auth = cfg.mounts.get("/BUCU0") orelse return error.MountNotFound;
    try std.testing.expect(!auth.open);
    try std.testing.expectEqual(@as(usize, 2), auth.users.len);
    try std.testing.expectEqualStrings("user1", auth.users[0].name);
    try std.testing.expectEqualStrings("password1", auth.users[0].password);
    try std.testing.expectEqualStrings("user2", auth.users[1].name);
    try std.testing.expectEqualStrings("password2", auth.users[1].password);
}

test "parse: open mount (no auth)" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "/PADO0\n");
    defer cfg.deinit();

    const auth = cfg.mounts.get("/PADO0") orelse return error.MountNotFound;
    try std.testing.expect(auth.open);
    try std.testing.expectEqual(@as(usize, 0), auth.users.len);
}

test "parse: multiple mounts" {
    var arena = testArena();
    defer arena.deinit();

    const content =
        \\/PRIVATE:alice:s3cr3t
        \\/PUBLIC
        \\/WORK:bob:hunter2,carol:abc123
    ;
    var cfg = try parser.parse(arena.allocator(), content);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 3), cfg.mounts.count());

    const priv = cfg.mounts.get("/PRIVATE") orelse return error.MountNotFound;
    try std.testing.expect(!priv.open);
    try std.testing.expectEqual(@as(usize, 1), priv.users.len);

    const pub_ = cfg.mounts.get("/PUBLIC") orelse return error.MountNotFound;
    try std.testing.expect(pub_.open);

    const work = cfg.mounts.get("/WORK") orelse return error.MountNotFound;
    try std.testing.expectEqual(@as(usize, 2), work.users.len);
}

// ── 原典 ntripcaster.conf.dist の実パース ────────────────────────────────────

/// 原典 ntripcaster.conf.dist をそのままインライン定義（後方互換性テスト用）
const CONF_DIST =
    \\##################################
    \\# NtripCaster configuration file #
    \\################################################################################
    \\
    \\############### Server Location and Resposible Person ##########################
    \\# Server meta info with no fuctionality.
    \\
    \\location BKG
    \\rp_email casteradmin@ifag.de
    \\server_url http://caster.ifag.de
    \\
    \\########################### Server Limits ######################################
    \\# Maximum number of simultaneous connections.
    \\
    \\max_clients 100
    \\max_clients_per_source 100
    \\max_sources 40
    \\
    \\######################### Server passwords #####################################
    \\# The "encoder_password" is used from the sources to log in.
    \\
    \\encoder_password sesam01
    \\
    \\#################### Server IP/port configuration ##############################
    \\
    \\server_name igs.ifag.de
    \\#port 80
    \\port 2101
    \\
    \\######################## Main Server Logfile ##################################
    \\
    \\logdir /tmp/ntripcaster_test/logs
    \\logfile ntripcaster.log
    \\
    \\############################ Access Control ###################################
    \\# Syntax: /<MOUNTPOINT>:<USER1>:<PASSWORD1>,<USER2>:<PASSWORD2>,...
    \\#
    \\/BUCU0:user1:password1,user2:password2
    \\/PADO0
    \\
;

test "parse: real ntripcaster.conf.dist" {
    var arena = testArena();
    defer arena.deinit();

    const content = CONF_DIST;

    var cfg = try parser.parse(arena.allocator(), content);
    defer cfg.deinit();

    // 原典設定値の検証
    try std.testing.expectEqual(@as(u16, 2101), cfg.port);
    try std.testing.expectEqual(@as(u32, 100), cfg.max_clients);
    try std.testing.expectEqual(@as(u32, 40), cfg.max_sources);
    try std.testing.expectEqualStrings("sesam01", cfg.encoder_password);
    try std.testing.expectEqualStrings("igs.ifag.de", cfg.server_name);

    // マウント: /BUCU0 (2ユーザー) + /PADO0 (オープン)
    try std.testing.expectEqual(@as(u32, 2), cfg.mounts.count());

    const bucu0 = cfg.mounts.get("/BUCU0") orelse return error.MountNotFound;
    try std.testing.expect(!bucu0.open);
    try std.testing.expectEqual(@as(usize, 2), bucu0.users.len);

    const pado0 = cfg.mounts.get("/PADO0") orelse return error.MountNotFound;
    try std.testing.expect(pado0.open);
}
