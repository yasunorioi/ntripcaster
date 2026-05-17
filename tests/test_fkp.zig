//! tests/test_fkp.zig — FKP エンジン + MSM7 + Type59 のユニットテスト

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const fkp_bits = ntripcaster.fkp.bits;
const fkp_msm7 = ntripcaster.fkp.msm7;
const fkp_engine = ntripcaster.fkp.engine;
const fkp_type59 = ntripcaster.fkp.type59;

// ── BitReader / BitWriter ─────────────────────────────────────────────────────

test "fkp: BitReader reads 12-bit message type" {
    // ペイロード先頭12bit = 1077 (MSG GPS MSM7)
    // 1077 = 0x435 = 0100 0011 0101
    // byte0 = 0b01000011 = 0x43
    // byte1 = 0b01010000 = 0x50 (上位4bit)
    const payload = [_]u8{ 0x43, 0x50, 0x00 };
    var br = fkp_bits.BitReader.init(&payload);
    try std.testing.expectEqual(@as(u64, 1077), br.readU(12));
}

test "fkp: BitWriter/BitReader roundtrip 30-bit TOW" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tow: u32 = 432000000; // 5日目 0:00 [ms]
    var buf = [_]u8{0} ** 8;
    var bw = fkp_bits.BitWriter.init(&buf);
    bw.writeU(30, tow);

    var br = fkp_bits.BitReader.init(&buf);
    try std.testing.expectEqual(@as(u64, tow), br.readU(30));
}

// ── MSM7 解析 ─────────────────────────────────────────────────────────────────

test "fkp: parseMsm7Header returns null for too-short payload" {
    const short = [_]u8{0xD3} ** 10;
    try std.testing.expect(fkp_msm7.parseMsm7Header(&short) == null);
}

test "fkp: parseMsg1005 returns null for too-short payload" {
    const short = [_]u8{0} ** 10;
    try std.testing.expect(fkp_msm7.parseMsg1005(&short) == null);
}

test "fkp: ecefToLatLon Tokyo approximate" {
    // 東京付近 ECEF (概算)
    // lat ≈ 35.68° N, lon ≈ 139.69° E
    const x: f64 = -3959730.0;
    const y: f64 = 3352966.0;
    const z: f64 = 3697212.0;
    const ll = fkp_msm7.ecefToLatLon(x, y, z);
    const lat_deg = ll[0] * 180.0 / std.math.pi;
    const lon_deg = ll[1] * 180.0 / std.math.pi;
    // 誤差 1度以内であることを確認
    try std.testing.expect(@abs(lat_deg - 35.68) < 1.0);
    try std.testing.expect(@abs(lon_deg - 139.69) < 1.0);
}

test "fkp: gpsFreqFromSigId L1/L2 correct" {
    // SigID 2 = L1C → 1575.42 MHz
    try std.testing.expectApproxEqAbs(
        @as(f64, 1575.42e6),
        fkp_msm7.gpsFreqFromSigId(2),
        1.0,
    );
    // SigID 16 = L2C → 1227.60 MHz
    try std.testing.expectApproxEqAbs(
        @as(f64, 1227.60e6),
        fkp_msm7.gpsFreqFromSigId(16),
        1.0,
    );
}

// ── FKP エンジン ──────────────────────────────────────────────────────────────

test "fkp: invert2x2 identity matrix" {
    // I = [[1,0],[0,1]] → I^-1 = [[1,0],[0,1]]
    const inv = fkp_engine.invert2x2(1.0, 0.0, 0.0, 1.0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), inv[0][0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), inv[0][1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), inv[1][0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), inv[1][1], 1e-10);
}

test "fkp: invert2x2 singular matrix returns null" {
    // 行列式 = 0 → null
    try std.testing.expect(fkp_engine.invert2x2(1.0, 2.0, 2.0, 4.0) == null);
}

test "fkp: invert2x2 known case" {
    // A = [[2,1],[5,3]] → A^-1 = [[3,-1],[-5,2]]
    const inv = fkp_engine.invert2x2(2.0, 1.0, 5.0, 3.0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), inv[0][0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), inv[0][1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -5.0), inv[1][0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), inv[1][1], 1e-10);
}

test "fkp: computeFkp requires at least 3 stations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try fkp_engine.computeFkp(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "fkp: computeFkp 3-station synthetic data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 北海道3局の地理座標 [rad]
    const deg = std.math.pi / 180.0;
    const coord_a = fkp_msm7.StationCoord{
        .ref_station_id = 1,
        .x = 0,
        .y = 0,
        .z = 0, // ECEFは未使用
        .lat = 44.80 * deg,
        .lon = 142.06 * deg,
    };
    const coord_b = fkp_msm7.StationCoord{
        .ref_station_id = 2,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 43.80 * deg,
        .lon = 142.43 * deg,
    };
    const coord_c = fkp_msm7.StationCoord{
        .ref_station_id = 3,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 43.58 * deg,
        .lon = 142.00 * deg,
    };

    // 合成観測値（PRN 5 のみ）
    const obs_a = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20e6, .l2_m = 20e6 * (1227.60 / 1575.42) }};
    const obs_b = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20e6 + 1.0, .l2_m = 20e6 * (1227.60 / 1575.42) + 0.8 }};
    const obs_c = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20e6 - 0.5, .l2_m = 20e6 * (1227.60 / 1575.42) - 0.4 }};

    const stations = [_]fkp_engine.StationObs{
        .{ .coord = coord_a, .obs = &obs_a },
        .{ .coord = coord_b, .obs = &obs_b },
        .{ .coord = coord_c, .obs = &obs_c },
    };

    const fkp = try fkp_engine.computeFkp(alloc, &stations);
    try std.testing.expectEqual(@as(usize, 1), fkp.len);
    try std.testing.expectEqual(@as(u8, 5), fkp[0].prn);
    // 数値は合成データなので有限値であることだけ確認
    try std.testing.expect(std.math.isFinite(fkp[0].n_i));
    try std.testing.expect(std.math.isFinite(fkp[0].e_i));
    try std.testing.expect(std.math.isFinite(fkp[0].n_0));
    try std.testing.expect(std.math.isFinite(fkp[0].e_0));
}

test "fkp: ALPHA + BETA coefficients sum" {
    // alpha - beta = 1 (ionosphere-free 係数の性質)
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.0),
        fkp_engine.ALPHA - fkp_engine.BETA,
        1e-6,
    );
}

// ── Type 59 エンコード/デコード ────────────────────────────────────────────────

test "fkp: encodeType59 produces valid RTCM3 frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const params = [_]fkp_engine.FkpParam{
        .{ .prn = 5, .n_i = 0.01, .e_i = -0.02, .n_0 = 1.5, .e_0 = -0.8 },
        .{ .prn = 10, .n_i = 0.0, .e_i = 0.0, .n_0 = 0.0, .e_0 = 0.0 },
    };

    const frame = try fkp_type59.encodeType59(arena.allocator(), 42, 432000000, &params);

    // フレーム先頭は 0xD3
    try std.testing.expectEqual(@as(u8, 0xD3), frame[0]);

    // CRC 検証（rtcm3.parseFrame 経由）
    const parse_result = ntripcaster.ntrip.rtcm3.parseFrame(frame);
    try std.testing.expect(parse_result != null);
    try std.testing.expectEqual(@as(u16, 59), parse_result.?.msg_type);
}

test "fkp: encodeType59 / decodeType59 roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const params = [_]fkp_engine.FkpParam{
        .{ .prn = 3, .n_i = 0.001, .e_i = -0.002, .n_0 = 0.5, .e_0 = -0.3 },
    };

    const frame = try fkp_type59.encodeType59(alloc, 1, 100000, &params);
    const decoded = try fkp_type59.decodeType59(alloc, frame);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(@as(u8, 3), decoded[0].prn);
    // スケーリング誤差以内（1 LSB 分）
    try std.testing.expectApproxEqAbs(params[0].n_i, decoded[0].n_i, 1.0 / fkp_type59.SCALE_I);
    try std.testing.expectApproxEqAbs(params[0].n_0, decoded[0].n_0, 1.0 / fkp_type59.SCALE_0);
}

test "fkp: encodeType59 empty params produces minimal frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const frame = try fkp_type59.encodeType59(arena.allocator(), 0, 0, &.{});
    try std.testing.expect(frame.len >= 6); // header(3) + min_payload + CRC(3)
}

// ── Bug 1 修正確認: ECEF → WGS84 往復精度 ───────────────────────────────────

/// WGS-84 前向き変換（緯度経度→ECEF）テストヘルパー
fn latLonToEcef(lat: f64, lon: f64, h: f64) [3]f64 {
    const a: f64 = 6378137.0;
    const e2: f64 = 0.00669437999014;
    const s = @sin(lat);
    const c = @cos(lat);
    const N = a / @sqrt(1.0 - e2 * s * s);
    return .{
        (N + h) * c * @cos(lon),
        (N + h) * c * @sin(lon),
        (N * (1.0 - e2) + h) * s,
    };
}

test "fkp: ecefToLatLon Nakagawa roundtrip (44.80N 142.06E)" {
    const deg = std.math.pi / 180.0;
    const lat0 = 44.80 * deg;
    const lon0 = 142.06 * deg;
    const ecef = latLonToEcef(lat0, lon0, 0.0);
    const ll = fkp_msm7.ecefToLatLon(ecef[0], ecef[1], ecef[2]);
    // 往復誤差 1e-8 rad 以内 (≈ 0.0001 mm)
    try std.testing.expectApproxEqAbs(lat0, ll[0], 1e-8);
    try std.testing.expectApproxEqAbs(lon0, ll[1], 1e-8);
}

test "fkp: ecefToLatLon Asahikawa roundtrip (43.80N 142.43E)" {
    const deg = std.math.pi / 180.0;
    const lat0 = 43.80 * deg;
    const lon0 = 142.43 * deg;
    const ecef = latLonToEcef(lat0, lon0, 0.0);
    const ll = fkp_msm7.ecefToLatLon(ecef[0], ecef[1], ecef[2]);
    try std.testing.expectApproxEqAbs(lat0, ll[0], 1e-8);
    try std.testing.expectApproxEqAbs(lon0, ll[1], 1e-8);
}

test "fkp: ecefToLatLon Akabira roundtrip (43.58N 142.00E)" {
    const deg = std.math.pi / 180.0;
    const lat0 = 43.58 * deg;
    const lon0 = 142.00 * deg;
    const ecef = latLonToEcef(lat0, lon0, 0.0);
    const ll = fkp_msm7.ecefToLatLon(ecef[0], ecef[1], ecef[2]);
    try std.testing.expectApproxEqAbs(lat0, ll[0], 1e-8);
    try std.testing.expectApproxEqAbs(lon0, ll[1], 1e-8);
}

test "fkp: ecefToLatLon Tokyo precise (35.69N 139.69E)" {
    // 東京付近（VLBI観測点近似）
    const deg = std.math.pi / 180.0;
    const lat0 = 35.69 * deg;
    const lon0 = 139.69 * deg;
    const ecef = latLonToEcef(lat0, lon0, 40.0); // h=40m
    const ll = fkp_msm7.ecefToLatLon(ecef[0], ecef[1], ecef[2]);
    try std.testing.expectApproxEqAbs(lat0, ll[0], 1e-7);
    try std.testing.expectApproxEqAbs(lon0, ll[1], 1e-7);
}

// ── Bug 2 確認: FKP スケール合理性 ──────────────────────────────────────────

test "fkp: computeFkp Hokkaido synthetic scale check" {
    // Bug 1 修正後、FKP パラメータが合理的な範囲に収まることを確認。
    // 北海道3局の実座標 + 現実的な電離層差（~10mm/100km）を使用。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const deg = std.math.pi / 180.0;
    // 実際の座標（修正済み ecefToLatLon で計算した値と整合）
    const coord_a = fkp_msm7.StationCoord{
        .ref_station_id = 1,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 44.80 * deg,
        .lon = 142.06 * deg,
    };
    const coord_b = fkp_msm7.StationCoord{
        .ref_station_id = 2,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 43.80 * deg,
        .lon = 142.43 * deg,
    };
    const coord_c = fkp_msm7.StationCoord{
        .ref_station_id = 3,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 43.58 * deg,
        .lon = 142.00 * deg,
    };

    // 典型的な電離層差: ~5mm/100km × 基線長
    // Δlat_B ≈ 110km, Δlat_C ≈ 135km → ΔL_GF ≈ 5mm, 7mm
    const obs_a = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20000000.0, .l2_m = 15604000.0 }};
    const obs_b = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20000005.5, .l2_m = 15604004.3 }};
    const obs_c = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20000007.0, .l2_m = 15604005.5 }};

    const stations = [_]fkp_engine.StationObs{
        .{ .coord = coord_a, .obs = &obs_a },
        .{ .coord = coord_b, .obs = &obs_b },
        .{ .coord = coord_c, .obs = &obs_c },
    };

    const fkp = try fkp_engine.computeFkp(alloc, &stations);
    try std.testing.expectEqual(@as(usize, 1), fkp.len);
    // 有限値であること
    try std.testing.expect(std.math.isFinite(fkp[0].n_i));
    try std.testing.expect(std.math.isFinite(fkp[0].n_0));
    // Bug 2 チェック: 桁外れ(>10^6)でないこと
    try std.testing.expect(@abs(fkp[0].n_i) < 1.0e6);
    try std.testing.expect(@abs(fkp[0].n_0) < 1.0e6);
}

// ── Phase 5b-0: extractPhase の cell_mask=false bit offset 修正 ─────────────

/// extractPhase が返すべき phase_m を rough_int / rough_mod / fine_phase から再計算する。
fn expectedPhaseM(rough_int: u32, rough_mod: u32, fine_phase: i64) f64 {
    const c: f64 = 299792458.0;
    const rough_ms = @as(f64, @floatFromInt(rough_int)) +
        @as(f64, @floatFromInt(rough_mod)) * (1.0 / 1024.0);
    const fine_ms = @as(f64, @floatFromInt(fine_phase)) * (1.0 / @as(f64, 1 << 29));
    return (rough_ms + fine_ms) * 1e-3 * c;
}

/// テスト用に MSM7 ヘッダー (sat_mask=PRN1..3, sig_mask=L1C+L2C) を payload 先頭に書く。
fn writeMsm7TestHeader(bw: *fkp_bits.BitWriter) void {
    bw.writeU(12, 1077); // GPS MSM7
    bw.writeU(12, 0x123); // ref_id
    bw.writeU(30, 432000000); // epoch
    bw.writeU(1, 0);
    bw.writeU(3, 0);
    bw.writeU(7, 0);
    bw.writeU(2, 0);
    bw.writeU(2, 0);
    bw.writeU(1, 0);
    bw.writeU(3, 0);
    // sat_mask: PRN 1, 2, 3 (bit 63, 62, 61)
    bw.writeU(64, (@as(u64, 1) << 63) | (@as(u64, 1) << 62) | (@as(u64, 1) << 61));
    // sig_mask: SigID 2 (L1C), 16 (L2C) → bit 30, 16
    bw.writeU(32, (@as(u32, 1) << 30) | (@as(u32, 1) << 16));
}

test "fkp: extractPhase full cell_mask returns all 6 observations" {
    // 全 cell valid (nsat=3, nsig=2 → ncell=6) の既存挙動 regression。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var payload = [_]u8{0} ** 96;
    var bw = fkp_bits.BitWriter.init(&payload);
    writeMsm7TestHeader(&bw);

    // cell_mask: 全 valid
    for (0..6) |_| bw.writeU(1, 1);

    // sat data (PRN1 / PRN2 / PRN3 でユニークな rough)
    bw.writeU(8, 70);
    bw.writeU(4, 0);
    bw.writeU(10, 512);
    bw.writeS(14, 0);
    bw.writeU(8, 71);
    bw.writeU(4, 0);
    bw.writeU(10, 256);
    bw.writeS(14, 0);
    bw.writeU(8, 72);
    bw.writeU(4, 0);
    bw.writeU(10, 128);
    bw.writeS(14, 0);

    // signal data: 6 cell × 80 bit、それぞれ distinct な fine_phase
    const fps = [_]i64{ 100000, 110000, 200000, 210000, 300000, 310000 };
    for (fps) |fp| {
        bw.writeS(20, 0);
        bw.writeS(24, fp);
        bw.writeU(10, 0);
        bw.writeU(1, 0);
        bw.writeU(10, 0);
        bw.writeS(15, 0);
    }

    const obs = try fkp_msm7.extractPhase(alloc, &payload);
    try std.testing.expectEqual(@as(usize, 6), obs.len);

    // (si, gi) ループ順: (0,0)(0,1)(1,0)(1,1)(2,0)(2,1)
    const expected = [_]struct { prn: u8, band: fkp_msm7.Band, rough_int: u32, rough_mod: u32, fp: i64 }{
        .{ .prn = 1, .band = .l1, .rough_int = 70, .rough_mod = 512, .fp = 100000 },
        .{ .prn = 1, .band = .l2, .rough_int = 70, .rough_mod = 512, .fp = 110000 },
        .{ .prn = 2, .band = .l1, .rough_int = 71, .rough_mod = 256, .fp = 200000 },
        .{ .prn = 2, .band = .l2, .rough_int = 71, .rough_mod = 256, .fp = 210000 },
        .{ .prn = 3, .band = .l1, .rough_int = 72, .rough_mod = 128, .fp = 300000 },
        .{ .prn = 3, .band = .l2, .rough_int = 72, .rough_mod = 128, .fp = 310000 },
    };
    for (expected, 0..) |e, i| {
        try std.testing.expectEqual(e.prn, obs[i].prn);
        try std.testing.expectEqual(e.band, obs[i].band);
        try std.testing.expectApproxEqAbs(
            expectedPhaseM(e.rough_int, e.rough_mod, e.fp),
            obs[i].phase_m,
            1e-4,
        );
    }
}

test "fkp: extractPhase partial cell_mask preserves bit offset" {
    // Phase 5b-0 修正の核心テスト:
    //   RTCM 10403.3 MSM 仕様では signal data block は cell_mask=1 の cell 分のみ存在。
    //   修正前は invalid cell の 80 bit も読み飛ばしていたため、後続 valid cell の
    //   phase 値が前後ズレを起こす。distinct な fine_phase で bit offset 整合を検出。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var payload = [_]u8{0} ** 96;
    var bw = fkp_bits.BitWriter.init(&payload);
    writeMsm7TestHeader(&bw);

    // cell_mask: (PRN1,L1)=1, (PRN1,L2)=0, (PRN2,L1)=1, (PRN2,L2)=1, (PRN3,L1)=0, (PRN3,L2)=1
    //   → ncell_valid = 4
    bw.writeU(1, 1);
    bw.writeU(1, 0);
    bw.writeU(1, 1);
    bw.writeU(1, 1);
    bw.writeU(1, 0);
    bw.writeU(1, 1);

    bw.writeU(8, 70);
    bw.writeU(4, 0);
    bw.writeU(10, 512);
    bw.writeS(14, 0);
    bw.writeU(8, 71);
    bw.writeU(4, 0);
    bw.writeU(10, 256);
    bw.writeS(14, 0);
    bw.writeU(8, 72);
    bw.writeU(4, 0);
    bw.writeU(10, 128);
    bw.writeS(14, 0);

    // signal data: valid cell 4 個分のみ (仕様準拠)
    const fps = [_]i64{ 100000, 200000, 300000, 400000 };
    for (fps) |fp| {
        bw.writeS(20, 0);
        bw.writeS(24, fp);
        bw.writeU(10, 0);
        bw.writeU(1, 0);
        bw.writeU(10, 0);
        bw.writeS(15, 0);
    }

    const obs = try fkp_msm7.extractPhase(alloc, &payload);
    try std.testing.expectEqual(@as(usize, 4), obs.len);

    // (si, gi) ループ順から valid cell だけ拾った場合:
    //   (0,0) PRN1L1 → block0 (fp=100000)
    //   (1,0) PRN2L1 → block1 (fp=200000)
    //   (1,1) PRN2L2 → block2 (fp=300000)
    //   (2,1) PRN3L2 → block3 (fp=400000)
    const expected = [_]struct { prn: u8, band: fkp_msm7.Band, rough_int: u32, rough_mod: u32, fp: i64 }{
        .{ .prn = 1, .band = .l1, .rough_int = 70, .rough_mod = 512, .fp = 100000 },
        .{ .prn = 2, .band = .l1, .rough_int = 71, .rough_mod = 256, .fp = 200000 },
        .{ .prn = 2, .band = .l2, .rough_int = 71, .rough_mod = 256, .fp = 300000 },
        .{ .prn = 3, .band = .l2, .rough_int = 72, .rough_mod = 128, .fp = 400000 },
    };
    for (expected, 0..) |e, i| {
        try std.testing.expectEqual(e.prn, obs[i].prn);
        try std.testing.expectEqual(e.band, obs[i].band);
        try std.testing.expectApproxEqAbs(
            expectedPhaseM(e.rough_int, e.rough_mod, e.fp),
            obs[i].phase_m,
            1e-4,
        );
    }
}
