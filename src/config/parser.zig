//! config/parser.zig — ntripcaster.conf パーサー
//!
//! 原典 ntripcaster.conf 形式を 100% 後方互換でパース。
//! フォーマット仕様:
//!   - `#` で始まる行はコメント（行末コメント不可）
//!   - 空行は無視
//!   - `key value` — 最初のスペースで key / value を分割
//!   - `/MOUNT:user1:pass1,user2:pass2` — マウント認証行
//!   - `/MOUNT` — オープンマウント（認証不要）
//!
//! メモリ: 全文字列は呼び出し元の `allocator` から確保する。
//! ArenaAllocator を推奨。Config.deinit() で HashMap を解放。

const std = @import("std");

// ── 型定義 ────────────────────────────────────────────────────────────────────

/// マウントに対するユーザー単位の認証情報
pub const User = struct {
    name: []const u8,
    password: []const u8,
};

/// マウントポイントの認証設定
pub const MountAuth = struct {
    /// true = 認証不要（オープンマウント）
    open: bool,
    /// 認証ユーザーリスト（open=true 時は空）
    users: []User,
};

/// サーバー設定構造体
/// 全 []const u8 フィールドは allocator から確保されたメモリを指す。
pub const Config = struct {
    // ── ネットワーク ──────────────────────────────────────────────────────
    port: u16 = 2101,
    server_name: []const u8 = "localhost",

    // ── 接続上限 ──────────────────────────────────────────────────────────
    max_clients: u32 = 100,
    max_clients_per_source: u32 = 100,
    max_sources: u32 = 40,

    // ── 認証 ──────────────────────────────────────────────────────────────
    encoder_password: []const u8 = "sesam01",

    // ── ログ ──────────────────────────────────────────────────────────────
    logdir: []const u8 = "logs",
    logfile: []const u8 = "ntripcaster.log",

    // ── メタ情報（機能に影響しない） ──────────────────────────────────────
    location: []const u8 = "",
    rp_email: []const u8 = "",
    server_url: []const u8 = "",

    // ── マウント認証テーブル ──────────────────────────────────────────────
    /// キー: マウントパス（"/" で始まる）、値: MountAuth
    mounts: std.StringHashMap(MountAuth),

    /// HashMap を解放する。文字列値の解放は呼び出し元の Arena に委ねる。
    pub fn deinit(self: *Config) void {
        self.mounts.deinit();
    }
};

// ── パースエラー ──────────────────────────────────────────────────────────────

pub const ParseError = error{
    InvalidPort,
    InvalidInteger,
    InvalidMountLine,
    InvalidCredential,
} || std.mem.Allocator.Error;

// ── 内部ヘルパー ──────────────────────────────────────────────────────────────

/// 行頭・行末のスペース/タブを除去して返す。
fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

/// マウント認証行をパースする。
/// 例: "/BUCU0:user1:pass1,user2:pass2" → mount="/BUCU0", 2 users
///      "/PADO0"                         → mount="/PADO0", open
fn parseMountLine(
    allocator: std.mem.Allocator,
    line: []const u8,
) ParseError!struct { mount: []const u8, auth: MountAuth } {
    std.debug.assert(line.len > 0 and line[0] == '/');

    // マウントパスと認証部を ":" で分割
    const colon_pos = std.mem.indexOfScalar(u8, line, ':');

    if (colon_pos == null) {
        // オープンマウント（認証なし）
        const mount = try allocator.dupe(u8, line);
        return .{
            .mount = mount,
            .auth = .{ .open = true, .users = &.{} },
        };
    }

    const mount = try allocator.dupe(u8, line[0..colon_pos.?]);
    const users_str = line[colon_pos.? + 1 ..];

    // ユーザーリストを "," で分割し各 "user:pass" をパース
    var users = std.ArrayList(User){};
    var cred_iter = std.mem.splitScalar(u8, users_str, ',');
    while (cred_iter.next()) |cred| {
        const cred_trimmed = std.mem.trim(u8, cred, " \t");
        if (cred_trimmed.len == 0) continue;

        const sep = std.mem.indexOfScalar(u8, cred_trimmed, ':') orelse
            return error.InvalidCredential;

        const user_name = try allocator.dupe(u8, cred_trimmed[0..sep]);
        const user_pass = try allocator.dupe(u8, cred_trimmed[sep + 1 ..]);
        try users.append(allocator, .{ .name = user_name, .password = user_pass });
    }

    return .{
        .mount = mount,
        .auth = .{
            .open = false,
            .users = try users.toOwnedSlice(allocator),
        },
    };
}

// ── 公開 API ──────────────────────────────────────────────────────────────────

/// ntripcaster.conf のファイル内容 `content` をパースして Config を返す。
///
/// 全文字列は `allocator` から確保。ArenaAllocator を推奨。
/// Config.deinit() を呼ぶことで HashMap を解放する。
pub fn parse(allocator: std.mem.Allocator, content: []const u8) ParseError!Config {
    var config = Config{
        .mounts = std.StringHashMap(MountAuth).init(allocator),
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);

        // 空行・コメント行スキップ
        if (line.len == 0 or line[0] == '#') continue;

        // マウント認証行
        if (line[0] == '/') {
            const result = try parseMountLine(allocator, line);
            try config.mounts.put(result.mount, result.auth);
            continue;
        }

        // キーバリュー行: 最初のスペース/タブで分割
        const sep_pos = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const key = line[0..sep_pos];
        const value = std.mem.trimLeft(u8, line[sep_pos..], " \t");
        if (value.len == 0) continue;

        if (std.mem.eql(u8, key, "port")) {
            config.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, key, "max_clients")) {
            config.max_clients = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "max_clients_per_source")) {
            config.max_clients_per_source = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "max_sources")) {
            config.max_sources = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "encoder_password")) {
            config.encoder_password = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "server_name")) {
            config.server_name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "logdir")) {
            config.logdir = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "logfile")) {
            config.logfile = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "location")) {
            config.location = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "rp_email")) {
            config.rp_email = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "server_url")) {
            config.server_url = try allocator.dupe(u8, value);
        }
        // 未知のキーは無視（前方互換性）
    }

    return config;
}

/// ファイルパスから直接パースする便利関数。
/// `max_bytes` を超えるファイルは error.FileTooBig を返す。
pub fn parseFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) (ParseError || std.fs.File.OpenError || error{FileTooBig})!Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const content = try std.fs.cwd().readFileAlloc(arena.allocator(), path, max_bytes);
    // content はここで arena に所有される。parseした後の文字列は
    // config の allocator(=arena) 内の dupe で確保されるため問題なし。
    const config = try parse(allocator, content);
    // content はもう不要だが arena を解放すると dupe 前の文字列が消える。
    // parse 内では全値を dupe しているので arena は解放してよい。
    arena.deinit();
    return config;
}
