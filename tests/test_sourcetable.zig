//! tests/test_sourcetable.zig — ntrip/sourcetable.zig のユニットテスト
//!
//! テスト対象:
//!   - buildResponse: ヘッダー形式、Content-Length整合性、ENDSOURCETABLE付加
//!   - buildResponse: 空ボディ・非空ボディ・末尾改行なしボディ

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const sourcetable = ntripcaster.sourcetable;

// ── buildResponse ─────────────────────────────────────────────────────────────

test "buildResponse: starts with SOURCETABLE 200 OK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponse(arena.allocator(), "", "localhost", &.{});
    try std.testing.expect(std.mem.startsWith(u8, resp, "SOURCETABLE 200 OK\r\n"));
}

test "buildResponse: empty body has only ENDSOURCETABLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponse(arena.allocator(), "", "localhost", &.{});
    // ヘッダー終端 \r\n\r\n の後が ENDSOURCETABLE のみ
    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoHeaderEnd;
    const body = resp[header_end + 4 ..];
    try std.testing.expectEqualStrings("ENDSOURCETABLE\r\n", body);
}

test "buildResponse: body is included before ENDSOURCETABLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body = "STR;BUCU0;Budapest;RTCM3;;\r\n";
    const resp = try sourcetable.buildResponse(arena.allocator(), body, "caster.example.com", &.{});

    try std.testing.expect(std.mem.indexOf(u8, resp, "STR;BUCU0") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ENDSOURCETABLE\r\n") != null);

    // ENDSOURCETABLE は STR; エントリの後
    const str_pos = std.mem.indexOf(u8, resp, "STR;BUCU0").?;
    const end_pos = std.mem.indexOf(u8, resp, "ENDSOURCETABLE").?;
    try std.testing.expect(str_pos < end_pos);
}

test "buildResponse: Content-Length matches actual body length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body = "STR;TEST;City;RTCM3;\r\n";
    const resp = try sourcetable.buildResponse(arena.allocator(), body, "localhost", &.{});

    // Content-Length 値を取り出す
    const cl_prefix = "Content-Length: ";
    const cl_start = std.mem.indexOf(u8, resp, cl_prefix) orelse return error.NoContentLength;
    const cl_vs = cl_start + cl_prefix.len;
    const cl_ve = std.mem.indexOf(u8, resp[cl_vs..], "\r\n") orelse return error.NoCRLF;
    const cl = try std.fmt.parseInt(usize, resp[cl_vs .. cl_vs + cl_ve], 10);

    // 実際のボディ長
    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoHeaderEnd;
    const actual_body = resp[header_end + 4 ..];
    try std.testing.expectEqual(cl, actual_body.len);
}

test "buildResponse: Content-Length correct for empty body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponse(arena.allocator(), "", "localhost", &.{});

    const cl_prefix = "Content-Length: ";
    const cl_start = std.mem.indexOf(u8, resp, cl_prefix) orelse return error.NoContentLength;
    const cl_vs = cl_start + cl_prefix.len;
    const cl_ve = std.mem.indexOf(u8, resp[cl_vs..], "\r\n") orelse return error.NoCRLF;
    const cl = try std.fmt.parseInt(usize, resp[cl_vs .. cl_vs + cl_ve], 10);

    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoHeaderEnd;
    const actual_body = resp[header_end + 4 ..];
    try std.testing.expectEqual(cl, actual_body.len);
}

test "buildResponse: Server header present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponse(arena.allocator(), "", "myserver", &.{});
    try std.testing.expect(std.mem.indexOf(u8, resp, "Server: NTRIP NtripCaster/") != null);
}

test "buildResponse: Content-Type is text/plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponse(arena.allocator(), "", "localhost", &.{});
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Type: text/plain") != null);
}

test "buildResponse: body without trailing newline gets CRLF appended" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 末尾に改行なし
    const body = "STR;NOLINE;City;RTCM3;";
    const resp = try sourcetable.buildResponse(arena.allocator(), body, "localhost", &.{});

    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoHeaderEnd;
    const actual_body = resp[header_end + 4 ..];

    // CRLF が補完されてから ENDSOURCETABLE
    try std.testing.expect(std.mem.startsWith(u8, actual_body, "STR;NOLINE;City;RTCM3;\r\n"));
}

test "buildResponse: multiple STR entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body =
        "STR;MOUNT1;City1;RTCM3;\r\n" ++
        "STR;MOUNT2;City2;RTCM3;\r\n" ++
        "CAS;caster.example.com;2101;TestCaster;BKG;0;DEU;50.11;8.69;\r\n";
    const resp = try sourcetable.buildResponse(arena.allocator(), body, "localhost", &.{});

    try std.testing.expect(std.mem.indexOf(u8, resp, "MOUNT1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "MOUNT2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ENDSOURCETABLE\r\n") != null);
}

// ── dynamic_mounts ────────────────────────────────────────────────────────────

test "buildResponse: dynamic_mounts empty produces no extra STR rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponse(arena.allocator(), "", "localhost", &.{});
    // ヘッダー終端後は ENDSOURCETABLE のみ
    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoHeaderEnd;
    const body = resp[header_end + 4 ..];
    try std.testing.expectEqualStrings("ENDSOURCETABLE\r\n", body);
}

test "buildResponse: dynamic source single mount appears as STR row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sources = [_]sourcetable.SourceEntry{.{ .mount = "LIVE0" }};
    const resp = try sourcetable.buildResponse(arena.allocator(), "", "localhost", &sources);

    // STR;LIVE0; が含まれる
    try std.testing.expect(std.mem.indexOf(u8, resp, "STR;LIVE0;") != null);
    // ENDSOURCETABLE は STR 行の後
    const str_pos = std.mem.indexOf(u8, resp, "STR;LIVE0;").?;
    const end_pos = std.mem.indexOf(u8, resp, "ENDSOURCETABLE").?;
    try std.testing.expect(str_pos < end_pos);
}

test "buildResponse: dynamic source with format and format_details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sources = [_]sourcetable.SourceEntry{.{
        .mount = "RTCM0",
        .format = "RTCM 3.2",
        .format_details = "1005(10),1077(1)",
    }};
    const resp = try sourcetable.buildResponse(arena.allocator(), "", "localhost", &sources);

    try std.testing.expect(std.mem.indexOf(u8, resp, "RTCM 3.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "1005(10),1077(1)") != null);
}

test "buildResponse: static body and dynamic sources both appear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const static_body = "CAS;localhost;2101;NtripCaster;0;DEU;0.00;0.00;0;0;misc;\r\n";
    const sources = [_]sourcetable.SourceEntry{
        .{ .mount = "RTCM1", .format = "RTCM 3.2", .format_details = "1005(1)" },
        .{ .mount = "RTCM2" },
    };
    const resp = try sourcetable.buildResponse(arena.allocator(), static_body, "localhost", &sources);

    // 静的エントリ確認
    try std.testing.expect(std.mem.indexOf(u8, resp, "CAS;localhost") != null);
    // 動的エントリ確認
    try std.testing.expect(std.mem.indexOf(u8, resp, "STR;RTCM1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "STR;RTCM2;") != null);
    // Content-Length 整合性確認
    const cl_prefix = "Content-Length: ";
    const cl_start = std.mem.indexOf(u8, resp, cl_prefix) orelse return error.NoContentLength;
    const cl_vs = cl_start + cl_prefix.len;
    const cl_ve = std.mem.indexOf(u8, resp[cl_vs..], "\r\n") orelse return error.NoCRLF;
    const cl = try std.fmt.parseInt(usize, resp[cl_vs .. cl_vs + cl_ve], 10);
    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoHeaderEnd;
    try std.testing.expectEqual(cl, resp[header_end + 4 ..].len);
}
