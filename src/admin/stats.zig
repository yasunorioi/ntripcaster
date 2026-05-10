//! admin/stats.zig — admin API 用の JSON シリアライザ。
//!
//! ServerState のスナップショットを JSON 化し、admin/server.zig が
//! /api/v1/* レスポンスとして返す。
//!
//! 手書き JSON で std.json への依存を避ける（出力先は std.ArrayList(u8)）。
//! 文字列フィールドは JSON 仕様に従いエスケープする。

const std = @import("std");
const server = @import("../server.zig");

/// ── JSON ヘルパー ────────────────────────────────────────────────────────────

fn appendByteHex(out: *std.ArrayList(u8), alloc: std.mem.Allocator, b: u8) !void {
    const hex_chars = "0123456789abcdef";
    var s: [6]u8 = .{ '\\', 'u', '0', '0', 0, 0 };
    s[4] = hex_chars[(b >> 4) & 0xF];
    s[5] = hex_chars[b & 0xF];
    try out.appendSlice(alloc, &s);
}

/// JSON 文字列リテラルとして出力する（前後のダブルクォート込み）。
pub fn appendQuoted(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    s: []const u8,
) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0...0x07, 0x0B, 0x0E...0x1F => try appendByteHex(out, alloc, c),
            else => try out.append(alloc, c),
        }
    }
    try out.append(alloc, '"');
}

/// std.net.Address を "ip:port" 形式で出力する（JSON 文字列として）。
pub fn appendAddr(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    addr: std.net.Address,
) !void {
    var tmp: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&tmp, "{f}", .{addr}) catch
        std.fmt.bufPrint(&tmp, "?", .{}) catch unreachable;
    try appendQuoted(out, alloc, formatted);
}

/// ── /api/v1/status ──────────────────────────────────────────────────────────

pub fn writeStatusJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    state: *server.ServerState,
    version: []const u8,
    server_started_at_ms: i64,
) !void {
    const now_ms = std.time.milliTimestamp();
    const uptime_ms = now_ms - server_started_at_ms;

    try out.append(alloc, '{');
    try out.appendSlice(alloc, "\"version\":");
    try appendQuoted(out, alloc, version);

    try writeKeyInt(out, alloc, ",\"started_at_ms\":", server_started_at_ms);
    try writeKeyInt(out, alloc, ",\"now_ms\":", now_ms);
    try writeKeyInt(out, alloc, ",\"uptime_ms\":", uptime_ms);
    try writeKeyInt(out, alloc, ",\"sources\":", @as(i64, @intCast(state.sourceCount())));
    try writeKeyInt(out, alloc, ",\"clients\":", @as(i64, @intCast(state.clientCount())));

    try out.appendSlice(alloc, ",\"listen\":");
    try appendAddr(out, alloc, state.listen_address);
    try out.append(alloc, '}');
}

/// ── /api/v1/sources ─────────────────────────────────────────────────────────

pub fn writeSourcesJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    state: *server.ServerState,
) !void {
    const snaps = try state.snapshotSources(alloc);
    defer {
        for (snaps) |*s| s.deinit(alloc);
        alloc.free(snaps);
    }

    try out.append(alloc, '[');
    for (snaps, 0..) |s, idx| {
        if (idx > 0) try out.append(alloc, ',');
        try out.append(alloc, '{');
        try out.appendSlice(alloc, "\"mount\":");
        try appendQuoted(out, alloc, s.mount);

        try out.appendSlice(alloc, ",\"peer\":");
        try appendAddr(out, alloc, s.peer_addr);

        try writeKeyBool(out, alloc, ",\"rtcm_detected\":", s.rtcm_detected);
        try writeKeyInt(out, alloc, ",\"client_count\":", @as(i64, @intCast(s.client_count)));
        try writeKeyInt(out, alloc, ",\"bytes_in\":", @as(i64, @intCast(s.bytes_in)));
        try writeKeyInt(out, alloc, ",\"started_at_ms\":", s.started_at_ms);
        try writeKeyInt(out, alloc, ",\"last_data_at_ms\":", s.last_data_at_ms);

        // msg_types: [{"type":N,"count":M}, ...]
        try out.appendSlice(alloc, ",\"msg_types\":[");
        for (s.msg_types, 0..) |mt, j| {
            if (j > 0) try out.append(alloc, ',');
            try out.append(alloc, '{');
            try writeKeyInt(out, alloc, "\"type\":", @as(i64, mt.msg_type));
            try writeKeyInt(out, alloc, ",\"count\":", @as(i64, @intCast(mt.count)));
            try out.append(alloc, '}');
        }
        try out.append(alloc, ']');
        try out.append(alloc, '}');
    }
    try out.append(alloc, ']');
}

/// ── /api/v1/clients ─────────────────────────────────────────────────────────

pub fn writeClientsJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    state: *server.ServerState,
) !void {
    const snaps = try state.snapshotClients(alloc);
    defer {
        for (snaps) |*c| c.deinit(alloc);
        alloc.free(snaps);
    }

    try out.append(alloc, '[');
    for (snaps, 0..) |c, idx| {
        if (idx > 0) try out.append(alloc, ',');
        try out.append(alloc, '{');
        try writeKeyInt(out, alloc, "\"id\":", @as(i64, @intCast(c.id)));
        try out.appendSlice(alloc, ",\"mount\":");
        try appendQuoted(out, alloc, c.mount);
        try out.appendSlice(alloc, ",\"peer\":");
        try appendAddr(out, alloc, c.peer_addr);
        try writeKeyInt(out, alloc, ",\"bytes_out\":", @as(i64, @intCast(c.bytes_out)));
        try writeKeyInt(out, alloc, ",\"started_at_ms\":", c.started_at_ms);
        try out.append(alloc, '}');
    }
    try out.append(alloc, ']');
}

// ── プリミティブ ────────────────────────────────────────────────────────────

fn writeKeyInt(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    key_with_punct: []const u8,
    value: i64,
) !void {
    try out.appendSlice(alloc, key_with_punct);
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(alloc, s);
}

fn writeKeyBool(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    key_with_punct: []const u8,
    value: bool,
) !void {
    try out.appendSlice(alloc, key_with_punct);
    try out.appendSlice(alloc, if (value) "true" else "false");
}

// ── テスト ─────────────────────────────────────────────────────────────────

test "appendQuoted: escapes control + special chars" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    try appendQuoted(&buf, std.testing.allocator, "a\"b\\c\nd\te\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001\"", buf.items);
}
