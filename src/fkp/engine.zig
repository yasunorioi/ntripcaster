//! fkp/engine.zig — FKP (Flächenkorrekturparameter) 計算エンジン
//!
//! 入力: 3 局以上の搬送波位相観測値と基準局座標
//! 出力: 各衛星の FKP パラメータ (N_I, E_I, N_0, E_0)
//!
//! 参考文献: 田中慎治(2003)「ネットワークRTK-GPS測位に関する研究」
//!   §4.3.3 FKP表現法 (p.51-54)
//!   §4.3.4 FKPパラメータの計算 (p.54-57)

const std = @import("std");
const msm7 = @import("msm7.zig");

/// GPS L1/L2 周波数
const F1: f64 = msm7.GPS_L1_FREQ;
const F2: f64 = msm7.GPS_L2_FREQ;

/// Ionosphere-free 線形結合係数（田中 2003, 式 4.9）
pub const ALPHA: f64 = F1 * F1 / (F1 * F1 - F2 * F2); // ≈ 2.5457
pub const BETA: f64 = F2 * F2 / (F1 * F1 - F2 * F2); // ≈ 1.5457

/// FKP 係数の物理妥当性閾値 [m/rad]。
/// 50 km baseline で 1 m 補正 = 1 / (50 km / 6378 km) = 127 m/rad、
/// その境界より少し下に置く。50 km 内で 50 cm を超える補正は物理的に
/// 疑わしい (electromagnetic + 大気 atmospheric 影響だけでは出ない)。
///
/// 真因は `computeFkp` が LIF を「衛星-局の geometric range を引いた
/// double-difference 残差」ではなく生の搬送波位相観測値で計算しており、
/// 衛星-局距離の km スケール勾配がそのまま FKP 係数に乗ってしまう構造的
/// 問題 (docs/phase6-design.md § 1 参照)。本閾値は safety net で、根本
/// 対応には ephemeris ベースの geometric range 計算が要る (Phase 7)。
pub const DEFAULT_FKP_MAX_MAGNITUDE: f64 = 100.0;

/// `computeFkp` の追加オプション。各フィールドはデフォルト値があるため
/// `.{}` で呼び出すと標準動作。
pub const ComputeOptions = struct {
    /// 各 FkpParam の n_0/e_0/n_i/e_i 絶対値の上限 [m/rad]。
    /// これを超える PRN は出力に含めない (棄却)。
    /// `std.math.inf(f64)` を渡すと閾値無効 (Phase 5b 以前の挙動)。
    max_magnitude: f64 = DEFAULT_FKP_MAX_MAGNITUDE,

    /// 統計出力先。null でなければ実行統計をここに書き込む。
    stats: ?*ComputeStats = null,
};

/// `computeFkp` の実行統計。
pub const ComputeStats = struct {
    /// 閾値超過で棄却された PRN 数 (Phase 6a)。
    dropped_excess: u32 = 0,
};

/// 1 衛星の FKP パラメータ
pub const FkpParam = struct {
    prn: u8,
    /// 電離層補正係数 [m/rad]
    n_i: f64, // 北方向
    e_i: f64, // 東方向
    /// 幾何学的補正係数 [m/rad]
    n_0: f64, // 北方向
    e_0: f64, // 東方向
};

/// 1 衛星の L1/L2 位相観測値 [m]。
pub const SatObs = struct {
    prn: u8,
    l1_m: ?f64,
    l2_m: ?f64,
};

/// 1 局の観測データ（座標 + 全衛星観測値）
pub const StationObs = struct {
    coord: msm7.StationCoord,
    obs: []const SatObs,
};

/// PhaseObs スライスから SatObs スライスに変換する。
/// 同一 PRN の L1/L2 をペアにまとめる。
pub fn groupPhaseObs(
    allocator: std.mem.Allocator,
    phase_list: []const msm7.PhaseObs,
) ![]SatObs {
    // PRN 別に集計
    var map = std.AutoHashMap(u8, SatObs).init(allocator);
    defer map.deinit();

    for (phase_list) |p| {
        const gop = try map.getOrPut(p.prn);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .prn = p.prn, .l1_m = null, .l2_m = null };
        }
        switch (p.band) {
            .l1 => gop.value_ptr.*.l1_m = p.phase_m,
            .l2 => gop.value_ptr.*.l2_m = p.phase_m,
            else => {},
        }
    }

    var list = std.ArrayList(SatObs){};
    var it = map.valueIterator();
    while (it.next()) |v| {
        try list.append(allocator, v.*);
    }
    return try list.toOwnedSlice(allocator);
}

/// 2×2 行列の逆行列を返す。行列式がゼロに近い場合は null。
///
/// A = [[a, b], [c, d]]
/// A^-1 = 1/(ad-bc) * [[d, -b], [-c, a]]
pub fn invert2x2(
    a: f64,
    b: f64,
    c: f64,
    d: f64,
) ?[2][2]f64 {
    const det = a * d - b * c;
    if (@abs(det) < 1e-20) return null;
    const inv = 1.0 / det;
    return .{
        .{ d * inv, -b * inv },
        .{ -c * inv, a * inv },
    };
}

/// 3 局データから FKP パラメータを計算する。
///
/// stations[0]: 中心局（参照局 A）
/// stations[1]: 補助局 B
/// stations[2]: 補助局 C
///
/// 計算式（田中 2003 §4.3.4）:
///   geometry-free:    LGF = L1 - L2  [m]  (電離層誤差に比例)
///   ionosphere-free:  LIF = α·L1 - β·L2  [m]  (電離層誤差除去)
///   一重位相差:        ΔΦ_B = Φ_B - Φ_A
///   FKP = A^-1 · ΔΦ
///     where A = [[Δφ_B, Δλ_B], [Δφ_C, Δλ_C]]
pub fn computeFkp(
    allocator: std.mem.Allocator,
    stations: []const StationObs,
    options: ComputeOptions,
) ![]FkpParam {
    if (options.stats) |s| s.* = .{};
    if (stations.len < 3) return &.{};

    const sta_a = stations[0]; // 中心局
    const sta_b = stations[1];
    const sta_c = stations[2];

    // 座標差 [rad]（中心局を原点とする）
    const dphi_b = sta_b.coord.lat - sta_a.coord.lat;
    const dlam_b = sta_b.coord.lon - sta_a.coord.lon;
    const dphi_c = sta_c.coord.lat - sta_a.coord.lat;
    const dlam_c = sta_c.coord.lon - sta_a.coord.lon;

    // A = [[dphi_b, dlam_b], [dphi_c, dlam_c]]
    const inv_a = invert2x2(dphi_b, dlam_b, dphi_c, dlam_c) orelse return &.{};

    var fkp_list = std.ArrayList(FkpParam){};

    for (sta_a.obs) |obs_a| {
        const prn = obs_a.prn;
        const obs_b = findSatObs(sta_b.obs, prn) orelse continue;
        const obs_c = findSatObs(sta_c.obs, prn) orelse continue;

        const l1a = obs_a.l1_m orelse continue;
        const l1b = obs_b.l1_m orelse continue;
        const l1c = obs_c.l1_m orelse continue;
        const l2a = obs_a.l2_m orelse continue;
        const l2b = obs_b.l2_m orelse continue;
        const l2c = obs_c.l2_m orelse continue;

        // 一重位相差 [m]
        const dl1_b = l1b - l1a;
        const dl1_c = l1c - l1a;
        const dl2_b = l2b - l2a;
        const dl2_c = l2c - l2a;

        // geometry-free (電離層誤差): L1 - L2
        const lgf_b = dl1_b - dl2_b;
        const lgf_c = dl1_c - dl2_c;

        // ionosphere-free (電離層除去): α·L1 - β·L2
        const lif_b = ALPHA * dl1_b - BETA * dl2_b;
        const lif_c = ALPHA * dl1_c - BETA * dl2_c;

        // FKP = A^-1 · ΔΦ
        const n_i = inv_a[0][0] * lgf_b + inv_a[0][1] * lgf_c;
        const e_i = inv_a[1][0] * lgf_b + inv_a[1][1] * lgf_c;
        const n_0 = inv_a[0][0] * lif_b + inv_a[0][1] * lif_c;
        const e_0 = inv_a[1][0] * lif_b + inv_a[1][1] * lif_c;

        // Phase 6a: 物理妥当性チェック。computeFkp の入力 (= 生の搬送波位相
        // 観測値) には衛星-局距離の km スケール勾配が含まれるため、3 局
        // triangle が縮退気味だと FkpParam が物理的にあり得ない大きさになる
        // 構造的問題がある (docs/phase6-design.md § 1)。根本対応は Phase 7
        // (ephemeris + DD + LAMBDA) で行うが、当面の safety net として閾値
        // 超過の PRN は出力に含めない。
        const max_abs = @max(@max(@abs(n_i), @abs(e_i)), @max(@abs(n_0), @abs(e_0)));
        if (max_abs > options.max_magnitude) {
            if (options.stats) |s| s.dropped_excess += 1;
            continue;
        }

        try fkp_list.append(allocator, .{
            .prn = prn,
            .n_i = n_i,
            .e_i = e_i,
            .n_0 = n_0,
            .e_0 = e_0,
        });
    }

    return try fkp_list.toOwnedSlice(allocator);
}

fn findSatObs(list: []const SatObs, prn: u8) ?SatObs {
    for (list) |obs| {
        if (obs.prn == prn) return obs;
    }
    return null;
}
