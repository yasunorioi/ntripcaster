//! ntrip/protocol.zig — NTRIP v1 プロトコルパーサー
//!
//! 原典 connection.c の handle_connection() と client.c / source.c の
//! ヘッダーパースを純粋な関数として分離。
//!
//! サポート: NTRIP v1 (ICYプロトコル) のみ。
//! v2 (HTTP/1.1 + Ntrip-Version + chunked transfer) は Phase 3以降。
//!
//! BKG差異(§2f):
//!   Source-Agent の先頭5文字が "ntrip" でない接続は拒否する（仕様は推奨、実装は強制）。

const std = @import("std");

// ── 型定義 ────────────────────────────────────────────────────────────────────

/// SOURCE コマンドのパース結果。
pub const SourceLogin = struct {
    /// パスワード（平文）
    password: []const u8,
    /// マウントパス（"/" で始まる）
    mount: []const u8,
    /// Source-Agent ヘッダー値（省略時 null）
    agent: ?[]const u8,
};

/// GET /<mount> リクエストのパース結果。
pub const ClientGet = struct {
    /// マウントパス（"/" で始まる）
    mount: []const u8,
    /// Authorization ヘッダー値（"Basic ..." 形式、省略時 null）
    auth_header: ?[]const u8,
    /// User-Agent ヘッダー値（省略時 null）
    user_agent: ?[]const u8,
    /// true = Ntrip-Version ヘッダーあり（NTRIP v2 クライアント）
    is_v2: bool,
};

/// NTRIPリクエストの判別結果。
///
/// 全スライスは元の `header` バッファを指す。
/// `header` バッファを解放するまで有効。
pub const NtripRequest = union(enum) {
    /// ソース（基準局）からの接続: "SOURCE <password> /<mount>\r\n..."
    source_login: SourceLogin,
    /// クライアントからのデータ要求: "GET /<mount> HTTP/1.x\r\n..."
    client_get: ClientGet,
    /// Sourcetable 要求: "GET / HTTP/1.x\r\n..."
    sourcetable_get: void,
    /// 未知・不正なリクエスト
    invalid: []const u8,
};

// ── 内部ヘルパー ──────────────────────────────────────────────────────────────

/// HTTPヘッダーブロックから指定ヘッダー名の値を取得する（大文字小文字無視）。
/// 最初の ":" で key / value を分割し、両端のスペースを trim して返す。
fn getHeader(header_block: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    _ = lines.next(); // リクエスト行をスキップ
    while (lines.next()) |line| {
        if (line.len == 0) break; // 空行 = ヘッダー終端
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// "SOURCE <password> /<mount>\r\n..." をパースする。
fn parseSourceLogin(header: []const u8) ?SourceLogin {
    // 最初の行を取り出す
    const line_end = std.mem.indexOfScalar(u8, header, '\n') orelse return null;
    const first_line = std.mem.trimRight(u8, header[0..line_end], " \r");

    // "SOURCE " は 7 文字。以降が "<password> /<mount>"
    if (first_line.len < 8) return null;
    const rest = first_line[7..];

    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const password = rest[0..space];
    const mount = std.mem.trimLeft(u8, rest[space + 1 ..], " ");
    if (mount.len == 0 or mount[0] != '/') return null;

    return .{
        .password = password,
        .mount = mount,
        .agent = getHeader(header, "Source-Agent"),
    };
}

/// "GET /<path> HTTP/1.x\r\n..." をパースする。
fn parseGetRequest(header: []const u8) NtripRequest {
    const line_end = std.mem.indexOfScalar(u8, header, '\n') orelse return .{ .invalid = header };
    const first_line = std.mem.trimRight(u8, header[0..line_end], " \r");

    // "GET " は 4 文字
    if (first_line.len < 5) return .{ .invalid = header };
    const after_get = first_line[4..];

    // パスと HTTP バージョン行を分割（スペースでパスが終わる）
    const path_end = std.mem.indexOfScalar(u8, after_get, ' ') orelse after_get.len;
    const path = after_get[0..path_end];

    // sourcetable 要求: パスが "/" のみ
    if (std.mem.eql(u8, path, "/")) return .sourcetable_get;

    // クライアントデータ要求
    const ntrip_ver = getHeader(header, "Ntrip-Version");
    return .{
        .client_get = .{
            .mount = path,
            .auth_header = getHeader(header, "Authorization"),
            .user_agent = getHeader(header, "User-Agent"),
            .is_v2 = ntrip_ver != null,
        },
    };
}

// ── 公開 API ──────────────────────────────────────────────────────────────────

/// HTTPヘッダーブロックをパースして NtripRequest を返す。
///
/// `header`: ソケットから読み取った生ヘッダー文字列（`\r\n\r\n` 終端まで）。
/// 返却値のスライスは全て `header` バッファを指す（`header` の生存期間内に使用すること）。
pub fn parseRequest(header: []const u8) NtripRequest {
    if (std.mem.startsWith(u8, header, "SOURCE ")) {
        return if (parseSourceLogin(header)) |sl|
            .{ .source_login = sl }
        else
            .{ .invalid = header };
    }
    if (std.mem.startsWith(u8, header, "GET ")) {
        return parseGetRequest(header);
    }
    return .{ .invalid = header };
}

/// Source-Agent ヘッダー値が NTRIP エージェントであるか検証する。
///
/// §2f BKG差異: 先頭5文字が "ntrip"（大文字小文字無視）であることを強制する。
pub fn isNtripAgent(agent: []const u8) bool {
    if (agent.len < 5) return false;
    return std.ascii.eqlIgnoreCase(agent[0..5], "ntrip");
}
