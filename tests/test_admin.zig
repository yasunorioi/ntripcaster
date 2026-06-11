//! tests/test_admin.zig — admin/stats.zig のユニットテストと admin/server.zig 経由の
//! HTTP / JSON 動作確認（Phase A スコープ）。

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const stats = ntripcaster.admin.stats;
const admin_server = ntripcaster.admin.server;
const parser = ntripcaster.config;
const server_mod = ntripcaster.server;

// ── stats.zig: appendQuoted ──────────────────────────────────────────────────

test "stats: appendQuoted escapes specials" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try stats.appendQuoted(&buf, std.testing.allocator, "a\"b\\c\nd\te");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", buf.items);
}

test "stats: appendQuoted escapes control byte as \\u00XX" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try stats.appendQuoted(&buf, std.testing.allocator, "x\x01y");
    try std.testing.expectEqualStrings("\"x\\u0001y\"", buf.items);
}

// ── stats.zig: status JSON ───────────────────────────────────────────────────

test "stats: writeStatusJson emits expected keys" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var config = try parser.parse(arena.allocator(), "encoder_password test\n");
    defer config.deinit();

    var state = server_mod.ServerState.init(alloc, &config, ".");
    defer state.deinit();

    // listen_address はテストでは未設定なので適当な値を入れる
    state.listen_address = try std.net.Address.parseIp4("127.0.0.1", 2101);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try stats.writeStatusJson(&out, alloc, &state, "0.2.1", 1234);

    // 必須キーの存在確認
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"version\":\"0.2.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"started_at_ms\":1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"sources\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"clients\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"listen\":") != null);
}

// ── stats.zig: sources / clients JSON (空) ───────────────────────────────────

test "stats: writeSourcesJson empty" {
    const alloc = std.testing.allocator;
    var config = try parser.parse(alloc, "");
    defer config.deinit();
    var state = server_mod.ServerState.init(alloc, &config, ".");
    defer state.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try stats.writeSourcesJson(&out, alloc, &state);
    try std.testing.expectEqualStrings("[]", out.items);
}

test "stats: writeSourcesJson station field is null when no 1005 received" {
    const source_mod = ntripcaster.ntrip.source;
    const alloc = std.testing.allocator;
    var config = try parser.parse(alloc, "");
    defer config.deinit();
    var state = server_mod.ServerState.init(alloc, &config, ".");
    defer state.deinit();

    const peer = try std.net.Address.parseIp4("127.0.0.1", 1234);
    const src = try source_mod.Source.create(alloc, "/M1", peer);
    try state.registerSource(src);
    defer {
        state.unregisterSource("/M1");
        src.destroy();
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try stats.writeSourcesJson(&out, alloc, &state);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"station\":null") != null);
}

test "stats: writeSourcesJson exposes station lat/lon once 1005 seen" {
    const source_mod = ntripcaster.ntrip.source;
    const rtcm3 = ntripcaster.ntrip.rtcm3;
    const alloc = std.testing.allocator;
    var config = try parser.parse(alloc, "");
    defer config.deinit();
    var state = server_mod.ServerState.init(alloc, &config, ".");
    defer state.deinit();

    const peer = try std.net.Address.parseIp4("127.0.0.1", 5678);
    const src = try source_mod.Source.create(alloc, "/SAP", peer);
    src.station = rtcm3.StationCoord{
        .ref_station_id = 7,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat_deg = 43.0686,
        .lon_deg = 141.3506,
        .antenna_height_m = 5.0,
    };
    try state.registerSource(src);
    defer {
        state.unregisterSource("/SAP");
        src.destroy();
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try stats.writeSourcesJson(&out, alloc, &state);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"station\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ref_id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"lat\":43.0686") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"lon\":141.3506") != null);
}

test "stats: writeClientsJson empty" {
    const alloc = std.testing.allocator;
    var config = try parser.parse(alloc, "");
    defer config.deinit();
    var state = server_mod.ServerState.init(alloc, &config, ".");
    defer state.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try stats.writeClientsJson(&out, alloc, &state);
    try std.testing.expectEqualStrings("[]", out.items);
}

// ── admin/server.zig: AdminState 構造の sanity ──────────────────────────────

test "admin: AdminState compiles and exposes shutdown" {
    const alloc = std.testing.allocator;
    var config = try parser.parse(alloc, "");
    defer config.deinit();
    var state = server_mod.ServerState.init(alloc, &config, ".");
    defer state.deinit();

    var admin = admin_server.AdminState{
        .state = &state,
        .bind = "127.0.0.1",
        .port = 0,
        .user = "",
        .password = "",
        .server_started_at_ms = std.time.milliTimestamp(),
        .alloc = alloc,
    };
    // listener が無い状態で shutdown() してもクラッシュしないこと
    admin.shutdown();
}
