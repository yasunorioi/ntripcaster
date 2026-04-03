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

/// FKP ソース局設定
pub const FkpSource = struct {
    host: []const u8,
    port: u16 = 2101,
    mountpoint: []const u8,
    user: []const u8 = "",
    password: []const u8 = "",
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

    // ── FKP 設定 ──────────────────────────────────────────────────────────
    /// true = FKP 機能を有効にする（fkp_enable true）
    fkp_enable: bool = false,
    /// FKP ソース局リスト。3局以上の場合に FKP 計算を有効化する。
    fkp_sources: []FkpSource = &.{},
    /// FKP 補正値を配信するマウントポイント（空文字列 = FKP 無効）
    fkp_mountpoint: []const u8 = "",
    /// FKP 計算間隔 [秒]
    fkp_interval: u32 = 1,

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

/// fkp_source 値部分をパースして FkpSource を返す。
///
/// フォーマット: "host/mount [user:password]"
///               "host:port/mount [user:password]"
///
/// 例:
///   "rtk2go.com/nakagawa00"                      → host, port=2101, mount
///   "rtk2go.com:2101/nakagawa00"                 → host, port=2101, mount
///   "rtk2go.com/nakagawa00 user@example.com:pw"  → with auth
fn parseFkpSource(
    allocator: std.mem.Allocator,
    value: []const u8,
) ParseError!FkpSource {
    // 最初のスペースで addr_part と opt_auth に分割
    const sp = std.mem.indexOfAny(u8, value, " \t");
    const addr_part = if (sp) |s| value[0..s] else value;
    const opt_auth = if (sp) |s| std.mem.trimLeft(u8, value[s..], " \t") else "";

    // addr_part を "/" で分割 → host_port / mount
    const slash = std.mem.indexOfScalar(u8, addr_part, '/') orelse
        return error.InvalidMountLine;
    const host_port_str = addr_part[0..slash];
    const mount = try allocator.dupe(u8, addr_part[slash + 1 ..]);

    // host_port_str を ":" で分割 → host / port
    var host: []const u8 = undefined;
    var port: u16 = 2101;
    if (std.mem.indexOfScalar(u8, host_port_str, ':')) |cp| {
        host = try allocator.dupe(u8, host_port_str[0..cp]);
        port = std.fmt.parseInt(u16, host_port_str[cp + 1 ..], 10) catch
            return error.InvalidPort;
    } else {
        host = try allocator.dupe(u8, host_port_str);
    }

    // opt_auth が空でなければ ":" で最初の分割 → user / password
    var user: []const u8 = "";
    var password: []const u8 = "";
    if (opt_auth.len > 0) {
        const cp = std.mem.indexOfScalar(u8, opt_auth, ':') orelse
            return error.InvalidCredential;
        user = try allocator.dupe(u8, opt_auth[0..cp]);
        password = try allocator.dupe(u8, opt_auth[cp + 1 ..]);
    }

    return .{
        .host = host,
        .port = port,
        .mountpoint = mount,
        .user = user,
        .password = password,
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

    var fkp_src_list = std.ArrayList(FkpSource){};

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
        } else if (std.mem.eql(u8, key, "fkp_enable")) {
            config.fkp_enable = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "fkp_source")) {
            const src = try parseFkpSource(allocator, value);
            try fkp_src_list.append(allocator, src);
        } else if (std.mem.eql(u8, key, "fkp_mountpoint")) {
            config.fkp_mountpoint = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "fkp_interval")) {
            config.fkp_interval = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
        }
        // 未知のキーは無視（前方互換性）
    }

    config.fkp_sources = try fkp_src_list.toOwnedSlice(allocator);
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
