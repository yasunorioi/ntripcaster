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

/// マウント未登録時の client アクセス既定挙動
/// - .deny: config に `/MOUNT` 行が無い mount への GET は 401 で蹴る (BKG 既定動作)
/// - .open: config に `/MOUNT` 行が無い mount でも GET 許可 (source が push してれば誰でも読める)
///
/// `/MOUNT` や `/MOUNT:user:pass` で明示された mount はこの設定に関わらず
/// 該当行の設定に従う。
pub const MountAccess = enum { deny, open };

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

    // ── Sourcetable CAS レコード（自動生成） ──────────────────────────────
    /// CAS 行 host フィールド (空なら server_name を使う)
    caster_host: []const u8 = "",
    caster_identifier: []const u8 = "NtripCaster",
    caster_operator: []const u8 = "",
    /// NMEA: 0 = caster は NMEA を要求しない / 1 = 要求する
    caster_nmea: u8 = 0,
    /// 3 文字 ISO 国コード（例: "JPN", "DEU"）
    caster_country: []const u8 = "",
    caster_latitude: f64 = 0.0,
    caster_longitude: f64 = 0.0,
    caster_fallback_host: []const u8 = "",
    caster_fallback_port: u16 = 0,
    caster_misc: []const u8 = "",

    // ── Sourcetable NET レコード（任意・自動生成） ────────────────────────
    /// NET 行を sourcetable に含めるか（network_identifier が空でない場合に有効）
    network_identifier: []const u8 = "",
    network_operator: []const u8 = "",
    /// "B" = Basic, "D" = Digest, "N" = none
    network_auth: []const u8 = "N",
    /// "Y" = fee, "N" = free
    network_fee: []const u8 = "N",
    network_web_net: []const u8 = "",
    network_web_str: []const u8 = "",
    network_web_reg: []const u8 = "",
    network_misc: []const u8 = "",

    // ── マウント認証テーブル ──────────────────────────────────────────────
    /// キー: マウントパス（"/" で始まる）、値: MountAuth
    mounts: std.StringHashMap(MountAuth),
    /// `mounts` に登録のない mount への client GET 時の既定挙動
    default_mount_access: MountAccess = .deny,

    // ── 管理 (admin) HTTP ────────────────────────────────────────────────
    /// 観測 UI / JSON API を提供する HTTP リスナーを起動するか
    admin_enable: bool = true,
    /// admin リスナーのバインドアドレス（既定: ループバックのみ）
    admin_bind: []const u8 = "127.0.0.1",
    /// admin リスナーのポート
    admin_port: u16 = 8080,
    /// Basic 認証ユーザー（空文字列 = 認証無効。bind を 0.0.0.0 にする場合は必ず設定する）
    admin_user: []const u8 = "",
    /// Basic 認証パスワード
    admin_password: []const u8 = "",

    // ── FKP 設定 ──────────────────────────────────────────────────────────
    /// true = FKP 機能を有効にする（fkp_enable true）
    fkp_enable: bool = false,
    /// FKP ソース局リスト。3局以上の場合に FKP 計算を有効化する。
    fkp_sources: []FkpSource = &.{},
    /// FKP 補正値を配信するマウントポイント（空文字列 = FKP 無効）
    fkp_mountpoint: []const u8 = "",
    /// FKP 計算間隔 [秒]
    fkp_interval: u32 = 1,
    /// 上流接続時に送る合成 GGA の緯度 [deg]。
    /// rtk2go.com のように NMEA=1 (GGA 必須) マウントに繋ぐ場合のみ意味を持つ。
    /// 0.0 のとき送信しない。VRS ではなく FKP 用途なので「網セル中心付近」を入れれば良い。
    fkp_gga_lat: f64 = 0.0,
    /// 上流接続時に送る合成 GGA の経度 [deg]
    fkp_gga_lon: f64 = 0.0,

    // ── VRS 設定 ──────────────────────────────────────────────────────────
    /// true = VRS 機能を有効にする (要 fkp_enable も true)
    vrs_enable: bool = false,
    /// rover に公開する VRS mountpoint 名 (例: "/VRS_AUTO")
    vrs_mountpoint: []const u8 = "",
    /// セル中心緯度 [deg]。rover がこの点から radius_km 以上離れたら切断。
    /// 0.0 のとき距離チェック無効。
    vrs_cell_center_lat: f64 = 0.0,
    vrs_cell_center_lon: f64 = 0.0,
    /// セル半径 [km] (距離チェック)
    vrs_cell_radius_km: f64 = 50.0,
    /// rover が初回 GGA を送るまでの待機時間 [秒]
    vrs_initial_gga_timeout_sec: u32 = 60,
    /// 仮想 Type 1005 を rover に注入する間隔 [秒]
    vrs_inject_1005_interval_sec: u32 = 5,

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
    var users = std.ArrayList(User).empty;
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
///   "ntrip.hogehoge.com/BASE01"                      → host, port=2101, mount
///   "ntrip.hogehoge.com:2101/BASE01"                 → host, port=2101, mount
///   "ntrip.hogehoge.com/BASE01 user@example.com:pw"  → with auth
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

    var fkp_src_list = std.ArrayList(FkpSource).empty;

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
        } else if (std.mem.eql(u8, key, "default_mount_access")) {
            if (std.mem.eql(u8, value, "open")) {
                config.default_mount_access = .open;
            } else if (std.mem.eql(u8, value, "deny")) {
                config.default_mount_access = .deny;
            } else {
                std.log.warn(
                    "unknown default_mount_access value '{s}' (expected 'open' or 'deny'); keeping default",
                    .{value},
                );
            }
        } else if (std.mem.eql(u8, key, "caster_host")) {
            config.caster_host = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "caster_identifier")) {
            config.caster_identifier = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "caster_operator")) {
            config.caster_operator = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "caster_nmea")) {
            config.caster_nmea = std.fmt.parseInt(u8, value, 10) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "caster_country")) {
            config.caster_country = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "caster_latitude")) {
            config.caster_latitude = std.fmt.parseFloat(f64, value) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "caster_longitude")) {
            config.caster_longitude = std.fmt.parseFloat(f64, value) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "caster_fallback_host")) {
            config.caster_fallback_host = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "caster_fallback_port")) {
            config.caster_fallback_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, key, "caster_misc")) {
            config.caster_misc = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "network_identifier")) {
            config.network_identifier = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "network_operator")) {
            config.network_operator = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "network_auth")) {
            config.network_auth = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "network_fee")) {
            config.network_fee = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "network_web_net")) {
            config.network_web_net = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "network_web_str")) {
            config.network_web_str = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "network_web_reg")) {
            config.network_web_reg = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "network_misc")) {
            config.network_misc = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "admin_enable")) {
            config.admin_enable = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "admin_bind")) {
            config.admin_bind = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "admin_port")) {
            config.admin_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, key, "admin_user")) {
            config.admin_user = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "admin_password")) {
            config.admin_password = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "fkp_enable")) {
            config.fkp_enable = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "fkp_source")) {
            const src = try parseFkpSource(allocator, value);
            try fkp_src_list.append(allocator, src);
        } else if (std.mem.eql(u8, key, "fkp_mountpoint")) {
            config.fkp_mountpoint = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "fkp_interval")) {
            config.fkp_interval = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "fkp_gga_lat")) {
            config.fkp_gga_lat = std.fmt.parseFloat(f64, value) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "fkp_gga_lon")) {
            config.fkp_gga_lon = std.fmt.parseFloat(f64, value) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "vrs_enable")) {
            config.vrs_enable = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "vrs_mountpoint")) {
            config.vrs_mountpoint = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "vrs_cell_center_lat")) {
            config.vrs_cell_center_lat = std.fmt.parseFloat(f64, value) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "vrs_cell_center_lon")) {
            config.vrs_cell_center_lon = std.fmt.parseFloat(f64, value) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "vrs_cell_radius_km")) {
            config.vrs_cell_radius_km = std.fmt.parseFloat(f64, value) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "vrs_initial_gga_timeout_sec")) {
            config.vrs_initial_gga_timeout_sec = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
        } else if (std.mem.eql(u8, key, "vrs_inject_1005_interval_sec")) {
            config.vrs_inject_1005_interval_sec = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
        }
        // 未知のキーは無視（前方互換性）
    }

    config.fkp_sources = try fkp_src_list.toOwnedSlice(allocator);

    // fkp_enable true なのに局数が不足（< 3）している場合は警告
    if (config.fkp_enable and config.fkp_sources.len < 3) {
        std.log.warn(
            "fkp_enable is true but only {d} fkp_source(s) defined (need >= 3); FKP will be inactive",
            .{config.fkp_sources.len},
        );
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
