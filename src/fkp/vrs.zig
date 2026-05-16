//! src/fkp/vrs.zig — VRS (Virtual Reference Station) ランタイム
//!
//! VRS は FKP と異なり「rover ごとに別ストリーム」を返す Network RTK 方式。
//! 動作概要:
//!   1. rover が `GET /<vrs_mountpoint>` で接続
//!   2. rover が定期的に `$GPGGA` を送信 (10 秒程度の間隔)
//!   3. caster は GGA から rover 位置を読み取り、その位置の仮想基準局として
//!      RTCM3 を合成して返送する
//!
//! 本実装の限界 (Phase 4 時点):
//!   - 主上流 (FKP runtime が立てる仮想 mountpoint) の RTCM3 を読み出し、
//!     Type 1005 を rover 位置で書き換え + Type 59 を除去して中継する
//!   - MSM7 (1077/1087/1097) は **そのままコピー** (= 真の VRS ではない)
//!     完全な FKP 補正適用には MSM7 エンコーダが必要で、それは Phase 5
//!   - 1005 だけ書き換えるのは正確には mathematically inconsistent だが、
//!     rover-基準局距離が小さいセル内なら 1cm-数 cm 程度の誤差で済む
//!
//! GGA 受信パス:
//!   poll(2) で rover stream を 100ms タイムアウトで覗き、データがあれば
//!   非ブロッキングで読んで `$G[PNL]GGA,...` 行を切り出してパースする。

const std = @import("std");
const parser = @import("../config/parser.zig");
const server = @import("../server.zig");
const source_mod = @import("../ntrip/source.zig");
const log_mod = @import("../log.zig");
const relay = @import("../relay/engine.zig");
const rtcm3 = @import("../ntrip/rtcm3.zig");
const msm7 = @import("msm7.zig");

// ── VRS 設定 ───────────────────────────────────────────────────────────────

/// VRS 用設定。`parser.Config` から `Runtime.create()` 時にコピーされる。
pub const VrsConfig = struct {
    enabled: bool = false,
    mountpoint: []const u8 = "",       // 公開する mountpoint 名 (例: "/VRS_AUTO")
    /// セル中心緯度 [deg]。rover がこの点から `cell_radius_km` 以上離れたら
    /// 503 で切断する。0.0 のときは距離チェックを無効化。
    cell_center_lat: f64 = 0.0,
    cell_center_lon: f64 = 0.0,
    cell_radius_km: f64 = 50.0,
    /// rover が初回 GGA を送るまでの待機時間 (秒)。これを超えたら 408 で切断。
    initial_gga_timeout_sec: u32 = 60,
    /// 仮想 Type 1005 を rover に注入する間隔 (秒)
    inject_1005_interval_sec: u32 = 5,
};

// ── VrsRover ──────────────────────────────────────────────────────────────

/// 単一 VRS rover の状態。1 接続 = 1 VrsRover = 1 スレッド。
pub const VrsRover = struct {
    id: u64,
    stream: std.net.Stream,
    peer_addr: std.net.Address,
    started_at_ms: i64,
    alloc: std.mem.Allocator,

    /// 最新の GGA から得た rover 位置 [deg, deg, m]
    /// has_position == false のあいだは合成停止 (= rover にデータ流さない)
    lock: std.Thread.Mutex = .{},
    has_position: bool = false,
    lat_deg: f64 = 0.0,
    lon_deg: f64 = 0.0,
    alt_m: f64 = 0.0,
    last_gga_at_ms: i64 = 0,

    bytes_in: u64 = 0,      // GGA 受信バイト数
    bytes_out: u64 = 0,     // 合成 RTCM3 送信バイト数

    pub fn create(
        alloc: std.mem.Allocator,
        id: u64,
        stream: std.net.Stream,
        peer_addr: std.net.Address,
    ) !*VrsRover {
        const r = try alloc.create(VrsRover);
        r.* = .{
            .id = id,
            .stream = stream,
            .peer_addr = peer_addr,
            .started_at_ms = std.time.milliTimestamp(),
            .alloc = alloc,
        };
        return r;
    }

    pub fn destroy(self: *VrsRover) void {
        self.alloc.destroy(self);
    }
};

// ── VrsRuntime ────────────────────────────────────────────────────────────

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    state: *server.ServerState,
    vrs_cfg: VrsConfig,

    /// 上流 RTCM3 を読むための「主上流仮想 Source」(FKP runtime が立てる
    /// 仮想 mountpoint と同じものを参照)。FKP runtime の起動が前提。
    /// null のときは Phase 4 動作不可 (FKP も無効化されている)。
    fkp_src: ?*server.Source,

    /// 接続中の rover (id → VrsRover*)
    rover_lock: std.Thread.Mutex = .{},
    rovers: std.AutoHashMap(u64, *VrsRover),

    pub fn create(
        alloc: std.mem.Allocator,
        state: *server.ServerState,
    ) !*Runtime {
        const cfg = state.config;
        if (!cfg.vrs_enable) return error.VrsDisabled;
        if (cfg.vrs_mountpoint.len == 0) return error.MissingMountpoint;

        const rt = try alloc.create(Runtime);
        errdefer alloc.destroy(rt);

        // 主上流の仮想 source を探す (FKP runtime が登録しているはず)
        const fkp_mp = ensureSlash(alloc, cfg.fkp_mountpoint) catch null;
        defer if (fkp_mp) |m| if (m.ptr != cfg.fkp_mountpoint.ptr) alloc.free(m);
        const fkp_src: ?*server.Source = if (fkp_mp) |m| state.getSource(m) else null;

        const vrs_mp_slashed = try ensureSlash(alloc, cfg.vrs_mountpoint);
        errdefer if (vrs_mp_slashed.ptr != cfg.vrs_mountpoint.ptr) alloc.free(vrs_mp_slashed);

        // VRS mountpoint は通常の「ソースとしては存在しない」が、認証用に
        // config.mounts には open エントリを置く (handleClient が config.mounts.get
        // しないと弾く設計のため)。
        var cfg_mut: *parser.Config = @constCast(cfg);
        cfg_mut.mounts.put(vrs_mp_slashed, .{ .open = true, .users = &.{} }) catch {};

        rt.* = .{
            .alloc = alloc,
            .state = state,
            .vrs_cfg = .{
                .enabled = true,
                .mountpoint = vrs_mp_slashed,
                .cell_center_lat = cfg.vrs_cell_center_lat,
                .cell_center_lon = cfg.vrs_cell_center_lon,
                .cell_radius_km = cfg.vrs_cell_radius_km,
                .initial_gga_timeout_sec = cfg.vrs_initial_gga_timeout_sec,
                .inject_1005_interval_sec = cfg.vrs_inject_1005_interval_sec,
            },
            .fkp_src = fkp_src,
            .rovers = std.AutoHashMap(u64, *VrsRover).init(alloc),
        };

        if (fkp_src == null) {
            state.logger.warn(
                "[vrs] fkp_mountpoint '{s}' not found in sources; VRS will refuse clients",
                .{cfg.fkp_mountpoint},
            );
        } else {
            state.logger.info(
                "[vrs] runtime ready: mountpoint={s} cell=({d:.4},{d:.4}) r={d}km",
                .{
                    rt.vrs_cfg.mountpoint,
                    rt.vrs_cfg.cell_center_lat,
                    rt.vrs_cfg.cell_center_lon,
                    rt.vrs_cfg.cell_radius_km,
                },
            );
        }

        return rt;
    }

    pub fn destroy(self: *Runtime) void {
        // 接続中 rover を切断 (clientLoop は stream.close で自然終了)
        self.rover_lock.lock();
        var it = self.rovers.valueIterator();
        while (it.next()) |r| r.*.stream.close();
        self.rovers.deinit();
        self.rover_lock.unlock();
        self.alloc.destroy(self);
    }

    pub fn matchesMountpoint(self: *const Runtime, mount: []const u8) bool {
        if (!self.vrs_cfg.enabled) return false;
        return std.mem.eql(u8, self.vrs_cfg.mountpoint, mount);
    }

    /// server.zig::ServerState.vrs に差し込む dispatch を作る。
    /// 循環依存回避のため anyopaque + 関数ポインタで abstract する。
    pub fn handler(self: *Runtime) server.VrsHandler {
        return .{
            .ctx = @ptrCast(self),
            .handle_fn = dispatchHandle,
            .matches_fn = dispatchMatches,
        };
    }

    /// rover 接続を引き受ける。client.zig::handleClient() から呼ばれる。
    /// この関数の戻りでハンドラスレッドが終了する。
    pub fn handle(
        self: *Runtime,
        stream: std.net.Stream,
        peer_addr: std.net.Address,
    ) void {
        if (self.fkp_src == null) {
            stream.writeAll("HTTP/1.0 503 Service Unavailable\r\n\r\n") catch {};
            return;
        }

        // ICY 200 OK を送って rover を「接続成立」にする
        stream.writeAll("ICY 200 OK\r\n\r\n") catch return;

        const id = self.state.nextClientId();
        const rover = VrsRover.create(self.alloc, id, stream, peer_addr) catch return;
        defer rover.destroy();

        self.rover_lock.lock();
        self.rovers.put(id, rover) catch {};
        self.rover_lock.unlock();
        defer {
            self.rover_lock.lock();
            _ = self.rovers.remove(id);
            self.rover_lock.unlock();
        }

        self.state.logger.info("[vrs] rover connected: id={d}", .{id});
        runRoverLoop(self, rover);
        self.state.logger.info(
            "[vrs] rover disconnected: id={d} in={d}B out={d}B uptime={d}s",
            .{
                id,
                rover.bytes_in,
                rover.bytes_out,
                @divTrunc(std.time.milliTimestamp() - rover.started_at_ms, 1000),
            },
        );
    }
};

// ── dispatch (server.VrsHandler 用) ───────────────────────────────────────

fn dispatchHandle(ctx: *anyopaque, stream: std.net.Stream, peer: std.net.Address) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.handle(stream, peer);
}

fn dispatchMatches(ctx: *anyopaque, mount: []const u8) bool {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    return rt.matchesMountpoint(mount);
}

// ── 内部: rover ハンドラ本体 ──────────────────────────────────────────────

fn runRoverLoop(rt: *Runtime, rover: *VrsRover) void {
    const fkp_src = rt.fkp_src.?;

    // 主上流の現在書き込み位置から購読開始
    var read_pos = fkp_src.ring.currentWritePos();

    // RTCM3 フレーム解析用バッファ
    var parse_buf: [relay.RingBuffer.CHUNK_SIZE * 2]u8 = undefined;
    var parse_len: usize = 0;

    var last_1005_at_ms: i64 = 0;
    const start_ms = std.time.milliTimestamp();

    // rover stream 読み取り用の小バッファ + 1 行 (GGA) 切り出し用
    var gga_acc: [256]u8 = undefined;
    var gga_len: usize = 0;

    // GGA を polling するため rover stream に短い read timeout を入れる。
    // upstream.zig と同じ手法 (SO_RCVTIMEO)。Linux では tv_usec = 100ms。
    setRecvTimeoutMs(rover.stream, 100) catch {};

    while (fkp_src.active.load(.seq_cst)) {
        // 1) rover stream を polling して GGA を読みに行く
        tryReadGga(rover, gga_acc[0..], &gga_len);

        // 2) 上流 RingBuffer から新着 RTCM3 を読む
        var read_buf: [relay.RingBuffer.CHUNK_SIZE]u8 = undefined;
        const result = fkp_src.ring.readChunk(read_pos, &read_buf) catch break;

        if (result) |r| {
            // parse_buf に追記 (溢れたら半分破棄)
            if (parse_len + r.len > parse_buf.len) {
                const carry = parse_buf.len / 2;
                std.mem.copyForwards(u8, parse_buf[0..carry], parse_buf[parse_len - carry .. parse_len]);
                parse_len = carry;
            }
            @memcpy(parse_buf[parse_len .. parse_len + r.len], read_buf[0..r.len]);
            parse_len += r.len;
            read_pos = r.next_pos;

            // フレームスキャン → 1005/59 をスキップ、他はそのまま forward
            const advanced = forwardFiltered(rover, parse_buf[0..parse_len]) catch break;
            const remaining = parse_len - advanced;
            if (remaining > 0 and advanced > 0) {
                std.mem.copyForwards(u8, parse_buf[0..remaining], parse_buf[advanced..parse_len]);
            }
            parse_len = remaining;
        } else {
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }

        const now = std.time.milliTimestamp();

        // 3) 定期的に Type 1005 を rover 座標で合成して送信
        rover.lock.lock();
        const has_pos = rover.has_position;
        const r_lat = rover.lat_deg;
        const r_lon = rover.lon_deg;
        const r_alt = rover.alt_m;
        rover.lock.unlock();

        if (has_pos) {
            const interval_ms: i64 = @intCast(@as(u64, rt.vrs_cfg.inject_1005_interval_sec) * 1000);
            if (now - last_1005_at_ms >= interval_ms) {
                inject1005(rover, r_lat, r_lon, r_alt) catch break;
                last_1005_at_ms = now;
            }
        }

        // 4) initial GGA timeout チェック
        if (!has_pos) {
            const timeout_ms: i64 = @intCast(@as(u64, rt.vrs_cfg.initial_gga_timeout_sec) * 1000);
            if (now - start_ms > timeout_ms) {
                rt.state.logger.warn(
                    "[vrs] rover id={d} no GGA in {d}s, closing",
                    .{ rover.id, rt.vrs_cfg.initial_gga_timeout_sec },
                );
                break;
            }
        }

        // 5) セル境界チェック (rover が位置を持っているとき)
        if (has_pos and rt.vrs_cfg.cell_center_lat != 0.0) {
            const d_km = distanceKm(
                rt.vrs_cfg.cell_center_lat,
                rt.vrs_cfg.cell_center_lon,
                r_lat,
                r_lon,
            );
            if (d_km > rt.vrs_cfg.cell_radius_km) {
                rt.state.logger.warn(
                    "[vrs] rover id={d} out of cell: {d:.1}km > {d:.1}km",
                    .{ rover.id, d_km, rt.vrs_cfg.cell_radius_km },
                );
                break;
            }
        }
    }
}

// ── GGA 読み取り ─────────────────────────────────────────────────────────

fn setRecvTimeoutMs(stream: std.net.Stream, ms: u32) !void {
    const tv = std.posix.timeval{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
    const bytes = std.mem.asBytes(&tv);
    try std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        bytes,
    );
}

/// rover stream から (短い timeout で) 1 回読み、改行で行をまとめて GGA を抽出する。
/// SO_RCVTIMEO 設定済 → 100ms 以内にデータが無ければ read() がエラーで戻る。
fn tryReadGga(rover: *VrsRover, acc: []u8, acc_len: *usize) void {
    var buf: [256]u8 = undefined;
    const n = rover.stream.read(&buf) catch return;
    if (n == 0) return;

    rover.bytes_in += n;

    // acc に追記 (溢れたら捨てて先頭から)
    for (buf[0..n]) |b| {
        if (acc_len.* >= acc.len) {
            acc_len.* = 0;  // 行が長すぎる: リセット
        }
        acc[acc_len.*] = b;
        acc_len.* += 1;

        if (b == '\n') {
            // 行確定 → GGA か検査
            const line = acc[0..acc_len.*];
            handleGgaLine(rover, line);
            acc_len.* = 0;
        }
    }
}

fn handleGgaLine(rover: *VrsRover, line: []const u8) void {
    // `$G[NPLA]GGA,` で始まる行のみ採用
    if (line.len < 7) return;
    if (line[0] != '$') return;
    if (line[1] != 'G') return;
    if (!std.mem.startsWith(u8, line[3..], "GGA,")) return;

    // カンマ区切りで各フィールドを取り出す
    var iter = std.mem.tokenizeAny(u8, line, ",*");
    // [0] = "$GPGGA" / "$GNGGA" etc
    _ = iter.next() orelse return;
    // [1] = UTC time
    _ = iter.next() orelse return;
    // [2] = lat ddmm.mmmm
    const lat_s = iter.next() orelse return;
    // [3] = N/S
    const ns = iter.next() orelse return;
    // [4] = lon dddmm.mmmm
    const lon_s = iter.next() orelse return;
    // [5] = E/W
    const ew = iter.next() orelse return;
    // [6] = fix quality (skip)
    _ = iter.next() orelse return;
    // [7] = num satellites
    _ = iter.next() orelse return;
    // [8] = HDOP
    _ = iter.next() orelse return;
    // [9] = altitude
    const alt_s = iter.next() orelse return;

    const lat = parseDdmm(lat_s, 2) orelse return;
    const lon = parseDdmm(lon_s, 3) orelse return;
    const alt = std.fmt.parseFloat(f64, alt_s) catch return;

    const final_lat = if (ns.len > 0 and ns[0] == 'S') -lat else lat;
    const final_lon = if (ew.len > 0 and ew[0] == 'W') -lon else lon;

    rover.lock.lock();
    rover.has_position = true;
    rover.lat_deg = final_lat;
    rover.lon_deg = final_lon;
    rover.alt_m = alt;
    rover.last_gga_at_ms = std.time.milliTimestamp();
    rover.lock.unlock();
}

/// "ddmm.mmmm" or "dddmm.mmmm" → 度に変換。`deg_digits` は度部分の桁数 (2 or 3)。
fn parseDdmm(s: []const u8, deg_digits: usize) ?f64 {
    if (s.len <= deg_digits) return null;
    const deg = std.fmt.parseFloat(f64, s[0..deg_digits]) catch return null;
    const min = std.fmt.parseFloat(f64, s[deg_digits..]) catch return null;
    return deg + min / 60.0;
}

// ── フレームフィルタ + 1005 注入 ──────────────────────────────────────────

/// `buf` の先頭からスキャンし、完全な RTCM3 フレームを `rover.stream` に書き出す。
/// Type 1005 と Type 59 は除外 (1005 は別途 inject、59 は VRS では不要)。
/// 不完全フレーム手前まで進めて `consumed` バイト数を返す。
fn forwardFiltered(rover: *VrsRover, buf: []const u8) !usize {
    var pos: usize = 0;
    while (pos < buf.len) {
        if (buf[pos] != rtcm3.PREAMBLE) {
            pos += 1;
            continue;
        }
        if (buf.len - pos < 6) break;  // ヘッダ未到達 (preamble + length + CRC)
        const fr = rtcm3.parseFrame(buf[pos..]) orelse {
            // CRC 不一致 or 未完: 1 バイト進めて再試行
            // ただしフレーム長分のバイトが揃っている (未完ではない) ことが
            // parseFrame の戻り null の主因なので、CRC 失敗とみなしてシフト
            const length: usize = (@as(usize, buf[pos + 1] & 0x03) << 8) | buf[pos + 2];
            if (buf.len - pos < 3 + length + 3) break;  // 未完 → 待つ
            pos += 1;
            continue;
        };
        const drop = (fr.msg_type == 59) or (fr.msg_type == 1005);
        if (!drop) {
            rover.stream.writeAll(buf[pos .. pos + fr.consumed]) catch return error.WriteFailed;
            rover.bytes_out += fr.consumed;
        }
        pos += fr.consumed;
    }
    return pos;
}

/// 仮想 Type 1005 を rover 位置で合成して送信する。
fn inject1005(rover: *VrsRover, lat_deg: f64, lon_deg: f64, alt_m: f64) !void {
    const lat_rad = lat_deg * std.math.pi / 180.0;
    const lon_rad = lon_deg * std.math.pi / 180.0;
    const ecef = msm7.latLonAltToEcef(lat_rad, lon_rad, alt_m);

    // rover id から派生した仮想 Reference Station ID (上位 12 bit に収まるよう mask)
    const ref_id: u16 = @truncate(0x4000 | (rover.id & 0x0FFF));

    const frame = msm7.encodeMsg1005(rover.alloc, ref_id, ecef, true) catch return;
    defer rover.alloc.free(frame);

    rover.stream.writeAll(frame) catch return error.WriteFailed;
    rover.bytes_out += frame.len;
}

// ── 距離 ──────────────────────────────────────────────────────────────────

/// 2 点間の大圏距離 [km] (Haversine 公式)
fn distanceKm(lat1_deg: f64, lon1_deg: f64, lat2_deg: f64, lon2_deg: f64) f64 {
    const R = 6371.0;
    const to_rad = std.math.pi / 180.0;
    const dlat = (lat2_deg - lat1_deg) * to_rad;
    const dlon = (lon2_deg - lon1_deg) * to_rad;
    const a = @sin(dlat / 2) * @sin(dlat / 2) +
        @cos(lat1_deg * to_rad) * @cos(lat2_deg * to_rad) *
        @sin(dlon / 2) * @sin(dlon / 2);
    const c = 2 * std.math.atan2(@sqrt(a), @sqrt(1 - a));
    return R * c;
}

// ── 共通: mountpoint 名に "/" を強制 ──────────────────────────────────────

fn ensureSlash(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) return name;
    if (name[0] == '/') return name;
    const out = try alloc.alloc(u8, name.len + 1);
    out[0] = '/';
    @memcpy(out[1..], name);
    return out;
}
