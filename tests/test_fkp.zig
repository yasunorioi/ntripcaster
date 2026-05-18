//! tests/test_fkp.zig — FKP エンジン + MSM7 + Type59 のユニットテスト

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const fkp_bits = ntripcaster.fkp.bits;
const fkp_msm7 = ntripcaster.fkp.msm7;
const fkp_engine = ntripcaster.fkp.engine;
const fkp_type59 = ntripcaster.fkp.type59;
const fkp_runtime = ntripcaster.fkp.runtime;
const fkp_vrs = ntripcaster.fkp.vrs;
const fkp_eph = ntripcaster.fkp.ephemeris;

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

    const result = try fkp_engine.computeFkp(arena.allocator(), &.{}, .{});
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

    // 合成観測値（PRN 5 のみ）。1.0 m / 0.8 m の delta は物理妥当範囲を
    // 超えるので Phase 6a の閾値判定は無効化 (max_magnitude=inf) する。
    // 「math が finite な出力を出すこと」だけ確認する古典 sanity test。
    const obs_a = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20e6, .l2_m = 20e6 * (1227.60 / 1575.42) }};
    const obs_b = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20e6 + 1.0, .l2_m = 20e6 * (1227.60 / 1575.42) + 0.8 }};
    const obs_c = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 20e6 - 0.5, .l2_m = 20e6 * (1227.60 / 1575.42) - 0.4 }};

    const stations = [_]fkp_engine.StationObs{
        .{ .coord = coord_a, .obs = &obs_a },
        .{ .coord = coord_b, .obs = &obs_b },
        .{ .coord = coord_c, .obs = &obs_c },
    };

    const fkp = try fkp_engine.computeFkp(alloc, &stations, .{ .max_magnitude = std.math.inf(f64) });
    try std.testing.expectEqual(@as(usize, 1), fkp.len);
    try std.testing.expectEqual(@as(u8, 5), fkp[0].prn);
    // 数値は合成データなので有限値であることだけ確認
    try std.testing.expect(std.math.isFinite(fkp[0].n_i));
    try std.testing.expect(std.math.isFinite(fkp[0].e_i));
    try std.testing.expect(std.math.isFinite(fkp[0].n_0));
    try std.testing.expect(std.math.isFinite(fkp[0].e_0));
}

// ── Phase 6a: computeFkp 閾値判定 (excess magnitude drop) ──────────────────

test "fkp: computeFkp drops PRN with excess magnitude (default threshold)" {
    // 過大な phase 差を入力 → n_0/e_0 が 100 m/rad を超え → 棄却される
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const deg = std.math.pi / 180.0;
    const coord_a = fkp_msm7.StationCoord{ .ref_station_id = 1, .x = 0, .y = 0, .z = 0, .lat = 44.80 * deg, .lon = 142.06 * deg };
    const coord_b = fkp_msm7.StationCoord{ .ref_station_id = 2, .x = 0, .y = 0, .z = 0, .lat = 43.80 * deg, .lon = 142.43 * deg };
    const coord_c = fkp_msm7.StationCoord{ .ref_station_id = 3, .x = 0, .y = 0, .z = 0, .lat = 43.58 * deg, .lon = 142.00 * deg };

    // 大きな phase 差 (m スケール) で n_0 が 1000+ m/rad に膨らむ入力
    const obs_a = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 0.0, .l2_m = 0.0 }};
    const obs_b = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 1.0, .l2_m = 0.8 }};
    const obs_c = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = -0.5, .l2_m = -0.4 }};

    const stations = [_]fkp_engine.StationObs{
        .{ .coord = coord_a, .obs = &obs_a },
        .{ .coord = coord_b, .obs = &obs_b },
        .{ .coord = coord_c, .obs = &obs_c },
    };

    var stats: fkp_engine.ComputeStats = .{};
    const fkp = try fkp_engine.computeFkp(alloc, &stations, .{ .stats = &stats });
    try std.testing.expectEqual(@as(usize, 0), fkp.len);
    try std.testing.expectEqual(@as(u32, 1), stats.dropped_excess);
}

test "fkp: computeFkp keeps PRN with sane magnitude (default threshold)" {
    // 物理妥当な mm-cm スケールの phase 差 → 閾値内なので返される
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const deg = std.math.pi / 180.0;
    const coord_a = fkp_msm7.StationCoord{ .ref_station_id = 1, .x = 0, .y = 0, .z = 0, .lat = 44.80 * deg, .lon = 142.06 * deg };
    const coord_b = fkp_msm7.StationCoord{ .ref_station_id = 2, .x = 0, .y = 0, .z = 0, .lat = 43.80 * deg, .lon = 142.43 * deg };
    const coord_c = fkp_msm7.StationCoord{ .ref_station_id = 3, .x = 0, .y = 0, .z = 0, .lat = 43.58 * deg, .lon = 142.00 * deg };

    // 物理妥当な ~mm スケール差 (10mm/100km × 100km 級基線)
    const obs_a = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 0.0, .l2_m = 0.0 }};
    const obs_b = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 0.005, .l2_m = 0.004 }};
    const obs_c = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 0.007, .l2_m = 0.0055 }};

    const stations = [_]fkp_engine.StationObs{
        .{ .coord = coord_a, .obs = &obs_a },
        .{ .coord = coord_b, .obs = &obs_b },
        .{ .coord = coord_c, .obs = &obs_c },
    };

    var stats: fkp_engine.ComputeStats = .{};
    const fkp = try fkp_engine.computeFkp(alloc, &stations, .{ .stats = &stats });
    try std.testing.expectEqual(@as(usize, 1), fkp.len);
    try std.testing.expectEqual(@as(u8, 5), fkp[0].prn);
    try std.testing.expectEqual(@as(u32, 0), stats.dropped_excess);
    // 閾値 100 以下であることを実証
    const max_abs = @max(@max(@abs(fkp[0].n_i), @abs(fkp[0].e_i)), @max(@abs(fkp[0].n_0), @abs(fkp[0].e_0)));
    try std.testing.expect(max_abs <= fkp_engine.DEFAULT_FKP_MAX_MAGNITUDE);
}

test "fkp: computeFkp custom max_magnitude threshold" {
    // 同じ入力でも閾値次第で出力/棄却が切り替わることを確認
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const deg = std.math.pi / 180.0;
    const coord_a = fkp_msm7.StationCoord{ .ref_station_id = 1, .x = 0, .y = 0, .z = 0, .lat = 44.80 * deg, .lon = 142.06 * deg };
    const coord_b = fkp_msm7.StationCoord{ .ref_station_id = 2, .x = 0, .y = 0, .z = 0, .lat = 43.80 * deg, .lon = 142.43 * deg };
    const coord_c = fkp_msm7.StationCoord{ .ref_station_id = 3, .x = 0, .y = 0, .z = 0, .lat = 43.58 * deg, .lon = 142.00 * deg };
    const obs_a = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 0.0, .l2_m = 0.0 }};
    const obs_b = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 0.005, .l2_m = 0.004 }};
    const obs_c = [_]fkp_engine.SatObs{.{ .prn = 5, .l1_m = 0.007, .l2_m = 0.0055 }};
    const stations = [_]fkp_engine.StationObs{
        .{ .coord = coord_a, .obs = &obs_a },
        .{ .coord = coord_b, .obs = &obs_b },
        .{ .coord = coord_c, .obs = &obs_c },
    };

    // 緩い閾値 (default 100) → 通過
    const fkp_loose = try fkp_engine.computeFkp(alloc, &stations, .{});
    try std.testing.expectEqual(@as(usize, 1), fkp_loose.len);

    // 厳しい閾値 (0.1 m/rad) → 棄却 (mm scale 入力でも n_0 は ~1-10 m/rad 級)
    var stats: fkp_engine.ComputeStats = .{};
    const fkp_strict = try fkp_engine.computeFkp(alloc, &stations, .{ .max_magnitude = 0.1, .stats = &stats });
    try std.testing.expectEqual(@as(usize, 0), fkp_strict.len);
    try std.testing.expectEqual(@as(u32, 1), stats.dropped_excess);
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

    // この test の入力 (Δl1 = 5.5/7.0 m) は本来 ~5mm 想定の数千倍で実用に
    // 合わない数値だが、Bug 2 (FKP scale check) の regression として残す。
    // Phase 6a の閾値は無効化して桁外れ (>10^6) でないことだけ確認。
    const fkp = try fkp_engine.computeFkp(alloc, &stations, .{ .max_magnitude = std.math.inf(f64) });
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

// ── Phase 5b-1: applyPhaseCorrection (MSM7 in-place 補正) ─────────────────

const test_rtcm3 = ntripcaster.ntrip.rtcm3;

/// Phase 5b-1 テスト用 MSM7 frame ビルダー。
/// nsat=3 (PRN1..3), nsig=2 (L1C/L2C)、全 cell valid (6 obs)、payload 96 byte。
/// fps は 6 cell ぶんの fine_phase 値 (i64)。CRC を埋め込んだ完成 frame を返す。
fn buildMsm7TestFrame(buf: *[102]u8, fps: [6]i64) usize {
    const payload_bytes: usize = 96;
    const frame_len: usize = 3 + payload_bytes + 3;
    @memset(buf[0..frame_len], 0);

    buf[0] = 0xD3;
    buf[1] = @truncate((payload_bytes >> 8) & 0x03);
    buf[2] = @truncate(payload_bytes & 0xFF);

    var bw = fkp_bits.BitWriter.init(buf[3 .. 3 + payload_bytes]);
    writeMsm7TestHeader(&bw);
    for (0..6) |_| bw.writeU(1, 1);
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
    for (fps) |fp| {
        bw.writeS(20, 0);
        bw.writeS(24, fp);
        bw.writeU(10, 0);
        bw.writeU(1, 0);
        bw.writeU(10, 0);
        bw.writeS(15, 0);
    }

    const crc = test_rtcm3.crc24q(buf[0 .. 3 + payload_bytes]);
    buf[3 + payload_bytes + 0] = @truncate(crc >> 16);
    buf[3 + payload_bytes + 1] = @truncate(crc >> 8);
    buf[3 + payload_bytes + 2] = @truncate(crc);
    return frame_len;
}

test "fkp: applyPhaseCorrection empty deltas leaves frame byte-identical" {
    // 補正対象なし → payload bit は変わらないので CRC も同じ → frame バイト列が一致。
    var frame_a: [102]u8 = undefined;
    var frame_b: [102]u8 = undefined;
    const fps = [_]i64{ 100000, 110000, 200000, 210000, 300000, 310000 };
    const len_a = buildMsm7TestFrame(&frame_a, fps);
    const len_b = buildMsm7TestFrame(&frame_b, fps);
    try std.testing.expectEqualSlices(u8, frame_a[0..len_a], frame_b[0..len_b]);

    try fkp_msm7.applyPhaseCorrection(frame_b[0..len_b], &.{});
    try std.testing.expectEqualSlices(u8, frame_a[0..len_a], frame_b[0..len_b]);
}

test "fkp: applyPhaseCorrection +0.01m on PRN1/L1 increments only that cell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var frame: [102]u8 = undefined;
    const fps = [_]i64{ 100000, 110000, 200000, 210000, 300000, 310000 };
    const len = buildMsm7TestFrame(&frame, fps);

    // 元の obs を保存
    const orig_obs = try fkp_msm7.extractPhase(alloc, frame[3 .. 3 + 96]);

    const deltas = [_]fkp_msm7.PhaseDelta{
        .{ .prn = 1, .band = .l1, .delta_m = 0.01 },
    };
    try fkp_msm7.applyPhaseCorrection(frame[0..len], &deltas);

    // CRC が parseFrame で通る (=in-place 書き換え後の整合性確認)
    const parsed = test_rtcm3.parseFrame(frame[0..len]) orelse return error.CrcFailed;
    try std.testing.expectEqual(@as(u16, 1077), parsed.msg_type);
    try std.testing.expectEqual(len, parsed.consumed);

    // 補正後 obs を再抽出 → PRN1/L1 のみ +0.01m
    const new_obs = try fkp_msm7.extractPhase(alloc, frame[3 .. 3 + 96]);
    try std.testing.expectEqual(orig_obs.len, new_obs.len);
    for (orig_obs, new_obs) |o, n| {
        try std.testing.expectEqual(o.prn, n.prn);
        try std.testing.expectEqual(o.band, n.band);
        if (o.prn == 1 and o.band == .l1) {
            // fine_phase 量子化 ~0.558 mm。1mm 許容で十分余裕。
            try std.testing.expectApproxEqAbs(o.phase_m + 0.01, n.phase_m, 1e-3);
        } else {
            // 他の cell は完全に不変
            try std.testing.expectApproxEqAbs(o.phase_m, n.phase_m, 1e-9);
        }
    }
}

test "fkp: applyPhaseCorrection rejects non-MSM7 frames" {
    // msg_type = 1005 (= 0x3ED, payload 先頭 12 bit = 0011 1110 1101)
    // payload_len = 19 (applyPhaseCorrection の minimum check 通過用)
    var frame = [_]u8{0} ** 25;
    frame[0] = 0xD3;
    frame[1] = 0;
    frame[2] = 19;
    frame[3] = 0x3E;
    frame[4] = 0xD0;
    // CRC は入力検証されないので未設定でも OK

    try std.testing.expectError(
        error.NotMsm7,
        fkp_msm7.applyPhaseCorrection(&frame, &.{}),
    );
}

// ── Phase 5b-2: FkpSnapshotStore ───────────────────────────────────────────

test "fkp: FkpSnapshotStore returns null before first update" {
    var store = fkp_runtime.FkpSnapshotStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expect(store.snapshot(std.testing.allocator) == null);
}

test "fkp: FkpSnapshotStore update + snapshot roundtrip" {
    var store = fkp_runtime.FkpSnapshotStore.init(std.testing.allocator);
    defer store.deinit();

    const params = [_]fkp_engine.FkpParam{
        .{ .prn = 5, .n_i = 0.01, .e_i = -0.02, .n_0 = 1.5, .e_0 = -0.8 },
        .{ .prn = 10, .n_i = 0.005, .e_i = 0.003, .n_0 = 0.7, .e_0 = 0.4 },
    };
    const ref = fkp_msm7.StationCoord{
        .ref_station_id = 1,
        .x = -3959730.0,
        .y = 3352966.0,
        .z = 3697212.0,
        .lat = 0.622,
        .lon = 2.438,
    };
    store.update(&params, ref);

    const snap = store.snapshot(std.testing.allocator) orelse return error.NoSnapshot;
    defer snap.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), snap.params.len);
    try std.testing.expectEqual(@as(u8, 5), snap.params[0].prn);
    try std.testing.expectEqual(@as(u8, 10), snap.params[1].prn);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), snap.params[0].n_i, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.8), snap.params[0].e_0, 1e-12);
    try std.testing.expectEqual(@as(u16, 1), snap.ref_coord.ref_station_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.622), snap.ref_coord.lat, 1e-12);

    // 2 回 snapshot を取っても独立した copy が返ること (testing.allocator が leak を検出)
    const snap2 = store.snapshot(std.testing.allocator) orelse return error.NoSnapshot;
    defer snap2.deinit(std.testing.allocator);
    try std.testing.expect(snap.params.ptr != snap2.params.ptr);
}

test "fkp: FkpSnapshotStore accepts empty params (Phase 6a all-dropped case)" {
    // Phase 6a で全 PRN が閾値棄却されたとき、runtime は empty params を
    // update に渡す。snapshot は valid な ref_coord と empty params を返し、
    // VRS 側で applyPhaseCorrection no-op success として扱える。
    var store = fkp_runtime.FkpSnapshotStore.init(std.testing.allocator);
    defer store.deinit();

    const params = [_]fkp_engine.FkpParam{};
    const ref = fkp_msm7.StationCoord{
        .ref_station_id = 1,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 0.5,
        .lon = 1.0,
    };
    store.update(&params, ref);

    const snap = store.snapshot(std.testing.allocator) orelse return error.NoSnapshot;
    defer snap.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), snap.params.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), snap.ref_coord.lat, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), snap.ref_coord.lon, 1e-12);
}

test "fkp: FkpSnapshotStore second update replaces first without leak" {
    var store = fkp_runtime.FkpSnapshotStore.init(std.testing.allocator);
    defer store.deinit();

    const params_a = [_]fkp_engine.FkpParam{
        .{ .prn = 5, .n_i = 0.01, .e_i = 0.02, .n_0 = 0.3, .e_0 = 0.4 },
    };
    const params_b = [_]fkp_engine.FkpParam{
        .{ .prn = 7, .n_i = 0.1, .e_i = 0.2, .n_0 = 0.5, .e_0 = 0.6 },
        .{ .prn = 8, .n_i = 0.3, .e_i = 0.4, .n_0 = 0.7, .e_0 = 0.8 },
    };
    const ref = fkp_msm7.StationCoord{
        .ref_station_id = 2,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 0,
        .lon = 0,
    };

    store.update(&params_a, ref);
    store.update(&params_b, ref);

    const snap = store.snapshot(std.testing.allocator) orelse return error.NoSnapshot;
    defer snap.deinit(std.testing.allocator);

    // 2 回目 update の値が返る (PRN 7,8)
    try std.testing.expectEqual(@as(usize, 2), snap.params.len);
    try std.testing.expectEqual(@as(u8, 7), snap.params[0].prn);
    try std.testing.expectEqual(@as(u8, 8), snap.params[1].prn);
    // testing.allocator が defer 時点で 1 回目の params_a copy の leak を検出する
}

// ── Phase 5b-3: computePhaseDelta + 統合フロー ──────────────────────────────

test "fkp: computePhaseDelta single PRN produces expected delta" {
    // ref_coord at (0,0)、rover at (0.001, 0.0005) rad → dN=0.001, dE=0.0005
    // n_i=0.5, e_i=0.3, n_0=1.0, e_0=0.7 m/rad
    // delta_m = (n_i+n_0)·dN + (e_i+e_0)·dE
    //         = 1.5 × 0.001 + 1.0 × 0.0005
    //         = 0.0015 + 0.0005 = 0.002 m
    var store = fkp_runtime.FkpSnapshotStore.init(std.testing.allocator);
    defer store.deinit();

    const params = [_]fkp_engine.FkpParam{
        .{ .prn = 5, .n_i = 0.5, .e_i = 0.3, .n_0 = 1.0, .e_0 = 0.7 },
    };
    const ref = fkp_msm7.StationCoord{
        .ref_station_id = 1,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 0,
        .lon = 0,
    };
    store.update(&params, ref);

    const snap = store.snapshot(std.testing.allocator) orelse return error.NoSnapshot;
    defer snap.deinit(std.testing.allocator);

    var deltas = std.ArrayList(fkp_msm7.PhaseDelta){};
    defer deltas.deinit(std.testing.allocator);
    try fkp_vrs.computePhaseDelta(&deltas, std.testing.allocator, snap, 0.001, 0.0005);

    try std.testing.expectEqual(@as(usize, 1), deltas.items.len);
    try std.testing.expectEqual(@as(u8, 5), deltas.items[0].prn);
    try std.testing.expectEqual(fkp_msm7.Band.l1, deltas.items[0].band);
    try std.testing.expectApproxEqAbs(@as(f64, 0.002), deltas.items[0].delta_m, 1e-12);
}

test "fkp: computePhaseDelta multiple PRNs returns one entry per param" {
    var store = fkp_runtime.FkpSnapshotStore.init(std.testing.allocator);
    defer store.deinit();

    const params = [_]fkp_engine.FkpParam{
        .{ .prn = 5, .n_i = 0.5, .e_i = 0.3, .n_0 = 1.0, .e_0 = 0.7 },
        .{ .prn = 10, .n_i = 0.1, .e_i = 0.2, .n_0 = 0.4, .e_0 = 0.6 },
    };
    const ref = fkp_msm7.StationCoord{
        .ref_station_id = 1,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 0,
        .lon = 0,
    };
    store.update(&params, ref);

    const snap = store.snapshot(std.testing.allocator) orelse return error.NoSnapshot;
    defer snap.deinit(std.testing.allocator);

    var deltas = std.ArrayList(fkp_msm7.PhaseDelta){};
    defer deltas.deinit(std.testing.allocator);
    try fkp_vrs.computePhaseDelta(&deltas, std.testing.allocator, snap, 0.001, 0.0005);

    try std.testing.expectEqual(@as(usize, 2), deltas.items.len);
    try std.testing.expectEqual(@as(u8, 5), deltas.items[0].prn);
    try std.testing.expectEqual(@as(u8, 10), deltas.items[1].prn);
    // PRN 5: (0.5+1.0)·0.001 + (0.3+0.7)·0.0005 = 0.002
    try std.testing.expectApproxEqAbs(@as(f64, 0.002), deltas.items[0].delta_m, 1e-12);
    // PRN 10: (0.1+0.4)·0.001 + (0.2+0.6)·0.0005 = 0.0005 + 0.0004 = 0.0009
    try std.testing.expectApproxEqAbs(@as(f64, 0.0009), deltas.items[1].delta_m, 1e-12);
}

test "fkp: computePhaseDelta + applyPhaseCorrection end-to-end on MSM7 frame" {
    // 合成 MSM7 frame に対し、computePhaseDelta で生成した deltas を
    // applyPhaseCorrection で書き込み、extractPhase で確認するエンドツーエンド。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = fkp_runtime.FkpSnapshotStore.init(std.testing.allocator);
    defer store.deinit();

    // PRN 1 のみ補正対象 (PRN 2, 3 は params に含めない → 補正なし)
    const params = [_]fkp_engine.FkpParam{
        .{ .prn = 1, .n_i = 5.0, .e_i = 2.0, .n_0 = 3.0, .e_0 = 1.0 },
    };
    const ref = fkp_msm7.StationCoord{
        .ref_station_id = 1,
        .x = 0,
        .y = 0,
        .z = 0,
        .lat = 0,
        .lon = 0,
    };
    store.update(&params, ref);

    const snap = store.snapshot(alloc) orelse return error.NoSnapshot;
    defer snap.deinit(alloc);

    // rover at (0.001, 0.0005) rad
    // delta_m = (5+3)·0.001 + (2+1)·0.0005 = 0.008 + 0.0015 = 0.0095 m
    var deltas = std.ArrayList(fkp_msm7.PhaseDelta){};
    defer deltas.deinit(alloc);
    try fkp_vrs.computePhaseDelta(&deltas, alloc, snap, 0.001, 0.0005);

    // MSM7 frame 構築
    var frame: [102]u8 = undefined;
    const fps = [_]i64{ 100000, 110000, 200000, 210000, 300000, 310000 };
    const len = buildMsm7TestFrame(&frame, fps);

    const orig_obs = try fkp_msm7.extractPhase(alloc, frame[3 .. 3 + 96]);
    try fkp_msm7.applyPhaseCorrection(frame[0..len], deltas.items);

    // CRC parseFrame で通る
    const parsed = test_rtcm3.parseFrame(frame[0..len]) orelse return error.CrcFailed;
    try std.testing.expectEqual(@as(u16, 1077), parsed.msg_type);

    // PRN 1/L1 のみ +0.0095 m / 他 5 cell は不変
    const new_obs = try fkp_msm7.extractPhase(alloc, frame[3 .. 3 + 96]);
    try std.testing.expectEqual(orig_obs.len, new_obs.len);
    for (orig_obs, new_obs) |o, n| {
        try std.testing.expectEqual(o.prn, n.prn);
        try std.testing.expectEqual(o.band, n.band);
        if (o.prn == 1 and o.band == .l1) {
            try std.testing.expectApproxEqAbs(o.phase_m + 0.0095, n.phase_m, 1e-3);
        } else {
            try std.testing.expectApproxEqAbs(o.phase_m, n.phase_m, 1e-9);
        }
    }
}

test "fkp: applyPhaseCorrection rejects truncated frames" {
    var frame = [_]u8{0} ** 5; // preamble + len のみ
    frame[0] = 0xD3;
    frame[1] = 0;
    frame[2] = 19;

    try std.testing.expectError(
        error.InvalidFrame,
        fkp_msm7.applyPhaseCorrection(&frame, &.{}),
    );
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

// ── Phase 7-1: GPS broadcast ephemeris (Type 1019) ────────────────────────

/// Type 1019 ペイロード (61 byte = 488 bit) を組み立てるヘルパー。
/// 全 raw scaled int を呼び出し側が与え、bit 配置は spec (RTCM 10403.3
/// § 3.5.13) 通りに書く。
fn buildMsg1019Payload(
    buf: *[61]u8,
    fields: struct {
        prn: u8,
        week_mod1024: u16,
        sv_acc: u4,
        code_on_l2: u2,
        idot_raw: i64,
        iode: u8,
        toc_raw: u64,
        af2_raw: i64,
        af1_raw: i64,
        af0_raw: i64,
        iodc: u16,
        crs_raw: i64,
        dn_raw: i64,
        m0_raw: i64,
        cuc_raw: i64,
        ecc_raw: u64,
        cus_raw: i64,
        sqrt_a_raw: u64,
        toe_raw: u64,
        cic_raw: i64,
        omega0_raw: i64,
        cis_raw: i64,
        inc_raw: i64,
        crc_raw: i64,
        argp_raw: i64,
        omdot_raw: i64,
        tgd_raw: i64,
        sv_health: u6,
        l2p_flag: u1,
        fit_interval_flag: u1,
    },
) void {
    @memset(buf, 0);
    var bw = fkp_bits.BitWriter.init(buf);
    bw.writeU(12, 1019);
    bw.writeU(6, fields.prn);
    bw.writeU(10, fields.week_mod1024);
    bw.writeU(4, fields.sv_acc);
    bw.writeU(2, fields.code_on_l2);
    bw.writeS(14, fields.idot_raw);
    bw.writeU(8, fields.iode);
    bw.writeU(16, fields.toc_raw);
    bw.writeS(8, fields.af2_raw);
    bw.writeS(16, fields.af1_raw);
    bw.writeS(22, fields.af0_raw);
    bw.writeU(10, fields.iodc);
    bw.writeS(16, fields.crs_raw);
    bw.writeS(16, fields.dn_raw);
    bw.writeS(32, fields.m0_raw);
    bw.writeS(16, fields.cuc_raw);
    bw.writeU(32, fields.ecc_raw);
    bw.writeS(16, fields.cus_raw);
    bw.writeU(32, fields.sqrt_a_raw);
    bw.writeU(16, fields.toe_raw);
    bw.writeS(16, fields.cic_raw);
    bw.writeS(32, fields.omega0_raw);
    bw.writeS(16, fields.cis_raw);
    bw.writeS(32, fields.inc_raw);
    bw.writeS(16, fields.crc_raw);
    bw.writeS(32, fields.argp_raw);
    bw.writeS(24, fields.omdot_raw);
    bw.writeS(8, fields.tgd_raw);
    bw.writeU(6, fields.sv_health);
    bw.writeU(1, fields.l2p_flag);
    bw.writeU(1, fields.fit_interval_flag);
}

test "fkp: parseMsg1019 decodes all fields with correct SI scaling" {
    // 全 field に distinct な raw 値を入れて、scale を素直に掛けたものが
    // パース結果と一致することを確認 (符号 + scale)。
    var buf: [61]u8 = undefined;
    buildMsg1019Payload(&buf, .{
        .prn = 13,
        .week_mod1024 = 1023,
        .sv_acc = 0,
        .code_on_l2 = 1,
        .idot_raw = -3000,
        .iode = 99,
        .toc_raw = 12345,
        .af2_raw = 5,
        .af1_raw = -7,
        .af0_raw = 1000000,
        .iodc = 250,
        .crs_raw = 320, // 320 × 2^-5 = 10.0 m
        .dn_raw = 4000,
        .m0_raw = 100000000,
        .cuc_raw = -500,
        .ecc_raw = 1717986918, // ≒ 0.2
        .cus_raw = 500,
        .sqrt_a_raw = 2702924288, // ≒ 5153.6 √m (近似)
        .toe_raw = 7200,
        .cic_raw = -200,
        .omega0_raw = -200000000,
        .cis_raw = 200,
        .inc_raw = 500000000,
        .crc_raw = -640, // -640 × 2^-5 = -20.0 m
        .argp_raw = 300000000,
        .omdot_raw = -8000,
        .tgd_raw = -10,
        .sv_health = 0,
        .l2p_flag = 1,
        .fit_interval_flag = 0,
    });

    const eph = fkp_eph.parseMsg1019(&buf) orelse {
        try std.testing.expect(false);
        return;
    };

    const pi = std.math.pi;
    const pow2_m29 = 1.0 / 536870912.0;
    const pow2_m31 = 1.0 / 2147483648.0;
    const pow2_m33 = 1.0 / 8589934592.0;
    const pow2_m43 = 1.0 / 8796093022208.0;
    const pow2_m55 = 1.0 / 36028797018963968.0;
    const pow2_m19 = 1.0 / 524288.0;

    try std.testing.expectEqual(@as(u8, 13), eph.prn);
    try std.testing.expectEqual(@as(u16, 1023), eph.week_mod1024);
    try std.testing.expectEqual(@as(u4, 0), eph.sv_acc);
    try std.testing.expectEqual(@as(u2, 1), eph.code_on_l2);
    try std.testing.expectEqual(@as(u8, 99), eph.iode);
    try std.testing.expectEqual(@as(u10, 250), eph.iodc);
    try std.testing.expectEqual(@as(u6, 0), eph.sv_health);
    try std.testing.expectEqual(@as(u1, 1), eph.l2p_flag);
    try std.testing.expectEqual(@as(u1, 0), eph.fit_interval_flag);

    try std.testing.expectApproxEqAbs(@as(f64, 12345.0 * 16.0), eph.toc_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7200.0 * 16.0), eph.toe_s, 1e-9);

    try std.testing.expectApproxEqAbs(1000000.0 * pow2_m31, eph.af0_s, 1e-15);
    try std.testing.expectApproxEqAbs(-7.0 * pow2_m43, eph.af1_s_per_s, 1e-20);
    try std.testing.expectApproxEqAbs(5.0 * pow2_m55, eph.af2_s_per_s2, 1e-25);

    try std.testing.expectApproxEqAbs(@as(f64, 10.0), eph.crs_m, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -20.0), eph.crc_m, 1e-9);

    try std.testing.expectApproxEqAbs(-500.0 * pow2_m29, eph.cuc_rad, 1e-15);
    try std.testing.expectApproxEqAbs(500.0 * pow2_m29, eph.cus_rad, 1e-15);
    try std.testing.expectApproxEqAbs(-200.0 * pow2_m29, eph.cic_rad, 1e-15);
    try std.testing.expectApproxEqAbs(200.0 * pow2_m29, eph.cis_rad, 1e-15);

    try std.testing.expectApproxEqAbs(4000.0 * pow2_m43 * pi, eph.dn_rad_per_s, 1e-22);
    try std.testing.expectApproxEqAbs(100000000.0 * pow2_m31 * pi, eph.m0_rad, 1e-10);
    try std.testing.expectApproxEqAbs(-200000000.0 * pow2_m31 * pi, eph.omega0_rad, 1e-10);
    try std.testing.expectApproxEqAbs(500000000.0 * pow2_m31 * pi, eph.i0_rad, 1e-10);
    try std.testing.expectApproxEqAbs(300000000.0 * pow2_m31 * pi, eph.argp_rad, 1e-10);
    try std.testing.expectApproxEqAbs(-3000.0 * pow2_m43 * pi, eph.idot_rad_per_s, 1e-22);
    try std.testing.expectApproxEqAbs(-8000.0 * pow2_m43 * pi, eph.omdot_rad_per_s, 1e-22);

    try std.testing.expectApproxEqAbs(1717986918.0 * pow2_m33, eph.ecc, 1e-15);
    try std.testing.expectApproxEqAbs(2702924288.0 * pow2_m19, eph.sqrt_a_m, 1e-10);

    try std.testing.expectApproxEqAbs(-10.0 * pow2_m31, eph.tgd_s, 1e-15);
}

test "fkp: parseMsg1019 rejects payload that is too short" {
    const short = [_]u8{0} ** 30;
    try std.testing.expectEqual(@as(?fkp_eph.GpsEphemeris, null), fkp_eph.parseMsg1019(&short));
}

test "fkp: parseMsg1019 rejects non-1019 message types" {
    var buf: [61]u8 = undefined;
    @memset(&buf, 0);
    var bw = fkp_bits.BitWriter.init(&buf);
    bw.writeU(12, 1077); // MSM7、1019 ではない
    try std.testing.expectEqual(@as(?fkp_eph.GpsEphemeris, null), fkp_eph.parseMsg1019(&buf));
}

test "fkp: EphemerisStore upsert + lookup roundtrip" {
    var store = fkp_eph.EphemerisStore.init(std.testing.allocator);
    defer store.deinit();

    const eph1 = fkp_eph.GpsEphemeris{
        .prn = 5,
        .week_mod1024 = 100,
        .sv_acc = 0,
        .code_on_l2 = 0,
        .iode = 10,
        .iodc = 10,
        .sv_health = 0,
        .l2p_flag = 0,
        .fit_interval_flag = 0,
        .toc_s = 0,
        .toe_s = 0,
        .af0_s = 0,
        .af1_s_per_s = 0,
        .af2_s_per_s2 = 0,
        .crs_m = 0,
        .crc_m = 0,
        .cuc_rad = 0,
        .cus_rad = 0,
        .cic_rad = 0,
        .cis_rad = 0,
        .dn_rad_per_s = 0,
        .m0_rad = 0,
        .ecc = 0,
        .sqrt_a_m = 5153.6,
        .omega0_rad = 0,
        .omdot_rad_per_s = 0,
        .i0_rad = 0,
        .idot_rad_per_s = 0,
        .argp_rad = 0,
        .tgd_s = 0,
    };

    try store.upsertGps(eph1, 1000);
    try std.testing.expectEqual(@as(usize, 1), store.countGps());

    const got1 = store.lookupGps(5) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u8, 10), got1.eph.iode);
    try std.testing.expectEqual(@as(i64, 1000), got1.received_at_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 5153.6), got1.eph.sqrt_a_m, 1e-9);

    // 同一 PRN、IODE 更新で上書き
    var eph2 = eph1;
    eph2.iode = 20;
    try store.upsertGps(eph2, 2000);
    try std.testing.expectEqual(@as(usize, 1), store.countGps());
    try std.testing.expectEqual(@as(u8, 20), store.lookupGps(5).?.eph.iode);
    try std.testing.expectEqual(@as(i64, 2000), store.lookupGps(5).?.received_at_ms);

    // 別 PRN は別エントリ
    var eph3 = eph1;
    eph3.prn = 7;
    try store.upsertGps(eph3, 3000);
    try std.testing.expectEqual(@as(usize, 2), store.countGps());
    try std.testing.expectEqual(@as(?fkp_eph.EphemerisStore.Entry, null), store.lookupGps(99));
}

test "fkp: parseMsg1019 + EphemerisStore integration" {
    // bit pattern を組んで parse → store に upsert → lookup で fields 再確認
    var buf: [61]u8 = undefined;
    buildMsg1019Payload(&buf, .{
        .prn = 7,
        .week_mod1024 = 500,
        .sv_acc = 1,
        .code_on_l2 = 1,
        .idot_raw = 100,
        .iode = 42,
        .toc_raw = 6300,
        .af2_raw = 0,
        .af1_raw = 1,
        .af0_raw = -50,
        .iodc = 42,
        .crs_raw = 64,
        .dn_raw = 100,
        .m0_raw = 100000,
        .cuc_raw = 0,
        .ecc_raw = 0,
        .cus_raw = 0,
        .sqrt_a_raw = 2702924288,
        .toe_raw = 6300,
        .cic_raw = 0,
        .omega0_raw = 0,
        .cis_raw = 0,
        .inc_raw = 0,
        .crc_raw = 0,
        .argp_raw = 0,
        .omdot_raw = 0,
        .tgd_raw = 0,
        .sv_health = 0,
        .l2p_flag = 0,
        .fit_interval_flag = 0,
    });

    const eph = fkp_eph.parseMsg1019(&buf) orelse {
        try std.testing.expect(false);
        return;
    };

    var store = fkp_eph.EphemerisStore.init(std.testing.allocator);
    defer store.deinit();
    try store.upsertGps(eph, 12345);

    const got = store.lookupGps(7) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u8, 7), got.eph.prn);
    try std.testing.expectEqual(@as(u8, 42), got.eph.iode);
    try std.testing.expectEqual(@as(u10, 42), got.eph.iodc);
    try std.testing.expectEqual(@as(u16, 500), got.eph.week_mod1024);
    // toc/toe = 6300 × 16 = 100800 s
    try std.testing.expectApproxEqAbs(@as(f64, 100800.0), got.eph.toc_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100800.0), got.eph.toe_s, 1e-9);
}
