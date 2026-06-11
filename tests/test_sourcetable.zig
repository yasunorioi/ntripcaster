//! tests/test_sourcetable.zig — ntrip/sourcetable.zig のユニットテスト
//!
//! テスト対象:
//!   - buildResponse: ヘッダー形式、Content-Length整合性、ENDSOURCETABLE付加
//!   - buildResponse: 空ボディ・非空ボディ・末尾改行なしボディ

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const sourcetable = ntripcaster.ntrip.sourcetable;

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

// ── buildResponseV2 (NTRIP v2) ────────────────────────────────────────────────

test "buildResponseV2: starts with HTTP/1.1 200 OK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponseV2(arena.allocator(), "", "localhost", &.{}, false);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
}

test "buildResponseV2: includes Ntrip-Version and gnss/sourcetable Content-Type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponseV2(arena.allocator(), "", "localhost", &.{}, false);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Ntrip-Version: Ntrip/2.0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Type: gnss/sourcetable; charset=UTF-8\r\n") != null);
}

test "buildResponseV2: Connection: close when keep_alive=false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponseV2(arena.allocator(), "", "localhost", &.{}, false);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: keep-alive\r\n") == null);
}

test "buildResponseV2: Connection: keep-alive when keep_alive=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponseV2(arena.allocator(), "", "localhost", &.{}, true);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: keep-alive\r\n") != null);
}

test "buildResponseV2: Content-Length matches body length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sources = [_]sourcetable.SourceEntry{
        .{ .mount = "M1", .format = "RTCM 3.2", .format_details = "1005(1)" },
    };
    const resp = try sourcetable.buildResponseV2(arena.allocator(), "", "localhost", &sources, false);
    const cl_prefix = "Content-Length: ";
    const cl_start = std.mem.indexOf(u8, resp, cl_prefix) orelse return error.NoContentLength;
    const cl_vs = cl_start + cl_prefix.len;
    const cl_ve = std.mem.indexOf(u8, resp[cl_vs..], "\r\n") orelse return error.NoCRLF;
    const cl = try std.fmt.parseInt(usize, resp[cl_vs .. cl_vs + cl_ve], 10);
    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoHeaderEnd;
    try std.testing.expectEqual(cl, resp[header_end + 4 ..].len);
}

test "buildResponseV2: body ends with ENDSOURCETABLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = try sourcetable.buildResponseV2(arena.allocator(), "", "localhost", &.{}, false);
    try std.testing.expect(std.mem.endsWith(u8, resp, "ENDSOURCETABLE\r\n"));
}

// ── buildCasterHeader (CAS/NET auto-generation, sourcetable.dat 廃止) ─────────

test "buildCasterHeader: emits CAS with all 12 fields and trailing CRLF" {
    const alloc = std.testing.allocator;
    const cas = try sourcetable.buildCasterHeader(alloc, .{
        .host = "caster.example.com",
        .port = 2101,
        .identifier = "ExampleCaster",
        .operator = "Example Inc.",
        .nmea = 1,
        .country = "JPN",
        .latitude = 43.1234,
        .longitude = 141.5678,
        .misc = "test",
    }, null);
    defer alloc.free(cas);

    // CAS で始まり、改行で終わる
    try std.testing.expect(std.mem.startsWith(u8, cas, "CAS;caster.example.com;2101;ExampleCaster;Example Inc.;1;JPN;43.12;141.57;"));
    try std.testing.expect(std.mem.endsWith(u8, cas, "\r\n"));
    // セパレータが 12 個（CAS + 11 fields の後）あるはず
    var semis: usize = 0;
    for (cas) |c| if (c == ';') { semis += 1; };
    try std.testing.expectEqual(@as(usize, 12), semis);
    // NET 行は出ない
    try std.testing.expect(std.mem.indexOf(u8, cas, "NET;") == null);
}

test "buildCasterHeader: NET line emitted when network info supplied" {
    const alloc = std.testing.allocator;
    const out = try sourcetable.buildCasterHeader(alloc, .{
        .host = "localhost",
        .port = 2101,
    }, .{
        .identifier = "MyNet",
        .operator = "MyOrg",
        .auth = "B",
        .fee = "N",
        .web_net = "https://example.com/net",
    });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "CAS;localhost;2101;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NET;MyNet;MyOrg;B;N;https://example.com/net;;;;\r\n") != null);
}

test "buildCasterHeader: defaults render empty string fields" {
    const alloc = std.testing.allocator;
    const out = try sourcetable.buildCasterHeader(alloc, .{
        .host = "h",
        .port = 1,
    }, null);
    defer alloc.free(out);
    // 連続セミコロン (空フィールド) が含まれる
    try std.testing.expect(std.mem.indexOf(u8, out, ";;") != null);
}

test "buildCasterHeader: integrates with buildResponse as body" {
    const alloc = std.testing.allocator;
    const header = try sourcetable.buildCasterHeader(alloc, .{
        .host = "caster.example.com",
        .port = 2101,
        .identifier = "ExampleCaster",
        .country = "JPN",
    }, null);
    defer alloc.free(header);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]sourcetable.SourceEntry{.{ .mount = "LIVE0", .format = "RTCM 3.2" }};
    const resp = try sourcetable.buildResponse(arena.allocator(), header, "ignored", &sources);

    try std.testing.expect(std.mem.indexOf(u8, resp, "CAS;caster.example.com;2101;") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "STR;LIVE0;") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "ENDSOURCETABLE\r\n"));
}
