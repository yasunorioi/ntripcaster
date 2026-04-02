//! ntrip/sourcetable.zig — Sourcetable管理・配信
//!
//! 原典 client.c の send_sourcetable() を Zig で再実装。
//!
//! NTRIP v1 Sourcetable レスポンス形式:
//!   SOURCETABLE 200 OK\r\n
//!   Server: NTRIP NtripCaster/<version>\r\n
//!   Content-Type: text/plain\r\n
//!   Content-Length: {size}\r\n
//!   \r\n
//!   {sourcetable.dat 内容}
//!   ENDSOURCETABLE\r\n

const std = @import("std");

pub const CASTER_VERSION = "0.2.0";

/// "SOURCETABLE 200 OK" レスポンス全体を `allocator` 上に生成する。
///
/// `body`: sourcetable.dat の内容（空文字列可）。
/// `server_name`: Server ヘッダーに埋め込むサーバー名。
/// `dynamic_mounts`: 現在接続中のソースマウント名スライス。
///   各エントリを `STR;{mount};;;;;;;;;;;;;N;N;0;;\r\n` 形式で body 末尾に追記する。
///
/// 返却値: 呼び出し元が `allocator.free()` で解放すること。
pub fn buildResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    server_name: []const u8,
    dynamic_mounts: []const []const u8,
) ![]u8 {
    _ = server_name; // Server ヘッダーには CASTER_VERSION のみ埋め込む

    // ボディ = sourcetable.dat 内容 + 動的STR行 + "ENDSOURCETABLE\r\n"
    var full_body = std.ArrayList(u8){};
    defer full_body.deinit(allocator);

    if (body.len > 0) {
        try full_body.appendSlice(allocator, body);
        // 末尾が改行でなければ CRLF を補完
        if (!std.mem.endsWith(u8, body, "\n")) {
            try full_body.appendSlice(allocator, "\r\n");
        }
    }

    // 動的ソースの STR 行を追記
    for (dynamic_mounts) |mount| {
        try full_body.appendSlice(allocator, "STR;");
        try full_body.appendSlice(allocator, mount);
        try full_body.appendSlice(allocator, ";;;;;;;;;;;;;N;N;0;;\r\n");
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

/// sourcetable.dat ファイルを読み込む。
/// ファイルが存在しない場合は null を返す（空の sourcetable で代替）。
///
/// 返却値: 呼び出し元が `allocator.free()` で解放すること。
pub fn readFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) !?[]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |e| {
        if (e == error.FileNotFound) return null;
        return e;
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB 上限
}
