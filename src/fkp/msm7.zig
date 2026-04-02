//! fkp/msm7.zig — RTCM3 MSM7 (Multiple Signal Message type 7) 解析
//!
//! 対応メッセージ:
//!   1077 = GPS MSM7
//!   1087 = GLONASS MSM7
//!   1097 = Galileo MSM7
//!
//! 搬送波位相 [m] を衛星PRN・バンド別に抽出する。
//! RTCM 10403.3 Table 3.5-91 ～ 3.5-100 準拠。

const std = @import("std");
const bits = @import("bits.zig");

const BitReader = bits.BitReader;

/// GPS 周波数定数
pub const GPS_L1_FREQ: f64 = 1575.42e6; // Hz
pub const GPS_L2_FREQ: f64 = 1227.60e6; // Hz
pub const LIGHT_SPEED: f64 = 299792458.0; // m/s

/// GPS L1 波長 [m]
pub const GPS_L1_LAMBDA: f64 = LIGHT_SPEED / GPS_L1_FREQ;
/// GPS L2 波長 [m]
pub const GPS_L2_LAMBDA: f64 = LIGHT_SPEED / GPS_L2_FREQ;

/// シグナルバンド
pub const Band = enum(u8) {
    l1 = 1,
    l2 = 2,
    l5 = 5,
    unknown = 0,
};

/// GPS MSM シグナルID → Band
/// RTCM 10403.3 Table 3.5-99
fn gpsBandFromSigId(sig_id: u32) Band {
    return switch (sig_id) {
        2...8 => .l1,
        15...23 => .l2,
        24...30 => .l5,
        else => .unknown,
    };
}

/// GPS MSM シグナルID → 周波数 [Hz]
pub fn gpsFreqFromSigId(sig_id: u32) f64 {
    return switch (gpsBandFromSigId(sig_id)) {
        .l1 => GPS_L1_FREQ,
        .l2 => GPS_L2_FREQ,
        .l5 => 1176.45e6,
        .unknown => GPS_L1_FREQ,
    };
}

/// 1衛星・1シグナルの搬送波位相観測値
pub const PhaseObs = struct {
    prn: u8,
    /// 搬送波位相 [m]
    phase_m: f64,
    /// シグナル周波数 [Hz]
    freq_hz: f64,
    /// バンド (L1/L2/L5)
    band: Band,
};

/// MSM7 共通ヘッダー
pub const Msm7Header = struct {
    ref_station_id: u16,
    epoch_time: u32,
    /// 衛星マスク (bit63=PRN1, bit0=PRN64)
    sat_mask: u64,
    /// シグナルマスク (bit31=SigID1, bit0=SigID32)
    sig_mask: u32,
    nsat: u32,
    nsig: u32,
    ncell: u32,
};

/// 64bit マスクのポップカウント
fn popcount64(x: u64) u32 {
    return @popCount(x);
}

/// 32bit マスクのポップカウント
fn popcount32(x: u32) u32 {
    return @popCount(x);
}

/// MSM7 ヘッダーをパース（ペイロード先頭から）
/// payload: RTCM3 フレームのペイロード全体（msg_type 12bit を含む）
pub fn parseMsm7Header(payload: []const u8) ?Msm7Header {
    if (payload.len < 19) return null;
    var br = BitReader.init(payload);

    _ = br.readU(12); // message number
    const ref_id: u16 = @truncate(br.readU(12));
    const epoch: u32 = @truncate(br.readU(30));
    br.skip(1); // multiple message bit
    br.skip(3); // IODS
    br.skip(7); // reserved
    br.skip(2); // clock steering indicator
    br.skip(2); // external clock indicator
    br.skip(1); // GNSS smoothing indicator
    br.skip(3); // GNSS smoothing interval

    const sat_mask: u64 = br.readU(64);
    const sig_mask: u32 = @truncate(br.readU(32));

    const nsat = popcount64(sat_mask);
    const nsig = popcount32(sig_mask);
    if (nsat == 0 or nsig == 0) return null;
    const ncell = nsat * nsig;
    if (ncell > 128) return null; // 安全上限

    return .{
        .ref_station_id = ref_id,
        .epoch_time = epoch,
        .sat_mask = sat_mask,
        .sig_mask = sig_mask,
        .nsat = nsat,
        .nsig = nsig,
        .ncell = ncell,
    };
}

/// MSM7 ペイロードから搬送波位相観測値リストを抽出する。
/// payload: RTCM3 フレームのペイロード（msg_type 12bit から始まる）
/// allocator: 結果スライス用
pub fn extractPhase(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]PhaseObs {
    if (payload.len < 19) return &.{};
    var br = BitReader.init(payload);

    // ── ヘッダー ──────────────────────────────────────────────────────
    _ = br.readU(12); // message number
    _ = br.readU(12); // ref station id
    _ = br.readU(30); // epoch time
    br.skip(1 + 3 + 7 + 2 + 2 + 1 + 3); // misc

    const sat_mask: u64 = br.readU(64);
    const sig_mask: u32 = @truncate(br.readU(32));
    const nsat = popcount64(sat_mask);
    const nsig = popcount32(sig_mask);
    if (nsat == 0 or nsig == 0) return &.{};
    const ncell = nsat * nsig;
    if (ncell > 128) return &.{};

    // PRN リスト (sat_mask bit63=PRN1, bit62=PRN2, ...)
    var prns: [64]u8 = undefined;
    var prn_count: usize = 0;
    {
        var bit: u6 = 63;
        while (true) {
            if (sat_mask & (@as(u64, 1) << bit) != 0) {
                prns[prn_count] = @as(u8, 64 - bit);
                prn_count += 1;
            }
            if (bit == 0) break;
            bit -= 1;
        }
    }

    // シグナルID リスト (sig_mask bit31=SigID1, bit30=SigID2, ...)
    var sig_ids: [32]u32 = undefined;
    var sig_count: usize = 0;
    {
        var bit: u5 = 31;
        while (true) {
            if (sig_mask & (@as(u32, 1) << bit) != 0) {
                sig_ids[sig_count] = 32 - @as(u32, bit);
                sig_count += 1;
            }
            if (bit == 0) break;
            bit -= 1;
        }
    }

    // ── セルマスク ────────────────────────────────────────────────────
    var cell_valid: [128]bool = [1]bool{false} ** 128;
    var ncell_valid: usize = 0;
    for (0..ncell) |i| {
        cell_valid[i] = br.readU(1) == 1;
        if (cell_valid[i]) ncell_valid += 1;
    }

    // ── サテライトデータ (MSM7: 8+4+10+14 = 36 bits per sat) ────────
    var rough_int: [64]u8 = undefined;
    var rough_mod: [64]u32 = undefined;
    for (0..nsat) |i| {
        rough_int[i] = @truncate(br.readU(8));
        br.skip(4); // extended satellite info
        rough_mod[i] = @truncate(br.readU(10));
        br.skip(14); // rough phase range rate
    }

    // ── シグナルデータ (MSM7: 20+24+10+1+10+15 = 80 bits per cell) ──
    var obs_list = std.ArrayList(PhaseObs){};
    defer obs_list.deinit(allocator);

    for (0..nsat) |si| {
        for (0..nsig) |gi| {
            const cell_idx = si * nsig + gi;
            const valid = cell_valid[cell_idx];

            const fine_pseudo = br.readS(20);
            _ = fine_pseudo;
            const fine_phase = br.readS(24);
            br.skip(10); // lock time indicator
            br.skip(1); // half-cycle ambiguity
            br.skip(10); // CNR
            br.skip(15); // fine phase range rate

            if (!valid) continue;
            if (rough_int[si] == 255) continue; // RTCM3 invalid sentinel
            if (fine_phase == -(1 << 23)) continue; // invalid fine phase

            // 搬送波位相 [m]
            // rough_range [ms] = rough_int + rough_mod * 2^-10
            const rough_ms: f64 =
                @as(f64, @floatFromInt(rough_int[si])) +
                @as(f64, @floatFromInt(rough_mod[si])) * (1.0 / 1024.0);
            // fine_phase 解像度: 2^-29 ms
            const fine_ms: f64 = @as(f64, @floatFromInt(fine_phase)) * (1.0 / @as(f64, 1 << 29));
            const phase_ms: f64 = rough_ms + fine_ms;
            const phase_m: f64 = phase_ms * 1e-3 * LIGHT_SPEED;

            const sig_id = if (gi < sig_count) sig_ids[gi] else 2;
            const freq = gpsFreqFromSigId(sig_id);
            const band = gpsBandFromSigId(sig_id);

            try obs_list.append(allocator, .{
                .prn = prns[si],
                .phase_m = phase_m,
                .freq_hz = freq,
                .band = band,
            });
        }
    }

    return try obs_list.toOwnedSlice(allocator);
}

// ── 1005/1006 基準局座標 ──────────────────────────────────────────────────────

/// RTCM MSG 1005 / 1006 から抽出した基準局座標
pub const StationCoord = struct {
    ref_station_id: u16,
    /// ECEF 座標 [m]
    x: f64,
    y: f64,
    z: f64,
    /// WGS84 地理座標 [rad]
    lat: f64,
    lon: f64,
};

/// MSG 1005 ペイロードから基準局 ECEF 座標を抽出する。
/// payload: RTCM3 フレームのペイロード（msg_type 12bit から始まる）
pub fn parseMsg1005(payload: []const u8) ?StationCoord {
    // 最小: 12+12+6+4+38+2+38+1+38 = 151 bits = 19 bytes
    if (payload.len < 19) return null;
    var br = BitReader.init(payload);

    _ = br.readU(12); // message number
    const ref_id: u16 = @truncate(br.readU(12));
    br.skip(6); // ITRF realization year
    br.skip(1); // GPS indicator
    br.skip(1); // GLONASS indicator
    br.skip(1); // Galileo indicator
    br.skip(1); // reference station indicator

    const x_raw = br.readS(38);
    br.skip(1); // single receiver oscillator indicator
    br.skip(1); // reserved
    const y_raw = br.readS(38);
    br.skip(1); // quarter cycle indicator
    const z_raw = br.readS(38);

    const x: f64 = @as(f64, @floatFromInt(x_raw)) * 0.0001;
    const y: f64 = @as(f64, @floatFromInt(y_raw)) * 0.0001;
    const z: f64 = @as(f64, @floatFromInt(z_raw)) * 0.0001;

    const ll = ecefToLatLon(x, y, z);
    return .{
        .ref_station_id = ref_id,
        .x = x,
        .y = y,
        .z = z,
        .lat = ll[0],
        .lon = ll[1],
    };
}

/// ECEF → WGS84 緯度経度 [rad, rad]（Bowring 反復法）
pub fn ecefToLatLon(x: f64, y: f64, z: f64) [2]f64 {
    const a: f64 = 6378137.0;
    const e2: f64 = 0.00669437999014;
    const b: f64 = a * @sqrt(1.0 - e2);
    const ep2: f64 = (a * a - b * b) / (b * b);
    const p = @sqrt(x * x + y * y);
    const lon = std.math.atan2(y, x);
    // 初期値（球面近似）
    var lat = std.math.atan2(z, p * (1.0 - e2));
    for (0..10) |_| {
        const s = @sin(lat);
        const c = @cos(lat);
        const N = a / @sqrt(1.0 - e2 * s * s);
        lat = std.math.atan2(z + ep2 * b * s * s * s, p - e2 * N * c * c * c);
    }
    return .{ lat, lon };
}
