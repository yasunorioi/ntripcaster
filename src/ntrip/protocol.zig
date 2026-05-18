//! ntrip/protocol.zig — NTRIP v1 / v2 プロトコルパーサー
//!
//! 原典 connection.c の handle_connection() と client.c / source.c の
//! ヘッダーパースを純粋な関数として分離。
//!
//! サポート:
//!   - NTRIP v1 (ICY プロトコル: "SOURCE ... HTTP/1.0" / "GET ... HTTP/1.0")
//!   - NTRIP v2 (HTTP/1.1 + "Ntrip-Version: Ntrip/2.0"):
//!       GET (client / sourcetable), POST (source push, 100-continue 対応)
//!
//! V2 検出ルール: "Ntrip-Version" ヘッダーに "Ntrip/2.0" が含まれていれば v2。
//! 値が無くてもヘッダーがあるだけで v2 扱い（互換性のため）。
//!
//! BKG差異(§2f):
//!   Source-Agent の先頭5文字が "ntrip" でない接続は拒否する（仕様は推奨、実装は強制）。

const std = @import("std");

// ── 型定義 ────────────────────────────────────────────────────────────────────

/// ソース（基準局）ログインのパース結果。
///
/// V1 ("SOURCE <password> /<mount>"): `password` に平文、`auth_header` は null。
/// V2 ("POST /<mount> HTTP/1.1" + Authorization): `password` は空、
/// `auth_header` に "Basic ..." 形式が入る。
pub const SourceLogin = struct {
    /// マウントパス（"/" で始まる）
    mount: []const u8,
    /// V1 inline password。V2 では空文字列。
    password: []const u8,
    /// V2 Authorization ヘッダー値（"Basic ..." 形式）。V1 では null。
    auth_header: ?[]const u8,
    /// Source-Agent ヘッダー値（省略時 null）
    agent: ?[]const u8,
    /// true = NTRIP v2 (POST + Ntrip-Version)
    is_v2: bool,
    /// V2 のみ: "Expect: 100-continue" ヘッダーあり
    expects_100: bool,
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
    /// true = "Connection: keep-alive"（V2 sourcetable 連続要求用、データストリームでは無視）
    keep_alive: bool,
};

/// GET / (sourcetable) リクエストのパース結果。
pub const SourcetableGet = struct {
    /// true = Ntrip-Version ヘッダーあり（NTRIP v2 クライアント）
    is_v2: bool,
    /// true = "Connection: keep-alive"
    keep_alive: bool,
};

/// NTRIPリクエストの判別結果。
///
/// 全スライスは元の `header` バッファを指す。
/// `header` バッファを解放するまで有効。
pub const NtripRequest = union(enum) {
    /// ソース（基準局）からの接続:
    ///   V1: "SOURCE <password> /<mount>\r\n..."
    ///   V2: "POST /<mount> HTTP/1.1\r\nNtrip-Version: Ntrip/2.0\r\nAuthorization: Basic ...\r\n..."
    source_login: SourceLogin,
    /// クライアントからのデータ要求: "GET /<mount> HTTP/1.x\r\n..."
    client_get: ClientGet,
    /// Sourcetable 要求: "GET / HTTP/1.x\r\n..."
    sourcetable_get: SourcetableGet,
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

/// "Connection" ヘッダー値が keep-alive を要求しているか判定。
/// V1.1 既定は keep-alive だが、明示指定のみ true とする（保守的）。
fn isKeepAlive(header: []const u8) bool {
    const conn = getHeader(header, "Connection") orelse return false;
    return std.ascii.indexOfIgnoreCase(conn, "keep-alive") != null;
}

/// "Ntrip-Version" ヘッダーで v2 か判定。値の中身は問わずヘッダー存在のみで判定。
fn detectV2(header: []const u8) bool {
    return getHeader(header, "Ntrip-Version") != null;
}

/// "Expect: 100-continue" ヘッダー存在判定。
fn expectsContinue(header: []const u8) bool {
    const e = getHeader(header, "Expect") orelse return false;
    return std.ascii.indexOfIgnoreCase(e, "100-continue") != null;
}

/// "SOURCE <password> /<mount>\r\n..." (NTRIP v1) をパースする。
fn parseSourceLoginV1(header: []const u8) ?SourceLogin {
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
        .mount = mount,
        .password = password,
        .auth_header = null,
        .agent = getHeader(header, "Source-Agent"),
        .is_v2 = false,
        .expects_100 = false,
    };
}

/// "POST /<mount> HTTP/1.1\r\nNtrip-Version: ...\r\n..." (NTRIP v2) をパースする。
fn parseSourceLoginV2(header: []const u8) ?SourceLogin {
    const line_end = std.mem.indexOfScalar(u8, header, '\n') orelse return null;
    const first_line = std.mem.trimRight(u8, header[0..line_end], " \r");

    // "POST " は 5 文字
    if (first_line.len < 6) return null;
    const after_post = first_line[5..];

    // パスと HTTP バージョンを分割
    const path_end = std.mem.indexOfScalar(u8, after_post, ' ') orelse return null;
    const path = after_post[0..path_end];
    if (path.len == 0 or path[0] != '/') return null;

    // V2 は Ntrip-Version 必須（無ければ生 HTTP POST として拒否）
    if (!detectV2(header)) return null;

    // Source-Agent 優先、無ければ User-Agent
    const agent = getHeader(header, "Source-Agent") orelse getHeader(header, "User-Agent");

    return .{
        .mount = path,
        .password = "",
        .auth_header = getHeader(header, "Authorization"),
        .agent = agent,
        .is_v2 = true,
        .expects_100 = expectsContinue(header),
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

    const is_v2 = detectV2(header);
    const keep_alive = isKeepAlive(header);

    // sourcetable 要求: パスが "/" のみ
    if (std.mem.eql(u8, path, "/")) {
        return .{ .sourcetable_get = .{ .is_v2 = is_v2, .keep_alive = keep_alive } };
    }

    // クライアントデータ要求
    return .{
        .client_get = .{
            .mount = path,
            .auth_header = getHeader(header, "Authorization"),
            .user_agent = getHeader(header, "User-Agent"),
            .is_v2 = is_v2,
            .keep_alive = keep_alive,
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
        return if (parseSourceLoginV1(header)) |sl|
            .{ .source_login = sl }
        else
            .{ .invalid = header };
    }
    if (std.mem.startsWith(u8, header, "POST ")) {
        return if (parseSourceLoginV2(header)) |sl|
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
