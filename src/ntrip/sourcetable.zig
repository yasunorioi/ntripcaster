//! ntrip/sourcetable.zig — Sourcetable管理・配信
//!
//! 原典 client.c の send_sourcetable() を Zig で再実装。
//! CAS/NET 行は設定から自動組み立て、STR 行は live source から動的生成。
//! 静的な sourcetable.dat ファイルは廃止（caller が CAS/NET テキストを
//! `buildCasterHeader` で生成し、`buildResponse` の `body` に渡す）。
//!
//! NTRIP v1 Sourcetable レスポンス形式:
//!   SOURCETABLE 200 OK\r\n
//!   Server: NTRIP NtripCaster/<version>\r\n
//!   Content-Type: text/plain\r\n
//!   Content-Length: {size}\r\n
//!   \r\n
//!   {body: CAS/NET ヘッダ + 動的 STR 行}
//!   ENDSOURCETABLE\r\n
//!
//! NTRIP v2 Sourcetable レスポンス形式:
//!   HTTP/1.1 200 OK\r\n
//!   Server: NTRIP NtripCaster/<version>\r\n
//!   Ntrip-Version: Ntrip/2.0\r\n
//!   Content-Type: gnss/sourcetable; charset=UTF-8\r\n
//!   Content-Length: {size}\r\n
//!   Connection: {close|keep-alive}\r\n
//!   \r\n
//!   {body}

const std = @import("std");

pub const CASTER_VERSION = "0.5.0";

/// 動的ソースの STR 行生成に使う情報
pub const SourceEntry = struct {
    mount: []const u8,
    /// ストリーム形式（例: "RTCM 3.2"）。未検出の場合は空文字列。
    format: []const u8 = "",
    /// フォーマット詳細（例: "1005(10),1077(1)"）。未検出の場合は空文字列。
    format_details: []const u8 = "",
};

/// NTRIP v1 sourcetable CAS レコード
/// CAS;<host>;<port>;<identifier>;<operator>;<nmea>;<country>;<lat>;<lon>;
///    <fallback_host>;<fallback_port>;<misc>
pub const CasterInfo = struct {
    host: []const u8,
    port: u16,
    identifier: []const u8 = "NtripCaster",
    operator: []const u8 = "",
    nmea: u8 = 0,
    country: []const u8 = "",
    latitude: f64 = 0.0,
    longitude: f64 = 0.0,
    fallback_host: []const u8 = "",
    fallback_port: u16 = 0,
    misc: []const u8 = "",
};

/// NTRIP v1 sourcetable NET レコード
/// NET;<identifier>;<operator>;<auth>;<fee>;<web-net>;<web-str>;<web-reg>;<misc>
pub const NetworkInfo = struct {
    identifier: []const u8,
    operator: []const u8 = "",
    auth: []const u8 = "N",
    fee: []const u8 = "N",
    web_net: []const u8 = "",
    web_str: []const u8 = "",
    web_reg: []const u8 = "",
    misc: []const u8 = "",
};

/// CAS + (任意の) NET 行を組み立てて返す。末尾は CRLF で締める。
/// 返却値は `allocator.free()` で解放すること。
pub fn buildCasterHeader(
    allocator: std.mem.Allocator,
    caster: CasterInfo,
    network: ?NetworkInfo,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const cas = try std.fmt.allocPrint(
        allocator,
        "CAS;{s};{d};{s};{s};{d};{s};{d:.2};{d:.2};{s};{d};{s};\r\n",
        .{
            caster.host,
            caster.port,
            caster.identifier,
            caster.operator,
            caster.nmea,
            caster.country,
            caster.latitude,
            caster.longitude,
            caster.fallback_host,
            caster.fallback_port,
            caster.misc,
        },
    );
    defer allocator.free(cas);
    try buf.appendSlice(allocator, cas);

    if (network) |net| {
        const net_line = try std.fmt.allocPrint(
            allocator,
            "NET;{s};{s};{s};{s};{s};{s};{s};{s};\r\n",
            .{
                net.identifier,
                net.operator,
                net.auth,
                net.fee,
                net.web_net,
                net.web_str,
                net.web_reg,
                net.misc,
            },
        );
        defer allocator.free(net_line);
        try buf.appendSlice(allocator, net_line);
    }

    return buf.toOwnedSlice(allocator);
}

/// "SOURCETABLE 200 OK" レスポンス全体を `allocator` 上に生成する。
///
/// `body`: sourcetable.dat の内容（空文字列可）。
/// `server_name`: Server ヘッダーに埋め込むサーバー名。
/// `dynamic_sources`: 現在接続中のソース情報スライス。
///   各エントリを NTRIP STR 行として body 末尾に追記する。
///   STR フォーマット: STR;mount;mount;format;format_details;;;;;;;;;N;N;0;;
///
/// 返却値: 呼び出し元が `allocator.free()` で解放すること。
pub fn buildResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    server_name: []const u8,
    dynamic_sources: []const SourceEntry,
) ![]u8 {
    _ = server_name; // Server ヘッダーには CASTER_VERSION のみ埋め込む

    // ボディ = sourcetable.dat 内容 + 動的STR行 + "ENDSOURCETABLE\r\n"
    var full_body = std.ArrayList(u8).empty;
    defer full_body.deinit(allocator);

    if (body.len > 0) {
        try full_body.appendSlice(allocator, body);
        // 末尾が改行でなければ CRLF を補完
        if (!std.mem.endsWith(u8, body, "\n")) {
            try full_body.appendSlice(allocator, "\r\n");
        }
    }

    // 動的ソースの STR 行を追記
    // NTRIP STR フィールド順:
    //   STR;mount;identifier;format;format-details;carrier;nav-sys;network;
    //   country;lat;lon;NMEA;solution;generator;compr-encryp;auth;fee;bitrate;misc;
    for (dynamic_sources) |entry| {
        try full_body.appendSlice(allocator, "STR;");
        try full_body.appendSlice(allocator, entry.mount);
        try full_body.appendSlice(allocator, ";");
        try full_body.appendSlice(allocator, entry.mount); // identifier = mount
        try full_body.appendSlice(allocator, ";");
        try full_body.appendSlice(allocator, entry.format);
        try full_body.appendSlice(allocator, ";");
        try full_body.appendSlice(allocator, entry.format_details);
        try full_body.appendSlice(allocator, ";;;;;;;;;N;N;0;;\r\n");
    }

    try full_body.appendSlice(allocator, "ENDSOURCETABLE\r\n");

    // ヘッダー + ボディを一つの文字列に結合
    return std.fmt.allocPrint(
        allocator,
        "SOURCETABLE 200 OK\r\n" ++
            "Server: NTRIP NtripCaster/{s}\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}",
        .{ CASTER_VERSION, full_body.items.len, full_body.items },
    );
}

/// NTRIP v2 (HTTP/1.1) 用の sourcetable レスポンスを生成する。
///
/// 引数は `buildResponse` (v1) と同じだが、レスポンスヘッダーが HTTP/1.1 形式になり
/// `Ntrip-Version: Ntrip/2.0` と `Content-Type: gnss/sourcetable; charset=UTF-8`
/// を付与する。`keep_alive` で `Connection` ヘッダーを切り替え。
pub fn buildResponseV2(
    allocator: std.mem.Allocator,
    body: []const u8,
    server_name: []const u8,
    dynamic_sources: []const SourceEntry,
    keep_alive: bool,
) ![]u8 {
    _ = server_name;

    var full_body = std.ArrayList(u8).empty;
    defer full_body.deinit(allocator);

    if (body.len > 0) {
        try full_body.appendSlice(allocator, body);
        if (!std.mem.endsWith(u8, body, "\n")) {
            try full_body.appendSlice(allocator, "\r\n");
        }
    }

    for (dynamic_sources) |entry| {
        try full_body.appendSlice(allocator, "STR;");
        try full_body.appendSlice(allocator, entry.mount);
        try full_body.appendSlice(allocator, ";");
        try full_body.appendSlice(allocator, entry.mount);
        try full_body.appendSlice(allocator, ";");
        try full_body.appendSlice(allocator, entry.format);
        try full_body.appendSlice(allocator, ";");
        try full_body.appendSlice(allocator, entry.format_details);
        try full_body.appendSlice(allocator, ";;;;;;;;;N;N;0;;\r\n");
    }

    try full_body.appendSlice(allocator, "ENDSOURCETABLE\r\n");

    const connection = if (keep_alive) "keep-alive" else "close";

    return std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\n" ++
            "Server: NTRIP NtripCaster/{s}\r\n" ++
            "Ntrip-Version: Ntrip/2.0\r\n" ++
            "Content-Type: gnss/sourcetable; charset=UTF-8\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: {s}\r\n" ++
            "\r\n" ++
            "{s}",
        .{ CASTER_VERSION, full_body.items.len, connection, full_body.items },
    );
}

// readFile() は廃止: sourcetable.dat に依存せず CAS/NET は設定から組み立てる。
