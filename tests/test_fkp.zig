//! tests/test_fkp.zig — FKP エンジン + MSM7 + Type59 のユニットテスト

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const fkp_bits = ntripcaster.fkp_bits;
const fkp_msm7 = ntripcaster.fkp_msm7;
const fkp_engine = ntripcaster.fkp_engine;
const fkp_type59 = ntripcaster.fkp_type59;

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
        .x = 0, .y = 0, .z = 0, // ECEFは未使用
        .lat = 44.80 * deg,
        .lon = 142.06 * deg,
    };
    const coord_b = fkp_msm7.StationCoord{
        .ref_station_id = 2,
        .x = 0, .y = 0, .z = 0,
        .lat = 43.80 * deg,
        .lon = 142.43 * deg,
    };
    const coord_c = fkp_msm7.StationCoord{
        .ref_station_id = 3,
        .x = 0, .y = 0, .z = 0,
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
    const parse_result = ntripcaster.rtcm3.parseFrame(frame);
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
        .ref_station_id = 1, .x = 0, .y = 0, .z = 0,
        .lat = 44.80 * deg, .lon = 142.06 * deg,
    };
    const coord_b = fkp_msm7.StationCoord{
        .ref_station_id = 2, .x = 0, .y = 0, .z = 0,
        .lat = 43.80 * deg, .lon = 142.43 * deg,
    };
    const coord_c = fkp_msm7.StationCoord{
        .ref_station_id = 3, .x = 0, .y = 0, .z = 0,
        .lat = 43.58 * deg, .lon = 142.00 * deg,
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
