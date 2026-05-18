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
const BitWriter = bits.BitWriter;

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
    /// 搬送波位相 [m] = (rough_int + rough_mod/1024 + fine_phase·2^-29) × c × 1e-3
    phase_m: f64,
    /// rough pseudorange [m] = (rough_int + rough_mod/1024) × c × 1e-3。
    /// Phase 6b で `phase_m - rough_range_m` を residual として SD/DD に
    /// 投入し、衛星-局の geometric range (km scale) を消すために使う。
    rough_range_m: f64,
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
                prns[prn_count] = 64 - @as(u8, bit);
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
    // RTCM 10403.3 § 3.5.16 準拠: signal data block は cell_mask=1 の cell 分のみ存在
    // (= ncell_valid 個)。invalid cell の 80 bit を読み飛ばすと bit offset がズレるので、
    // valid 判定は readS の前に行う。
    var obs_list = std.ArrayList(PhaseObs){};
    defer obs_list.deinit(allocator);

    for (0..nsat) |si| {
        for (0..nsig) |gi| {
            const cell_idx = si * nsig + gi;
            if (!cell_valid[cell_idx]) continue;

            const fine_pseudo = br.readS(20);
            _ = fine_pseudo;
            const fine_phase = br.readS(24);
            br.skip(10); // lock time indicator
            br.skip(1); // half-cycle ambiguity
            br.skip(10); // CNR
            br.skip(15); // fine phase range rate

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
            const rough_range_m: f64 = rough_ms * 1e-3 * LIGHT_SPEED;

            const sig_id = if (gi < sig_count) sig_ids[gi] else 2;
            const freq = gpsFreqFromSigId(sig_id);
            const band = gpsBandFromSigId(sig_id);

            try obs_list.append(allocator, .{
                .prn = prns[si],
                .phase_m = phase_m,
                .rough_range_m = rough_range_m,
                .freq_hz = freq,
                .band = band,
            });
        }
    }

    return try obs_list.toOwnedSlice(allocator);
}

// ── 位相補正適用 (Phase 5b-1) ─────────────────────────────────────────────────

/// 1 (PRN, Band) 組に対する位相補正値 [m]。
pub const PhaseDelta = struct {
    prn: u8,
    band: Band,
    /// 加算する位相値 [m]
    delta_m: f64,
};

/// MSM7 フレームの phase 観測値を `deltas` で in-place 書き換え、CRC-24Q を
/// 再計算する。`frame` は preamble..CRC を含む完全な RTCM3 フレーム全体。
///
/// `deltas` 配列にエントリのない (PRN, Band) は変更しない。
/// 該当 cell の `cell_mask==false` / `fine_phase==invalid sentinel` /
/// `rough_int==255` も変更しない (保守的にスキップ)。
///
/// Errors:
///   - `error.InvalidFrame`: フレーム長 / preamble / payload 長が不正
///   - `error.NotMsm7`: メッセージタイプが MSM7 (1077/1087/1097) でない
pub fn applyPhaseCorrection(
    frame: []u8,
    deltas: []const PhaseDelta,
) !void {
    // ── フレーム形式チェック ────────────────────────────────────────
    if (frame.len < 6) return error.InvalidFrame;
    if (frame[0] != 0xD3) return error.InvalidFrame;
    const payload_len: usize =
        (@as(usize, frame[1] & 0x03) << 8) | frame[2];
    if (frame.len < 3 + payload_len + 3) return error.InvalidFrame;
    if (payload_len < 19) return error.InvalidFrame;

    const payload = frame[3 .. 3 + payload_len];

    // msg_type は payload 先頭 12 bit
    const msg_type: u16 = (@as(u16, payload[0]) << 4) | (payload[1] >> 4);
    if (msg_type != 1077 and msg_type != 1087 and msg_type != 1097) {
        return error.NotMsm7;
    }

    // ── ヘッダー解析 (extractPhase と同じロジック) ─────────────────
    var br = BitReader.init(payload);
    _ = br.readU(12); // message number
    _ = br.readU(12); // ref station id
    _ = br.readU(30); // epoch time
    br.skip(1 + 3 + 7 + 2 + 2 + 1 + 3); // misc
    const sat_mask: u64 = br.readU(64);
    const sig_mask: u32 = @truncate(br.readU(32));
    const nsat = popcount64(sat_mask);
    const nsig = popcount32(sig_mask);
    if (nsat == 0 or nsig == 0) return; // 何もすることなし → CRC 再計算もスキップ
    const ncell = nsat * nsig;
    if (ncell > 128) return error.InvalidFrame;

    var prns: [64]u8 = undefined;
    var prn_count: usize = 0;
    {
        var bit: u6 = 63;
        while (true) {
            if (sat_mask & (@as(u64, 1) << bit) != 0) {
                prns[prn_count] = 64 - @as(u8, bit);
                prn_count += 1;
            }
            if (bit == 0) break;
            bit -= 1;
        }
    }
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

    // ── cell_mask ──────────────────────────────────────────────────
    var cell_valid: [128]bool = [1]bool{false} ** 128;
    for (0..ncell) |i| {
        cell_valid[i] = br.readU(1) == 1;
    }

    // ── サテライトデータ (rough_int, rough_mod を保存) ──────────────
    var rough_int: [64]u32 = undefined;
    var rough_mod: [64]u32 = undefined;
    for (0..nsat) |i| {
        rough_int[i] = @truncate(br.readU(8));
        br.skip(4); // extended satellite info
        rough_mod[i] = @truncate(br.readU(10));
        br.skip(14); // rough phase range rate
    }

    // ── シグナルデータ (cell_valid のみ 80 bit ずつ進める) ─────────
    // 1 cell の signal data 開始 bit offset を記録 → fine_phase は +20 bit 位置
    for (0..nsat) |si| {
        for (0..nsig) |gi| {
            const cell_idx = si * nsig + gi;
            if (!cell_valid[cell_idx]) continue;

            const block_start = br.bitPos();
            br.skip(20); // fine_pseudo
            const fine_phase = br.readS(24);
            br.skip(10 + 1 + 10 + 15);

            // 補正対象として無効な cell をスキップ
            if (rough_int[si] == 255) continue;
            if (fine_phase == -(@as(i64, 1) << 23)) continue;

            if (gi >= sig_count) continue;
            const prn = prns[si];
            const sig_id = sig_ids[gi];
            const band = gpsBandFromSigId(sig_id);
            if (band == .unknown) continue;
            const delta_m = findDelta(deltas, prn, band) orelse continue;

            // 現 phase_ms から新 fine_phase bits を計算
            const rough_ms: f64 =
                @as(f64, @floatFromInt(rough_int[si])) +
                @as(f64, @floatFromInt(rough_mod[si])) * (1.0 / 1024.0);
            const fine_ms_cur: f64 = @as(f64, @floatFromInt(fine_phase)) *
                (1.0 / @as(f64, 1 << 29));
            const phase_ms_new: f64 = rough_ms + fine_ms_cur +
                delta_m / (LIGHT_SPEED * 1e-3);

            const fine_ms_new: f64 = phase_ms_new - rough_ms;
            var new_fine_bits: i64 = @intFromFloat(@round(fine_ms_new * @as(f64, 1 << 29)));

            // [-2^23+1, 2^23-1] にクランプ (-2^23 = invalid sentinel を避ける)
            const MAX_FINE: i64 = (@as(i64, 1) << 23) - 1;
            const MIN_FINE: i64 = -MAX_FINE;
            if (new_fine_bits > MAX_FINE) new_fine_bits = MAX_FINE;
            if (new_fine_bits < MIN_FINE) new_fine_bits = MIN_FINE;

            // signed 24-bit を 2's complement パターンへ
            const new_fine_u: u64 = @as(u64, @bitCast(new_fine_bits)) &
                ((@as(u64, 1) << 24) - 1);
            bits.writeBitsAt(payload, block_start + 20, 24, new_fine_u);
        }
    }

    // ── CRC-24Q 再計算 ─────────────────────────────────────────────
    const rtcm3 = @import("../ntrip/rtcm3.zig");
    const new_crc = rtcm3.crc24q(frame[0 .. 3 + payload_len]);
    frame[3 + payload_len + 0] = @truncate(new_crc >> 16);
    frame[3 + payload_len + 1] = @truncate(new_crc >> 8);
    frame[3 + payload_len + 2] = @truncate(new_crc);
}

fn findDelta(deltas: []const PhaseDelta, prn: u8, band: Band) ?f64 {
    for (deltas) |d| {
        if (d.prn == prn and d.band == band) return d.delta_m;
    }
    return null;
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

/// WGS84 緯度経度高度 [rad, rad, m] → ECEF [m, m, m]
pub fn latLonAltToEcef(lat: f64, lon: f64, alt: f64) [3]f64 {
    const a: f64 = 6378137.0;
    const e2: f64 = 0.00669437999014;
    const s = @sin(lat);
    const c = @cos(lat);
    const N = a / @sqrt(1.0 - e2 * s * s);
    const x = (N + alt) * c * @cos(lon);
    const y = (N + alt) * c * @sin(lon);
    const z = (N * (1.0 - e2) + alt) * s;
    return .{ x, y, z };
}

/// RTCM3 Type 1005 (Stationary Antenna Reference Point) フレームを生成する。
/// ECEF 座標 + Reference Station ID を入力に、parseMsg1005 と対称な構造でエンコード。
///
/// `ref_station_id`: 0..4095 (12 bit)。これを超えると `error.RefIdOutOfRange`。
///   過去に 0x4000 を渡して silent truncate されるバグがあったため明示的にチェック。
/// `non_physical`: true = "Reference Station Indicator" bit を 1 にする (VRS の自己申告)
/// 返却値: 完全な RTCM3 フレーム (CRC 含む)。allocator で解放すること。
pub fn encodeMsg1005(
    allocator: std.mem.Allocator,
    ref_station_id: u16,
    ecef: [3]f64,
    non_physical: bool,
) ![]u8 {
    if (ref_station_id > 0xFFF) return error.RefIdOutOfRange;

    // payload: 12+12+6+1+1+1+1+38+1+1+38+1+38 = 151 bits = 19 bytes
    const payload_bytes: usize = 19;
    const frame_len: usize = 3 + payload_bytes + 3;
    const buf = try allocator.alloc(u8, frame_len);
    @memset(buf, 0);

    buf[0] = 0xD3;
    buf[1] = @truncate((payload_bytes >> 8) & 0x03);
    buf[2] = @truncate(payload_bytes & 0xFF);

    var bw = BitWriter.init(buf[3 .. 3 + payload_bytes]);
    bw.writeU(12, 1005); // message number
    bw.writeU(12, ref_station_id);
    bw.writeU(6, 0); // ITRF realization year
    bw.writeU(1, 1); // GPS supported
    bw.writeU(1, 1); // GLONASS supported
    bw.writeU(1, 1); // Galileo supported
    bw.writeU(1, if (non_physical) 1 else 0); // reference station indicator

    const x_q: i64 = @intFromFloat(@round(ecef[0] / 0.0001));
    const y_q: i64 = @intFromFloat(@round(ecef[1] / 0.0001));
    const z_q: i64 = @intFromFloat(@round(ecef[2] / 0.0001));

    bw.writeS(38, x_q);
    bw.writeU(1, 0); // single receiver oscillator
    bw.writeU(1, 0); // reserved
    bw.writeS(38, y_q);
    bw.writeU(1, 0); // quarter cycle indicator
    bw.writeS(38, z_q);

    // CRC-24Q
    const rtcm3 = @import("../ntrip/rtcm3.zig");
    const crc = rtcm3.crc24q(buf[0 .. 3 + payload_bytes]);
    buf[3 + payload_bytes + 0] = @truncate(crc >> 16);
    buf[3 + payload_bytes + 1] = @truncate(crc >> 8);
    buf[3 + payload_bytes + 2] = @truncate(crc);

    return buf;
}

/// RTCM3 Type 1008 (Antenna Descriptor + Serial Number) フレームを生成する。
/// 1007 (descriptor のみ) の上位互換。VRS rover に「ちゃんとした基準局」と
/// 認識させるためのメタデータ。送信頻度は低 (起動時 1 回で十分)。
///
/// payload: 12 + 12 + 8 + 8*N + 8 + 8 + 8*M = 48 + 8*(N+M) bits = 6 + N + M bytes
///   msg_num(12) + ref_id(12) + N(8) + descriptor(8*N) +
///   setup_id(8) + M(8) + serial(8*M)
pub fn encodeMsg1008(
    allocator: std.mem.Allocator,
    ref_station_id: u16,
    descriptor: []const u8,
    serial: []const u8,
) ![]u8 {
    if (ref_station_id > 0xFFF) return error.RefIdOutOfRange;
    if (descriptor.len > 31) return error.DescriptorTooLong; // RTCM 仕様上限 31
    if (serial.len > 31) return error.SerialTooLong;

    const payload_bytes: usize = 6 + descriptor.len + serial.len;
    const frame_len: usize = 3 + payload_bytes + 3;
    const buf = try allocator.alloc(u8, frame_len);
    @memset(buf, 0);

    buf[0] = 0xD3;
    buf[1] = @truncate((payload_bytes >> 8) & 0x03);
    buf[2] = @truncate(payload_bytes & 0xFF);

    var bw = BitWriter.init(buf[3 .. 3 + payload_bytes]);
    bw.writeU(12, 1008); // message number
    bw.writeU(12, ref_station_id);
    bw.writeU(8, @intCast(descriptor.len)); // descriptor counter N
    for (descriptor) |c| bw.writeU(8, c);
    bw.writeU(8, 0); // antenna setup id
    bw.writeU(8, @intCast(serial.len)); // serial counter M
    for (serial) |c| bw.writeU(8, c);

    const rtcm3 = @import("../ntrip/rtcm3.zig");
    const crc = rtcm3.crc24q(buf[0 .. 3 + payload_bytes]);
    buf[3 + payload_bytes + 0] = @truncate(crc >> 16);
    buf[3 + payload_bytes + 1] = @truncate(crc >> 8);
    buf[3 + payload_bytes + 2] = @truncate(crc);

    return buf;
}

/// ECEF → WGS84 緯度経度 [rad, rad]
///
/// 単純直接反復法（Borkowski 1989 / Bowring simple iteration）:
///   lat_{n+1} = atan2(Z + e² · N(lat_n) · sin(lat_n),  p)
///   N(lat) = a / sqrt(1 - e² · sin²(lat))
///
/// 初期値 lat_0 = atan2(Z, p)、10回で 1e-12 rad 精度に収束。
/// 旧 Bowring 式は reduced latitude θ の更新漏れにより緯度が約18°ずれる
/// バグがあったため、本実装に置き換え。
pub fn ecefToLatLon(x: f64, y: f64, z: f64) [2]f64 {
    const a: f64 = 6378137.0;
    const e2: f64 = 0.00669437999014; // WGS-84 第1離心率の二乗
    const p = @sqrt(x * x + y * y);
    const lon = std.math.atan2(y, x);
    // 初期値（球面近似）
    var lat = std.math.atan2(z, p);
    for (0..15) |_| {
        const s = @sin(lat);
        const N = a / @sqrt(1.0 - e2 * s * s);
        const lat_new = std.math.atan2(z + e2 * N * s, p);
        if (@abs(lat_new - lat) < 1e-12) {
            lat = lat_new;
            break;
        }
        lat = lat_new;
    }
    return .{ lat, lon };
}
