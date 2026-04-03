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

// ── FKP 設定 ──────────────────────────────────────────────────────────────────

test "fkp: fkp_enable default false" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "port 2101\n");
    defer cfg.deinit();

    try std.testing.expect(!cfg.fkp_enable);
}

test "fkp: fkp_enable true" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "fkp_enable true\n");
    defer cfg.deinit();

    try std.testing.expect(cfg.fkp_enable);
}

test "fkp: fkp_enable false explicit" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "fkp_enable false\n");
    defer cfg.deinit();

    try std.testing.expect(!cfg.fkp_enable);
}

test "fkp: fkp_source host/mount no auth" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "fkp_source rtk2go.com/nakagawa00\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.fkp_sources.len);
    const src = cfg.fkp_sources[0];
    try std.testing.expectEqualStrings("rtk2go.com", src.host);
    try std.testing.expectEqual(@as(u16, 2101), src.port);
    try std.testing.expectEqualStrings("nakagawa00", src.mountpoint);
    try std.testing.expectEqualStrings("", src.user);
    try std.testing.expectEqualStrings("", src.password);
}

test "fkp: fkp_source host:port/mount" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "fkp_source rtk2go.com:2101/Asahikawa-HAMA\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.fkp_sources.len);
    const src = cfg.fkp_sources[0];
    try std.testing.expectEqualStrings("rtk2go.com", src.host);
    try std.testing.expectEqual(@as(u16, 2101), src.port);
    try std.testing.expectEqualStrings("Asahikawa-HAMA", src.mountpoint);
}

test "fkp: fkp_source with auth" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(),
        "fkp_source rtk2go.com/UEMATSUDENKI-F9P test@example.com:none\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.fkp_sources.len);
    const src = cfg.fkp_sources[0];
    try std.testing.expectEqualStrings("rtk2go.com", src.host);
    try std.testing.expectEqualStrings("UEMATSUDENKI-F9P", src.mountpoint);
    try std.testing.expectEqualStrings("test@example.com", src.user);
    try std.testing.expectEqualStrings("none", src.password);
}

test "fkp: fkp_mountpoint" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "fkp_mountpoint /FKP_HOKKAIDO\n");
    defer cfg.deinit();

    try std.testing.expectEqualStrings("/FKP_HOKKAIDO", cfg.fkp_mountpoint);
}

test "fkp: fkp_interval default 1" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 1), cfg.fkp_interval);
}

test "fkp: fkp_interval explicit" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "fkp_interval 5\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 5), cfg.fkp_interval);
}

test "fkp: fkp_source 0 sources disabled" {
    var arena = testArena();
    defer arena.deinit();

    var cfg = try parser.parse(arena.allocator(), "fkp_enable true\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 0), cfg.fkp_sources.len);
}

test "fkp: fkp_source 2 sources (insufficient) emits warning" {
    var arena = testArena();
    defer arena.deinit();

    // fkp_enable true + 局数 < 3 → std.log.warn が出力される（FKP inactive）。
    // パーサーはエラーにせず 2 件をそのまま格納する。
    const content =
        \\fkp_enable true
        \\fkp_source rtk2go.com/mount1
        \\fkp_source rtk2go.com/mount2
    ;
    var cfg = try parser.parse(arena.allocator(), content);
    defer cfg.deinit();

    try std.testing.expect(cfg.fkp_enable);
    try std.testing.expectEqual(@as(usize, 2), cfg.fkp_sources.len);
}

test "fkp: full 3-source config with existing settings" {
    var arena = testArena();
    defer arena.deinit();

    const content =
        \\port 2101
        \\server_name caster.example.com
        \\fkp_enable true
        \\fkp_source rtk2go.com/nakagawa00 test@example.com:none
        \\fkp_source rtk2go.com:2101/Asahikawa-HAMA test@example.com:none
        \\fkp_source rtk2go.com/UEMATSUDENKI-F9P test@example.com:none
        \\fkp_mountpoint /FKP_HOKKAIDO
        \\fkp_interval 1
        \\/PADO0
    ;
    var cfg = try parser.parse(arena.allocator(), content);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 2101), cfg.port);
    try std.testing.expectEqualStrings("caster.example.com", cfg.server_name);
    try std.testing.expect(cfg.fkp_enable);
    try std.testing.expectEqual(@as(usize, 3), cfg.fkp_sources.len);
    try std.testing.expectEqualStrings("/FKP_HOKKAIDO", cfg.fkp_mountpoint);
    try std.testing.expectEqual(@as(u32, 1), cfg.fkp_interval);

    try std.testing.expectEqualStrings("nakagawa00", cfg.fkp_sources[0].mountpoint);
    try std.testing.expectEqualStrings("Asahikawa-HAMA", cfg.fkp_sources[1].mountpoint);
    try std.testing.expectEqualStrings("UEMATSUDENKI-F9P", cfg.fkp_sources[2].mountpoint);

    // 既存マウント設定も保持
    try std.testing.expectEqual(@as(u32, 1), cfg.mounts.count());
}
