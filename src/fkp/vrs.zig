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
const fkp_runtime = @import("runtime.zig");

/// build option (default false)。`-Dvrs-inject-antenna=true` で有効化。
/// build_options モジュールはルート側 build.zig で options_mod として作成され、
/// ntripcaster_mod / src_tests / fkp_demo 等の `.imports` 経由で配線される。
const build_options = @import("build_options");

// ── VRS 設定 ───────────────────────────────────────────────────────────────

/// VRS 用設定。`parser.Config` から `Runtime.create()` 時にコピーされる。
pub const VrsConfig = struct {
    enabled: bool = false,
    mountpoint: []const u8 = "", // 公開する mountpoint 名 (例: "/VRS_AUTO")
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

    /// この rover に見せる仮想基準局 ID (12-bit, 0x800..0xFFF)。create() で
    /// 計算して固定。inject1005 / inject1008 / MSM7 ref_id 書き換えの全てで
    /// 同じ値を使うことで rover 側が単一の基準局として認識する。
    vrs_ref_id: u16,

    /// 最新の GGA から得た rover 位置 [deg, deg, m]
    /// has_position == false のあいだは合成停止 (= rover にデータ流さない)
    lock: std.Thread.Mutex = .{},
    has_position: bool = false,
    lat_deg: f64 = 0.0,
    lon_deg: f64 = 0.0,
    alt_m: f64 = 0.0,
    last_gga_at_ms: i64 = 0,

    bytes_in: u64 = 0, // GGA 受信バイト数
    bytes_out: u64 = 0, // 合成 RTCM3 送信バイト数

    // ── 診断カウンタ (rover 終了時にまとめてログ出力) ─────────────────────
    /// GGA を初めてパースした際に true。一度きりの info ログ用。
    initial_gga_logged: bool = false,
    /// この rover に inject1005 した累計
    inject_1005_count: u64 = 0,
    /// この rover に inject1008 した累計 (build option 有効時のみ加算)
    inject_1008_count: u64 = 0,
    /// forwardFiltered が転送した RTCM3 フレーム累計
    frames_forwarded: u64 = 0,
    /// forwardFiltered で ref_id を VRS 値に書き換えたフレーム累計
    /// (MSM7 / legacy obs / 1033 / 1230 等、station_id を持つメッセージ)
    frames_ref_id_rewritten: u64 = 0,
    /// forwardFiltered が drop した RTCM3 フレーム累計 (msg_type=59/1005/1006)
    frames_dropped: u64 = 0,
    /// drop した中で msg_type=1005 だったフレーム累計 (1005 漏れ調査用)
    frames_dropped_1005: u64 = 0,
    /// drop した中で msg_type=1006 だったフレーム累計 (1006 = 1005 + AntHeight)
    frames_dropped_1006: u64 = 0,
    /// drop した中で msg_type=59 だったフレーム累計
    frames_dropped_59: u64 = 0,
    /// Phase 5b-3: applyPhaseCorrection が成功した MSM7 フレーム累計
    frames_phase_corrected: u64 = 0,
    /// Phase 5b-3: applyPhaseCorrection が失敗した MSM7 フレーム累計
    /// (snapshot 未保存 / rover 位置未取得 / applyPhaseCorrection エラー等)
    frames_correction_failed: u64 = 0,

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
            .vrs_ref_id = @truncate(0x800 | (id & 0x7FF)),
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

    /// FKP ランタイムへの back-reference。`snapshotFkp()` 経由で MSM7
    /// フレームに対する phase 補正を取得する。null のときは Phase 4 相当
    /// (補正なし、frame は ref_id 書き換えのみで素通し)。
    fkp_rt: ?*fkp_runtime.Runtime,

    /// 接続中の rover (id → VrsRover*)
    rover_lock: std.Thread.Mutex = .{},
    rovers: std.AutoHashMap(u64, *VrsRover),

    pub fn create(
        alloc: std.mem.Allocator,
        state: *server.ServerState,
        fkp_rt: ?*fkp_runtime.Runtime,
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
            .fkp_rt = fkp_rt,
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
            "[vrs] rover disconnected: id={d} vrs_ref_id=0x{X:0>3} in={d}B out={d}B uptime={d}s " ++
                "frames_fwd={d} ref_id_rewritten={d} drop_total={d} (1005={d} 1006={d} 59={d}) " ++
                "inject_1005={d} inject_1008={d} phase_corrected={d} corr_failed={d} has_pos={any}",
            .{
                id,
                rover.vrs_ref_id,
                rover.bytes_in,
                rover.bytes_out,
                @divTrunc(std.time.milliTimestamp() - rover.started_at_ms, 1000),
                rover.frames_forwarded,
                rover.frames_ref_id_rewritten,
                rover.frames_dropped,
                rover.frames_dropped_1005,
                rover.frames_dropped_1006,
                rover.frames_dropped_59,
                rover.inject_1005_count,
                rover.inject_1008_count,
                rover.frames_phase_corrected,
                rover.frames_correction_failed,
                rover.has_position,
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
    var last_stats_at_ms: i64 = std.time.milliTimestamp();
    var last_stats_frames_fwd: u64 = 0;
    var last_stats_drop_1005: u64 = 0;
    var last_stats_drop_1006: u64 = 0;
    const start_ms = std.time.milliTimestamp();

    // rover stream 読み取り用の小バッファ + 1 行 (GGA) 切り出し用
    var gga_acc: [256]u8 = undefined;
    var gga_len: usize = 0;

    // GGA を polling するため rover stream に短い read timeout を入れる。
    // upstream.zig と同じ手法 (SO_RCVTIMEO)。Linux では tv_usec = 100ms。
    setRecvTimeoutMs(rover.stream, 100) catch {};

    while (fkp_src.active.load(.seq_cst)) {
        // 1) rover stream を polling して GGA を読みに行く
        tryReadGga(rt, rover, gga_acc[0..], &gga_len);

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
            // rt 渡しで MSM7 に Phase 5b-3 補正を適用する
            const advanced = forwardFiltered(rover.stream, parse_buf[0..parse_len], rover, rt) catch break;
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
                inject1005(rt, rover, r_lat, r_lon, r_alt) catch break;
                last_1005_at_ms = now;
            }
        }

        // 3.5) 5 秒ごとにフィルタ統計を info ログに出す (10 秒以降のみ)
        if (now - last_stats_at_ms >= 5000 and now - start_ms >= 10_000) {
            const dfwd = rover.frames_forwarded - last_stats_frames_fwd;
            const d1005 = rover.frames_dropped_1005 - last_stats_drop_1005;
            const d1006 = rover.frames_dropped_1006 - last_stats_drop_1006;
            rt.state.logger.info(
                "[vrs] rover id={d} stats: fwd+={d} drop_1005+={d} drop_1006+={d} has_pos={any} inject_1005={d}",
                .{ rover.id, dfwd, d1005, d1006, has_pos, rover.inject_1005_count },
            );
            last_stats_at_ms = now;
            last_stats_frames_fwd = rover.frames_forwarded;
            last_stats_drop_1005 = rover.frames_dropped_1005;
            last_stats_drop_1006 = rover.frames_dropped_1006;
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
fn tryReadGga(rt: *Runtime, rover: *VrsRover, acc: []u8, acc_len: *usize) void {
    var buf: [256]u8 = undefined;
    const n = rover.stream.read(&buf) catch return;
    if (n == 0) return;

    rover.bytes_in += n;

    // acc に追記 (溢れたら捨てて先頭から)
    for (buf[0..n]) |b| {
        if (acc_len.* >= acc.len) {
            acc_len.* = 0; // 行が長すぎる: リセット
        }
        acc[acc_len.*] = b;
        acc_len.* += 1;

        if (b == '\n') {
            // 行確定 → GGA か検査
            const line = acc[0..acc_len.*];
            handleGgaLine(rt, rover, line);
            acc_len.* = 0;
        }
    }
}

fn handleGgaLine(rt: ?*Runtime, rover: *VrsRover, line: []const u8) void {
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
    const log_first = !rover.initial_gga_logged;
    rover.initial_gga_logged = true;
    rover.lock.unlock();

    if (log_first) if (rt) |runtime| {
        runtime.state.logger.info(
            "[vrs] rover id={d} first GGA parsed: lat={d:.6} lon={d:.6} alt={d:.1}m",
            .{ rover.id, final_lat, final_lon, alt },
        );
    };
}

/// "ddmm.mmmm" or "dddmm.mmmm" → 度に変換。`deg_digits` は度部分の桁数 (2 or 3)。
fn parseDdmm(s: []const u8, deg_digits: usize) ?f64 {
    if (s.len <= deg_digits) return null;
    const deg = std.fmt.parseFloat(f64, s[0..deg_digits]) catch return null;
    const min = std.fmt.parseFloat(f64, s[deg_digits..]) catch return null;
    return deg + min / 60.0;
}

// ── フレームフィルタ + 1005 注入 + MSM7 ref_id 書き換え ────────────────────

/// 該当 msg_type の payload bits 12-23 が "Reference Station ID" かを判定。
/// RTCM 10403.3 で station_id を含むメッセージ:
/// - 1001..1004: legacy GPS observations
/// - 1005..1008: station coordinates / antenna descriptor
/// - 1009..1012: legacy GLONASS observations
/// - 1033: receiver/antenna descriptor
/// - 1071..1077, 1081..1087, 1091..1097, 1101..1107, 1111..1117, 1121..1127,
///   1131..1137: MSM1-7 for GPS/GLO/Gal/SBAS/QZSS/BDS/IRNSS
/// - 1230: GLONASS code-phase biases
fn rtcmHasStationId(msg_type: u16) bool {
    return switch (msg_type) {
        1001...1012,
        1033,
        1071...1077,
        1081...1087,
        1091...1097,
        1101...1107,
        1111...1117,
        1121...1127,
        1131...1137,
        1230,
        => true,
        else => false,
    };
}

/// `frame` (RTCM3 1 フレーム全体 = preamble + length + payload + CRC) の
/// payload bits 12-23 (= byte[1] 下位 4bit + byte[2]) を `new_ref_id` に
/// 書き換えて CRC-24Q を再計算する。`new_ref_id` は 12 bit 必須。
/// payload 長 < 3 byte の場合は何もしない (= station_id 欠落フレーム)。
fn rewriteRefIdInFrame(frame: []u8, new_ref_id: u16) void {
    std.debug.assert(new_ref_id <= 0xFFF);
    if (frame.len < 8) return;
    const length: usize = (@as(usize, frame[1] & 0x03) << 8) | frame[2];
    if (length < 3) return;
    if (frame.len < 3 + length + 3) return;

    // payload[1] 上位 4bit = msg_type の下位 4bit (温存)。下位 4bit = ref_id 上位 4bit。
    frame[3 + 1] = (frame[3 + 1] & 0xF0) | @as(u8, @truncate((new_ref_id >> 8) & 0x0F));
    frame[3 + 2] = @truncate(new_ref_id & 0xFF);

    const crc = rtcm3.crc24q(frame[0 .. 3 + length]);
    frame[3 + length + 0] = @truncate((crc >> 16) & 0xFF);
    frame[3 + length + 1] = @truncate((crc >> 8) & 0xFF);
    frame[3 + length + 2] = @truncate(crc & 0xFF);
}

/// MSM7 メッセージタイプ判定 (1077=GPS, 1087=GLO, 1097=Gal)
fn isMsm7(msg_type: u16) bool {
    return msg_type == 1077 or msg_type == 1087 or msg_type == 1097;
}

/// FKP スナップショット + rover 位置 (rad) から PRN ごとの位相補正値を計算する。
/// 簡易版: 地物的成分 (n_0, e_0) と電離層成分 (n_i, e_i) を L1 換算で合算。
/// 結果は `out` に append (caller の allocator を使う)。
///
/// 数式 (docs/phase5b-design.md § 3、L1 のみ):
///   delta_m = (n_i + n_0) * dN + (e_i + e_0) * dE
///   dN, dE は rover - master (lat/lon 差) [rad]
pub fn computePhaseDelta(
    out: *std.ArrayList(msm7.PhaseDelta),
    alloc: std.mem.Allocator,
    snap: fkp_runtime.FkpSnapshot,
    rover_lat_rad: f64,
    rover_lon_rad: f64,
) !void {
    const d_n = rover_lat_rad - snap.ref_coord.lat;
    const d_e = rover_lon_rad - snap.ref_coord.lon;
    for (snap.params) |p| {
        const delta_m = (p.n_i + p.n_0) * d_n + (p.e_i + p.e_0) * d_e;
        try out.append(alloc, .{
            .prn = p.prn,
            .band = .l1,
            .delta_m = delta_m,
        });
    }
}

/// MSM7 フレームに FKP 補正を適用する。失敗時は rover.frames_correction_failed
/// を増やしてそのまま (= 補正なしの frame を送るので Phase 5a 動作にフォールバック)。
/// Phase 5b-3。
fn applyVrsPhaseCorrection(
    frame: []u8,
    rover: *VrsRover,
    rt: *Runtime,
) void {
    const fkp_rt = rt.fkp_rt orelse return;

    var arena = std.heap.ArenaAllocator.init(rover.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const snap = fkp_rt.snapshotFkp(alloc) orelse {
        // FKP がまだ snapshot を生成していない (起動直後等)
        rover.frames_correction_failed += 1;
        return;
    };
    defer snap.deinit(alloc);

    rover.lock.lock();
    if (!rover.has_position) {
        rover.lock.unlock();
        rover.frames_correction_failed += 1;
        return;
    }
    const rover_lat_rad = rover.lat_deg * std.math.pi / 180.0;
    const rover_lon_rad = rover.lon_deg * std.math.pi / 180.0;
    rover.lock.unlock();

    var deltas = std.ArrayList(msm7.PhaseDelta){};
    defer deltas.deinit(alloc);
    computePhaseDelta(&deltas, alloc, snap, rover_lat_rad, rover_lon_rad) catch {
        rover.frames_correction_failed += 1;
        return;
    };

    msm7.applyPhaseCorrection(frame, deltas.items) catch {
        rover.frames_correction_failed += 1;
        return;
    };

    rover.frames_phase_corrected += 1;
}

/// `buf` の先頭からスキャンし、完全な RTCM3 フレームを `writer` に書き出す。
/// Type 1005 / 1006 / 59 は除外、MSM7 等の station_id 保持メッセージは
/// rover.vrs_ref_id に書き換えてから送る (Phase 5a)。MSM7 のみ Phase 5b-3 の
/// `applyVrsPhaseCorrection` で in-place 位相補正を適用する (rt!=null のとき)。
/// 不完全フレーム手前まで進めて `consumed` バイト数を返す。
fn forwardFiltered(
    writer: anytype,
    buf: []const u8,
    rover: *VrsRover,
    rt: ?*Runtime,
) !usize {
    // RTCM3 frame max size = 3 + 1023 + 3 = 1029 byte (length は 10 bit)。
    var scratch: [3 + 1023 + 3]u8 = undefined;

    var pos: usize = 0;
    while (pos < buf.len) {
        if (buf[pos] != rtcm3.PREAMBLE) {
            pos += 1;
            continue;
        }
        if (buf.len - pos < 6) break;
        const fr = rtcm3.parseFrame(buf[pos..]) orelse {
            const length: usize = (@as(usize, buf[pos + 1] & 0x03) << 8) | buf[pos + 2];
            if (buf.len - pos < 3 + length + 3) break;
            pos += 1;
            continue;
        };
        const drop = (fr.msg_type == 59) or (fr.msg_type == 1005) or (fr.msg_type == 1006);
        if (drop) {
            rover.frames_dropped += 1;
            if (fr.msg_type == 1005) rover.frames_dropped_1005 += 1;
            if (fr.msg_type == 1006) rover.frames_dropped_1006 += 1;
            if (fr.msg_type == 59) rover.frames_dropped_59 += 1;
        } else if (rtcmHasStationId(fr.msg_type)) {
            // station_id 含む → scratch にコピーして書き換え + CRC 再計算
            @memcpy(scratch[0..fr.consumed], buf[pos .. pos + fr.consumed]);
            rewriteRefIdInFrame(scratch[0..fr.consumed], rover.vrs_ref_id);
            // Phase 5b-3: MSM7 のみ phase 補正適用 (rt==null の Phase 4 test は skip)
            if (rt) |runtime| {
                if (isMsm7(fr.msg_type)) {
                    applyVrsPhaseCorrection(scratch[0..fr.consumed], rover, runtime);
                }
            }
            writer.writeAll(scratch[0..fr.consumed]) catch return error.WriteFailed;
            rover.bytes_out += fr.consumed;
            rover.frames_forwarded += 1;
            rover.frames_ref_id_rewritten += 1;
        } else {
            // station_id なし (ephemeris 等) → そのまま transparent forward
            writer.writeAll(buf[pos .. pos + fr.consumed]) catch return error.WriteFailed;
            rover.bytes_out += fr.consumed;
            rover.frames_forwarded += 1;
        }
        pos += fr.consumed;
    }
    return pos;
}

/// 仮想 Type 1005 を rover 位置で合成して送信する。
fn inject1005(rt: *Runtime, rover: *VrsRover, lat_deg: f64, lon_deg: f64, alt_m: f64) !void {
    const lat_rad = lat_deg * std.math.pi / 180.0;
    const lon_rad = lon_deg * std.math.pi / 180.0;
    const ecef = msm7.latLonAltToEcef(lat_rad, lon_rad, alt_m);
    const ref_id = rover.vrs_ref_id;

    const frame = msm7.encodeMsg1005(rover.alloc, ref_id, ecef, true) catch return;
    defer rover.alloc.free(frame);

    rover.stream.writeAll(frame) catch return error.WriteFailed;
    rover.bytes_out += frame.len;
    rover.inject_1005_count += 1;

    // 初回のみ info ログ。以後は終了時サマリで集計確認。
    if (rover.inject_1005_count == 1) {
        rt.state.logger.info(
            "[vrs] rover id={d} first inject 1005: ref_id=0x{X:0>3} ({d}) ecef=({d:.3},{d:.3},{d:.3})",
            .{ rover.id, ref_id, ref_id, ecef[0], ecef[1], ecef[2] },
        );
    }

    // build option で有効時のみ Antenna Descriptor (1008) を 1005 の直後に挟む。
    // RTCM 推奨: 1005 の約半分のレート、観測メッセージの間には挟まない。
    // 1005 の偶数回目 (= 2 回に 1 回) で送る → 半レート。
    // 標準ビルドからは comptime if で完全に消える。
    if (comptime build_options.vrs_inject_antenna) {
        if (rover.inject_1005_count % 2 == 1) { // 初回 + 3回目 + 5回目 ...
            injectAntenna(rt, rover) catch {};
        }
    }
}

/// Antenna Descriptor (RTCM3 1008) を送る。descriptor は "ADVNULLANTENNA NONE"
/// (NONE = radome なし) を使用 — esp32-xbee #13 / SNIP DavidKelleySCSC 推奨:
/// 「ベース局側で既に PCO/PCV 補正済み」を意味し、Trimble rover の 95% で OK。
/// serial は空文字列で十分。
fn injectAntenna(rt: *Runtime, rover: *VrsRover) !void {
    const frame = msm7.encodeMsg1008(rover.alloc, rover.vrs_ref_id, "ADVNULLANTENNA NONE", "") catch return;
    defer rover.alloc.free(frame);
    rover.stream.writeAll(frame) catch return error.WriteFailed;
    rover.bytes_out += frame.len;
    rover.inject_1008_count += 1;
    if (rover.inject_1008_count == 1) {
        rt.state.logger.info(
            "[vrs] rover id={d} first inject 1008: ref_id=0x{X:0>3} desc='ADVNULLANTENNA NONE'",
            .{ rover.id, rover.vrs_ref_id },
        );
    }
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

// ── テスト ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// テスト用: writeAll の呼び出しを ArrayList に貯める偽 writer。
const CaptureWriter = struct {
    buf: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    pub fn writeAll(self: CaptureWriter, data: []const u8) !void {
        try self.buf.appendSlice(self.alloc, data);
    }
};

/// テスト用: 任意の msg_type + ref_id を持つ 3-byte payload の RTCM3 フレームを作る。
/// payload[0..1] = msg_type (12bit), payload[1..2] 下位 12bit = ref_id。
fn makeDummyFrame(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, msg_type: u16) !void {
    return makeDummyFrameRid(buf, alloc, msg_type, 0);
}

fn makeDummyFrameRid(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, msg_type: u16, ref_id: u16) !void {
    const payload0: u8 = @truncate((msg_type >> 4) & 0xFF);
    const payload1: u8 = @truncate(((msg_type & 0x0F) << 4) | ((ref_id >> 8) & 0x0F));
    const payload2: u8 = @truncate(ref_id & 0xFF);
    var frame: [9]u8 = .{ 0xD3, 0x00, 0x03, payload0, payload1, payload2, 0, 0, 0 };
    const crc = rtcm3.crc24q(frame[0..6]);
    frame[6] = @truncate((crc >> 16) & 0xFF);
    frame[7] = @truncate((crc >> 8) & 0xFF);
    frame[8] = @truncate(crc & 0xFF);
    try buf.appendSlice(alloc, &frame);
}

/// テスト用: VrsRover のフィールドをコピーするミニ初期化。stream は使わない。
fn makeTestRover(alloc: std.mem.Allocator) VrsRover {
    const id: u64 = 42;
    return .{
        .id = id,
        .stream = .{ .handle = -1 }, // 触らない (forwardFiltered は writer 側を使う)
        .peer_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
        .started_at_ms = 0,
        .alloc = alloc,
        .vrs_ref_id = @truncate(0x800 | (id & 0x7FF)), // = 0x82A
    };
}

test "vrs: forwardFiltered drops Type 1005/1006/59, forwards + rewrites ref_id on MSM7" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var input: std.ArrayListUnmanaged(u8) = .{};
    // 1077 (forward+rewrite) → 1005 (drop) → 1019 (forward, no rewrite)
    //   → 59 (drop) → 1006 (drop) → 1087 (forward+rewrite)
    try makeDummyFrame(&input, a, 1077);
    try makeDummyFrame(&input, a, 1005);
    try makeDummyFrame(&input, a, 1019);
    try makeDummyFrame(&input, a, 59);
    try makeDummyFrame(&input, a, 1006);
    try makeDummyFrame(&input, a, 1087);

    var captured: std.ArrayListUnmanaged(u8) = .{};
    const writer = CaptureWriter{ .buf = &captured, .alloc = a };
    var rover = makeTestRover(a);

    const consumed = try forwardFiltered(writer, input.items, &rover, null);

    try testing.expectEqual(input.items.len, consumed);
    try testing.expectEqual(@as(u64, 3), rover.frames_forwarded);
    try testing.expectEqual(@as(u64, 2), rover.frames_ref_id_rewritten); // 1077 + 1087
    try testing.expectEqual(@as(u64, 3), rover.frames_dropped);
    try testing.expectEqual(@as(u64, 1), rover.frames_dropped_1005);
    try testing.expectEqual(@as(u64, 1), rover.frames_dropped_1006);
    try testing.expectEqual(@as(u64, 1), rover.frames_dropped_59);
    // 出力は 1077 + 1019 + 1087 の連結 (各 9 バイト = 3 byte payload + 3 CRC + 3 header)
    try testing.expectEqual(@as(usize, 3 * 9), captured.items.len);
    // msg_type 抽出
    const mt0: u16 = (@as(u16, captured.items[3]) << 4) | (captured.items[4] >> 4);
    const mt1: u16 = (@as(u16, captured.items[12]) << 4) | (captured.items[13] >> 4);
    const mt2: u16 = (@as(u16, captured.items[21]) << 4) | (captured.items[22] >> 4);
    try testing.expectEqual(@as(u16, 1077), mt0);
    try testing.expectEqual(@as(u16, 1019), mt1);
    try testing.expectEqual(@as(u16, 1087), mt2);
    // ref_id 抽出 (1077 frame の payload bytes 1-2)
    const rid0: u16 = ((@as(u16, captured.items[4]) & 0x0F) << 8) | captured.items[5];
    const rid2: u16 = ((@as(u16, captured.items[22]) & 0x0F) << 8) | captured.items[23];
    try testing.expectEqual(rover.vrs_ref_id, rid0); // 1077: 書き換え済
    try testing.expectEqual(rover.vrs_ref_id, rid2); // 1087: 書き換え済
    // 1019 (ephemeris) は station_id 持たない → そのまま (rewrite count に入らない)
    // CRC が再計算されて valid であることは captured 全体を parseFrame で再パースして確認
    var pos: usize = 0;
    var cnt: usize = 0;
    while (pos < captured.items.len) {
        const fr = rtcm3.parseFrame(captured.items[pos..]) orelse return error.RewriteCorruptedFrame;
        cnt += 1;
        pos += fr.consumed;
    }
    try testing.expectEqual(@as(usize, 3), cnt); // 3 frames, 全 CRC valid
}

test "vrs: rewriteRefIdInFrame keeps msg_type, updates ref_id, refreshes CRC" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var input: std.ArrayListUnmanaged(u8) = .{};
    try makeDummyFrame(&input, a, 1077); // makeDummyFrame は ref_id=0 で作る
    rewriteRefIdInFrame(input.items, 0x801);

    // CRC が valid であることは parseFrame の成功で確認
    const fr = rtcm3.parseFrame(input.items) orelse return error.ParseFailed;
    try testing.expectEqual(@as(u16, 1077), fr.msg_type);
    // ref_id を再抽出
    const rid: u16 = ((@as(u16, input.items[4]) & 0x0F) << 8) | input.items[5];
    try testing.expectEqual(@as(u16, 0x801), rid);
}

test "vrs: rtcmHasStationId classifies common types correctly" {
    // station_id 持つ: 1001..1012, 1033, MSM 群, 1230
    try testing.expect(rtcmHasStationId(1077));
    try testing.expect(rtcmHasStationId(1004));
    try testing.expect(rtcmHasStationId(1033));
    try testing.expect(rtcmHasStationId(1230));
    try testing.expect(rtcmHasStationId(1127));
    // 持たない: ephemeris 群 + 不明
    try testing.expect(!rtcmHasStationId(1019)); // GPS ephemeris
    try testing.expect(!rtcmHasStationId(1020)); // GLO ephemeris
    try testing.expect(!rtcmHasStationId(1042)); // BDS ephemeris
    try testing.expect(!rtcmHasStationId(1045)); // Galileo F/NAV
    try testing.expect(!rtcmHasStationId(1046)); // Galileo I/NAV
    try testing.expect(!rtcmHasStationId(59)); // FKP (drop 対象)
    try testing.expect(!rtcmHasStationId(0));
    try testing.expect(!rtcmHasStationId(9999));
}

test "vrs: forwardFiltered drops real encoded 1005 frame" {
    // encodeMsg1005 で作った実フレームが drop されることを検証 (artificial dummy ではない)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const real_1005 = try msm7.encodeMsg1005(a, 1, .{ -3949000.123, 3357000.456, 3700000.789 }, false);
    var captured: std.ArrayListUnmanaged(u8) = .{};
    const writer = CaptureWriter{ .buf = &captured, .alloc = a };
    var rover = makeTestRover(a);

    const consumed = try forwardFiltered(writer, real_1005, &rover, null);
    try testing.expectEqual(real_1005.len, consumed);
    try testing.expectEqual(@as(u64, 0), rover.frames_forwarded);
    try testing.expectEqual(@as(u64, 1), rover.frames_dropped_1005);
    try testing.expectEqual(@as(usize, 0), captured.items.len);
}

test "vrs: forwardFiltered stops at incomplete trailing frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var input: std.ArrayListUnmanaged(u8) = .{};
    try makeDummyFrame(&input, a, 1077); // 完全 9-byte frame (forward+rewrite)
    // 中途半端な 2 番目のフレームヘッダだけ (preamble + len_hi のみ)
    try input.appendSlice(a, &.{ 0xD3, 0x00 });

    var captured: std.ArrayListUnmanaged(u8) = .{};
    const writer = CaptureWriter{ .buf = &captured, .alloc = a };
    var rover = makeTestRover(a);

    const consumed = try forwardFiltered(writer, input.items, &rover, null);
    try testing.expectEqual(@as(usize, 9), consumed);
    try testing.expectEqual(@as(u64, 1), rover.frames_forwarded);
}

test "vrs: handleGgaLine parses standard $GPGGA" {
    var rover = makeTestRover(testing.allocator);
    // 4807.038 (ddmm.mmmm) → 48 + 7.038/60 = 48.1173°
    // 01131.000 (dddmm.mmmm) → 11 + 31.000/60 = 11.5167°
    const line = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n";
    handleGgaLine(null, &rover, line);
    try testing.expect(rover.has_position);
    try testing.expectApproxEqAbs(@as(f64, 48.1173), rover.lat_deg, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 11.5167), rover.lon_deg, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 545.4), rover.alt_m, 0.01);
}

test "vrs: handleGgaLine handles $GNGGA (multi-GNSS prefix)" {
    var rover = makeTestRover(testing.allocator);
    const line = "$GNGGA,000000.00,3530.0000,N,13730.0000,E,1,08,0.9,10.5,M,46.9,M,,*XX\r\n";
    handleGgaLine(null, &rover, line);
    try testing.expect(rover.has_position);
    try testing.expectApproxEqAbs(@as(f64, 35.5), rover.lat_deg, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 137.5), rover.lon_deg, 0.001);
}

test "vrs: handleGgaLine ignores non-GGA NMEA" {
    var rover = makeTestRover(testing.allocator);
    handleGgaLine(null, &rover, "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n");
    try testing.expect(!rover.has_position);
}

test "vrs: handleGgaLine ignores garbage" {
    var rover = makeTestRover(testing.allocator);
    handleGgaLine(null, &rover, "garbage line\r\n");
    try testing.expect(!rover.has_position);
    handleGgaLine(null, &rover, "");
    try testing.expect(!rover.has_position);
}

test "vrs: encodeMsg1005 + parseMsg1005 roundtrip preserves 12-bit ref_id" {
    // Phase 4 既知バグの regression: inject1005 が 0x4000 marker bit を立てて
    // いたが ref_id は 12-bit field なので silent truncate されて rover からは
    // ref_id=1 にしか見えなかった。修正後は 12-bit 内に収めるので、エンコード/
    // パースで値が往復することを確認する。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // VRS 仮想マーカー範囲の上下端 + 中間値で round-trip
    const test_ids = [_]u16{ 0x800, 0x801, 0xA42, 0xFFF };
    for (test_ids) |rid| {
        const frame = try msm7.encodeMsg1005(a, rid, .{ 4212550.838, 167720.710, 4770076.851 }, true);
        // payload は frame[3..3+19]、parseMsg1005 はそこを期待
        const decoded = msm7.parseMsg1005(frame[3 .. 3 + 19]) orelse return error.ParseFailed;
        try testing.expectEqual(rid, decoded.ref_station_id);
    }
}

test "vrs: encodeMsg1005 rejects ref_id > 12 bits" {
    const buf = msm7.encodeMsg1005(testing.allocator, 0x4001, .{ 0, 0, 0 }, false);
    try testing.expectError(error.RefIdOutOfRange, buf);
}

test "vrs: encodeMsg1008 produces valid RTCM3 frame with msg_type=1008" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const frame = try msm7.encodeMsg1008(a, 0x801, "NTRIP_VRS NONE", "VRS801");
    // parseFrame should accept this frame and report msg_type 1008
    const fr = rtcm3.parseFrame(frame) orelse return error.ParseFailed;
    try testing.expectEqual(@as(u16, 1008), fr.msg_type);
    try testing.expectEqual(frame.len, fr.consumed);
    // payload size = 6 + 14 + 6 = 26 bytes、フレーム = 3 + 26 + 3 = 32 bytes
    try testing.expectEqual(@as(usize, 32), frame.len);
}

test "vrs: encodeMsg1008 rejects too-long fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "0123456789012345678901234567890123456789"; // 40 chars
    try testing.expectError(error.DescriptorTooLong, msm7.encodeMsg1008(a, 0x801, long, "x"));
    try testing.expectError(error.SerialTooLong, msm7.encodeMsg1008(a, 0x801, "x", long));
    try testing.expectError(error.RefIdOutOfRange, msm7.encodeMsg1008(a, 0x1234, "x", "y"));
}

test "vrs: parseDdmm round trip with known values" {
    // 4807.038 → 48 + 7.038/60 = 48.1173
    const lat = parseDdmm("4807.038", 2) orelse return error.ParseFailed;
    try testing.expectApproxEqAbs(@as(f64, 48.1173), lat, 0.0001);
    // 13745.6789 → 137 + 45.6789/60 = 137.7613
    const lon = parseDdmm("13745.6789", 3) orelse return error.ParseFailed;
    try testing.expectApproxEqAbs(@as(f64, 137.76132), lon, 0.00001);
}
