//! src/fkp/upstream.zig — 単一上流 NTRIP クライアント (FKP runtime 用)
//!
//! 1 つの NTRIP caster に rover として GET 接続し、RTCM3 ストリームを継続的に
//! 受信する。受信中に:
//!   - 1005 / 1006 を見つけたら基準局座標を保存
//!   - 1077 / 1087 / 1097 (MSM7) を見つけたら搬送波位相観測値を蓄積
//!   - 任意のパススルー callback があれば、受信生バイトを丸ごと渡す
//!     (主上流の生 RTCM3 を仮想 mountpoint に流すために使う)
//!
//! 切断時は指数バックオフで再接続する。`stop()` で終了。

const std = @import("std");
const io = @import("../io.zig");
const os = @import("../os.zig");
const msm7 = @import("msm7.zig");
const ephemeris = @import("ephemeris.zig");
const rtcm3 = @import("../ntrip/rtcm3.zig");
const log_mod = @import("../log.zig");

/// 設定
pub const Config = struct {
    host: []const u8,
    port: u16 = 2101,
    mount: []const u8,
    user: []const u8 = "",
    pass: []const u8 = "",
    /// 接続失敗時の初回バックオフ
    initial_backoff_ms: u64 = 2 * std.time.ms_per_s,
    /// 上限バックオフ
    max_backoff_ms: u64 = 60 * std.time.ms_per_s,
    /// データ無音タイムアウト (これを超えると切断扱い)
    data_timeout_ms: u64 = 30 * std.time.ms_per_s,
    /// GET 直後に送る合成 GGA の緯度 [deg]。0.0 のとき送信しない。
    /// rtk2go.com のように NMEA=1 (GGA 必須) マウントに繋ぐとき使う。
    gga_lat_deg: f64 = 0.0,
    /// GGA の経度 [deg]。0.0 のとき送信しない。
    gga_lon_deg: f64 = 0.0,
};

/// 上流から渡されたスナップショット。`takeSnapshot()` で取り出す。
/// `phase_list` は caller-allocated。read 後に caller が free する。
pub const Snapshot = struct {
    coord: ?msm7.StationCoord,
    /// 「フレッシュな」観測値リスト ((prn,band) ごとに最新、age 上限内)。
    phase_list: []msm7.PhaseObs,
};

/// 観測値エントリ。タイムスタンプ付きで保管し、古くなったら snapshot から除外する。
const ObsEntry = struct {
    obs: msm7.PhaseObs,
    ts_ms: i64,
};

/// (prn, band) を 1 つの u16 キーにエンコードする。
fn obsKey(prn: u8, band: msm7.Band) u16 {
    return (@as(u16, prn) << 8) | @intFromEnum(band);
}

/// パススルー callback: raw RTCM3 バイトをそのまま転送する。
/// 主上流のみで使う (仮想 mountpoint への注入)。
pub const PassthroughFn = *const fn (ctx: *anyopaque, data: []const u8) void;

pub const Upstream = struct {
    alloc: std.mem.Allocator,
    cfg: Config,
    logger: log_mod.Logger,

    /// 蓄積バッファ (lock で保護)
    lock: os.Mutex,
    coord: ?msm7.StationCoord,
    /// (prn, band) → 最新観測。新着で上書き、古いエントリは snapshot 時に除外。
    /// ArrayList ではなく Map にすることで「station A のみ更新が遅い」レースを回避。
    phase_map: std.AutoHashMapUnmanaged(u16, ObsEntry),
    /// Phase 7-1: GPS Type 1019 から取り出した broadcast ephemeris の保管。
    /// 各上流からの最新 eph を PRN 別に保持。Phase 7-2 以降で衛星 ECEF 計算に使う。
    /// `lock` で保護 (phase_map と共有)。
    eph_store: ephemeris.EphemerisStore,

    /// snapshot に含める観測値の age 上限 [ms]。これより古いエントリは「死んでる」扱い。
    /// 通常 MSM7 は 1 秒間隔で来るので、10 秒もあれば過剰に余裕。
    max_obs_age_ms: i64 = 10 * std.time.ms_per_s,

    /// 受信ライフサイクル
    active: std.atomic.Value(bool),
    last_data_at_ms: i64,

    /// パススルー設定 (主上流のみ非 null)
    passthrough_ctx: ?*anyopaque,
    passthrough_fn: ?PassthroughFn,

    /// スレッド (start() で spawn、stop()/join() で終了)
    thread: ?os.Thread,

    pub fn create(alloc: std.mem.Allocator, cfg: Config, logger: log_mod.Logger) !*Upstream {
        const u = try alloc.create(Upstream);
        u.* = .{
            .alloc = alloc,
            .cfg = .{
                .host = try alloc.dupe(u8, cfg.host),
                .port = cfg.port,
                .mount = try alloc.dupe(u8, cfg.mount),
                .user = try alloc.dupe(u8, cfg.user),
                .pass = try alloc.dupe(u8, cfg.pass),
                .initial_backoff_ms = cfg.initial_backoff_ms,
                .max_backoff_ms = cfg.max_backoff_ms,
                .data_timeout_ms = cfg.data_timeout_ms,
                .gga_lat_deg = cfg.gga_lat_deg,
                .gga_lon_deg = cfg.gga_lon_deg,
            },
            .logger = logger,
            .lock = .{},
            .coord = null,
            .phase_map = .{},
            .eph_store = ephemeris.EphemerisStore.init(alloc),
            .max_obs_age_ms = 10 * std.time.ms_per_s,
            .active = std.atomic.Value(bool).init(true),
            .last_data_at_ms = std.time.milliTimestamp(),
            .passthrough_ctx = null,
            .passthrough_fn = null,
            .thread = null,
        };
        return u;
    }

    pub fn destroy(self: *Upstream) void {
        self.lock.lock();
        self.phase_map.deinit(self.alloc);
        self.eph_store.deinit();
        self.lock.unlock();
        self.alloc.free(self.cfg.host);
        self.alloc.free(self.cfg.mount);
        self.alloc.free(self.cfg.user);
        self.alloc.free(self.cfg.pass);
        self.alloc.destroy(self);
    }

    pub fn setPassthrough(self: *Upstream, ctx: *anyopaque, cb: PassthroughFn) void {
        self.passthrough_ctx = ctx;
        self.passthrough_fn = cb;
    }

    /// バックグラウンドスレッド開始
    pub fn start(self: *Upstream) !void {
        self.thread = try os.Thread.spawn(.{}, runLoop, .{self});
    }

    /// 終了通知 + join (呼び出し側スレッドをブロックする)
    pub fn stop(self: *Upstream) void {
        self.active.store(false, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// 「フレッシュな」観測値の owned コピーを返す。内部はクリアせず、新着で
    /// 自動的に上書きされる。age 上限を超えたエントリは結果に含めない (が、map
    /// からの GC は次の挿入時に任せる)。caller が phase_list を free する。
    pub fn takeSnapshot(self: *Upstream, alloc: std.mem.Allocator) !Snapshot {
        self.lock.lock();
        defer self.lock.unlock();

        const now = std.time.milliTimestamp();
        const cutoff = now - self.max_obs_age_ms;

        // フレッシュなエントリを数える
        var fresh: usize = 0;
        var it = self.phase_map.valueIterator();
        while (it.next()) |v| {
            if (v.ts_ms >= cutoff) fresh += 1;
        }

        const out_list = try alloc.alloc(msm7.PhaseObs, fresh);
        var i: usize = 0;
        var it2 = self.phase_map.valueIterator();
        while (it2.next()) |v| {
            if (v.ts_ms >= cutoff) {
                out_list[i] = v.obs;
                i += 1;
            }
        }

        return .{
            .coord = self.coord,
            .phase_list = out_list,
        };
    }

    /// 直近受信からの経過 ms (新しさのチェック用)
    pub fn millisSinceLastData(self: *Upstream) i64 {
        self.lock.lock();
        defer self.lock.unlock();
        return std.time.milliTimestamp() - self.last_data_at_ms;
    }
};

// ── 内部 ──────────────────────────────────────────────────────────────────

fn runLoop(self: *Upstream) void {
    var backoff_ms: u64 = 0;

    while (self.active.load(.seq_cst)) {
        // 接続
        const stream = connect(self) catch |err| {
            self.logger.warn(
                "[upstream {s}] connect failed: {}, backoff {d}ms",
                .{ self.cfg.mount, err, @max(backoff_ms, self.cfg.initial_backoff_ms) },
            );
            backoff_ms = nextBackoff(backoff_ms, self.cfg);
            sleepInterruptible(self, backoff_ms);
            continue;
        };
        defer stream.close();

        self.logger.info("[upstream {s}] connected to {s}:{d}", .{
            self.cfg.mount, self.cfg.host, self.cfg.port,
        });
        backoff_ms = 0;
        self.lock.lock();
        self.last_data_at_ms = std.time.milliTimestamp();
        self.lock.unlock();

        // 受信ループ
        readLoop(self, stream);

        self.logger.warn("[upstream {s}] disconnected", .{self.cfg.mount});
        backoff_ms = nextBackoff(backoff_ms, self.cfg);
        sleepInterruptible(self, backoff_ms);
    }
}

fn nextBackoff(prev_ms: u64, cfg: Config) u64 {
    if (prev_ms == 0) return cfg.initial_backoff_ms;
    const doubled = prev_ms *| 2;
    return @min(doubled, cfg.max_backoff_ms);
}

/// `active=false` を尊重しながら最大 ms 待機 (細かいスリープに分割)
fn sleepInterruptible(self: *Upstream, ms: u64) void {
    var remaining: u64 = ms;
    const tick: u64 = 100;
    while (remaining > 0 and self.active.load(.seq_cst)) {
        const this_sleep: u64 = @min(remaining, tick);
        os.sleep(this_sleep * @as(u64, std.time.ns_per_ms));
        remaining -= this_sleep;
    }
}

/// socket に SO_RCVTIMEO を設定する。secs == 0 で無効化。backend 差は
/// io.setRecvTimeoutMs が吸収する。
fn setRecvTimeout(stream: io.Stream, secs: u32) void {
    io.setRecvTimeoutMs(stream.handle, secs * 1000);
}

/// NTRIP caster に GET 接続 → ICY 200 OK 確認まで
fn connect(self: *Upstream) !io.Stream {
    const stream = try io.tcpConnectToHost(self.alloc, self.cfg.host, self.cfg.port);
    errdefer stream.close();

    // ICY 待ち中に上流が応答しないと無限ハングするので、接続フェーズだけ短い
    // read timeout を入れる (15 秒)。読み始めたら無音検出は data_timeout_ms に任せる。
    setRecvTimeout(stream, 15);

    // GET リクエスト送信
    try sendGet(self, stream);

    // ICY 200 OK を待つ
    try waitIcy(stream);

    // NMEA=1 マウント (rtk2go 等) は GGA 受信まで RTCM3 を流さないので、
    // gga_lat/gga_lon が指定されているときは合成 GGA を送る。
    if (self.cfg.gga_lat_deg != 0.0 or self.cfg.gga_lon_deg != 0.0) {
        sendGga(self, stream) catch |err| {
            self.logger.warn("[upstream {s}] GGA send failed: {}", .{ self.cfg.mount, err });
        };
    }

    // 読み込みフェーズに入ったら timeout を長めに (ストール検知は data_timeout_ms で別途)
    setRecvTimeout(stream, @intCast(self.cfg.data_timeout_ms / 1000 + 5));

    return stream;
}

/// 合成 NMEA GGA を送信する (rtk2go の NMEA=1 マウントを「開ける」ための嘘 GGA)。
fn sendGga(self: *Upstream, stream: io.Stream) !void {
    var buf: [128]u8 = undefined;
    const sentence = formatGga(&buf, self.cfg.gga_lat_deg, self.cfg.gga_lon_deg) orelse return;
    try stream.writeAll(sentence);
    self.logger.info("[upstream {s}] sent GGA (lat={d:.4} lon={d:.4})", .{
        self.cfg.mount, self.cfg.gga_lat_deg, self.cfg.gga_lon_deg,
    });
}

/// `$GPGGA,...*XX\r\n` を組み立てる。返り値は buf 内のスライス。
/// 失敗時 (buf 不足) は null。
fn formatGga(buf: []u8, lat_deg: f64, lon_deg: f64) ?[]const u8 {
    // ddmm.mmmm 形式に変換
    const lat_abs = @abs(lat_deg);
    const lat_deg_i: u32 = @intFromFloat(@floor(lat_abs));
    const lat_min: f64 = (lat_abs - @as(f64, @floatFromInt(lat_deg_i))) * 60.0;
    const lat_ns: u8 = if (lat_deg >= 0) 'N' else 'S';

    const lon_abs = @abs(lon_deg);
    const lon_deg_i: u32 = @intFromFloat(@floor(lon_abs));
    const lon_min: f64 = (lon_abs - @as(f64, @floatFromInt(lon_deg_i))) * 60.0;
    const lon_ew: u8 = if (lon_deg >= 0) 'E' else 'W';

    // チェックサム前まで組み立て
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // GGA ペイロード ($ と *xx 以外を生成してチェックサム計算)
    const payload_start: usize = 1;  // '$' の後
    w.writeByte('$') catch return null;
    std.fmt.format(w, "GPGGA,000000.00,{d:0>2}{d:07.4},{c},{d:0>3}{d:07.4},{c},1,08,0.9,0.0,M,46.9,M,,", .{
        lat_deg_i, lat_min, lat_ns, lon_deg_i, lon_min, lon_ew,
    }) catch return null;

    const pos_before_star = fbs.pos;

    // XOR チェックサム ($ と * の間)
    var cs: u8 = 0;
    for (buf[payload_start..pos_before_star]) |b| cs ^= b;

    std.fmt.format(w, "*{X:0>2}\r\n", .{cs}) catch return null;
    return buf[0..fbs.pos];
}

fn sendGet(self: *Upstream, stream: io.Stream) !void {
    var req_buf: [768]u8 = undefined;

    if (self.cfg.user.len > 0) {
        // Basic 認証
        const cred_fmt = try std.fmt.allocPrint(
            self.alloc,
            "{s}:{s}",
            .{ self.cfg.user, self.cfg.pass },
        );
        defer self.alloc.free(cred_fmt);

        const encoder = std.base64.standard.Encoder;
        var auth_b64: [256]u8 = undefined;
        const encoded_len = encoder.calcSize(cred_fmt.len);
        if (encoded_len > auth_b64.len) return error.AuthTooLong;
        _ = encoder.encode(auth_b64[0..encoded_len], cred_fmt);

        const req = try std.fmt.bufPrint(
            &req_buf,
            "GET /{s} HTTP/1.0\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Ntrip-Version: Ntrip/1.0\r\n" ++
                "User-Agent: NTRIP NtripCasterFkp/0.3\r\n" ++
                "Authorization: Basic {s}\r\n" ++
                "\r\n",
            .{ self.cfg.mount, self.cfg.host, self.cfg.port, auth_b64[0..encoded_len] },
        );
        try stream.writeAll(req);
    } else {
        const req = try std.fmt.bufPrint(
            &req_buf,
            "GET /{s} HTTP/1.0\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Ntrip-Version: Ntrip/1.0\r\n" ++
                "User-Agent: NTRIP NtripCasterFkp/0.3\r\n" ++
                "\r\n",
            .{ self.cfg.mount, self.cfg.host, self.cfg.port },
        );
        try stream.writeAll(req);
    }
}

fn waitIcy(stream: io.Stream) !void {
    var buf: [256]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.UpstreamClosed;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "ICY 200 OK") != null) return;
        // HTTP/1.0 200 OK も許容 (一部 caster は HTTP/1.x で応答)
        if (std.mem.indexOf(u8, buf[0..total], "HTTP/1.0 200") != null) return;
        if (std.mem.indexOf(u8, buf[0..total], "HTTP/1.1 200") != null) return;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) return error.NotIcy200;
    }
    return error.NotIcy200;
}

/// 受信生バイトを取り込み、パススルー callback と RTCM3 パーサーに投入する。
fn readLoop(self: *Upstream, stream: io.Stream) void {
    var read_buf: [4096]u8 = undefined;
    // RTCM3 パース用バッファ (チャンク跨ぎ対応)
    var parse_buf: [8192]u8 = undefined;
    var parse_len: usize = 0;

    while (self.active.load(.seq_cst)) {
        const n = stream.read(&read_buf) catch break;
        if (n == 0) break; // 接続閉鎖

        const chunk = read_buf[0..n];

        // パススルー (主上流のみ)
        if (self.passthrough_fn) |cb| {
            cb(self.passthrough_ctx.?, chunk);
        }

        // 受信時刻更新
        self.lock.lock();
        self.last_data_at_ms = std.time.milliTimestamp();
        self.lock.unlock();

        // RTCM3 パース用バッファに追記 (溢れたら先頭を破棄)
        if (parse_len + chunk.len > parse_buf.len) {
            const carry = parse_buf.len / 2;
            std.mem.copyForwards(u8, parse_buf[0..carry], parse_buf[parse_len - carry .. parse_len]);
            parse_len = carry;
        }
        @memcpy(parse_buf[parse_len .. parse_len + chunk.len], chunk);
        parse_len += chunk.len;

        // フレームスキャン → 1005/1006/1077/1087/1097 を処理
        //
        // 重要: parseFrame には必ず valid range の `parse_buf[pos..parse_len]`
        // を渡す。`parse_buf[pos..]` だと parse_buf.len (= 8192) まで見えてしまい
        // stale data 上で偶然 CRC が一致すると `consumed > parse_len - pos` の
        // 成功を返し、`pos += consumed` で pos > parse_len 状態になって後段の
        // shift で usize underflow → SIGSEGV。
        // (Phase 4 既知問題「長時間運用で SIGSEGV」の根本原因。assertion
        //  diag-B で実証済み、tests/test_fkp.zig に regression 追加)
        var pos: usize = 0;
        while (pos < parse_len) {
            if (parse_buf[pos] != rtcm3.PREAMBLE) {
                pos += 1;
                continue;
            }
            const fr = rtcm3.parseFrame(parse_buf[pos..parse_len]) orelse {
                if (parse_len - pos < 6) break; // ヘッダ未到達
                pos += 1;
                continue;
            };
            const payload = parse_buf[pos + 3 .. pos + fr.consumed - 3];
            handleFrame(self, fr.msg_type, payload);
            pos += fr.consumed;
        }

        // 消費済みシフト。pos <= parse_len は上の invariant で保証されるので
        // 直接引き算で OK (@min による防御は parse_buf[pos..parse_len] 化で
        // 不要になった)。
        if (pos > 0 and pos < parse_len) {
            const remaining = parse_len - pos;
            std.mem.copyForwards(u8, parse_buf[0..remaining], parse_buf[pos..parse_len]);
            parse_len = remaining;
        } else if (pos == parse_len) {
            parse_len = 0;
        }
        // pos == 0 (何も消費せず) なら parse_len そのまま、次 chunk 追加待ち。

        // データ無音タイムアウト
        if (self.millisSinceLastData() > @as(i64, @intCast(self.cfg.data_timeout_ms))) {
            self.logger.warn("[upstream {s}] stall {d}ms, reconnect", .{
                self.cfg.mount,
                self.millisSinceLastData(),
            });
            break;
        }
    }
}

fn handleFrame(self: *Upstream, msg_type: u16, payload: []const u8) void {
    switch (msg_type) {
        1005, 1006 => {
            if (msm7.parseMsg1005(payload)) |coord| {
                self.lock.lock();
                self.coord = coord;
                self.lock.unlock();
            }
        },
        1077, 1087, 1097 => {
            // MSM7 の搬送波位相を抽出して最新観測 map に上書き
            const obs = msm7.extractPhase(self.alloc, payload) catch return;
            defer self.alloc.free(obs);

            const now = std.time.milliTimestamp();
            self.lock.lock();
            defer self.lock.unlock();
            for (obs) |o| {
                self.phase_map.put(self.alloc, obsKey(o.prn, o.band), .{
                    .obs = o,
                    .ts_ms = now,
                }) catch return;
            }
        },
        1019 => {
            // GPS broadcast ephemeris (Phase 7-1)。同一 PRN は常に上書き。
            const eph = ephemeris.parseMsg1019(payload) orelse return;
            const now = std.time.milliTimestamp();
            self.lock.lock();
            defer self.lock.unlock();
            self.eph_store.upsertGps(eph, now) catch return;
        },
        else => {},
    }
}
