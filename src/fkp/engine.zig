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
const ephemeris = @import("ephemeris.zig");
const orbit = @import("orbit.zig");

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

    var list = std.ArrayList(SatObs).empty;
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

    var fkp_list = std.ArrayList(FkpParam).empty;

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

// ─────────────────────────────────────────────────────────────────────────
// Phase 7-3: ephemeris ベース DD residual + ref PRN 選定
// ─────────────────────────────────────────────────────────────────────────
//
// 既存 `computeFkp` (生 phase 観測値を入力に取り、SD で plane fit) は構造的に
// geometric range が消えない (docs/phase6-design.md § 1)。Phase 7-3 では:
//
//   1. 各 (PRN, station) で ρ_j_a と sat clock bias を ephemeris から計算
//   2. SD residual_j_a = L_j_a − ρ_j_a − c·dt_sat_j
//      → station clock δt_a + iono I + tropo T + N·λ + ε のみ残る
//   3. SD pair-difference: SD_j_b = res_j_b − res_j_a (station 対の clock 差消去)
//   4. DD: DD_j_b = SD_j_b − SD_k_b (k = ref PRN; sat clock の二次効果が
//      完全消去される)
//   5. DD を LIF/LGF combine して平面 fit → FkpParam
//
// Phase 7-3 単独では N·λ DD bias がそのまま残る (= magnitude reduction は
// 部分的)。本格的な cm 級 FKP は Phase 7-4 (LAMBDA で N·λ DD を整数 fix) で
// 達成する。Phase 7-3 はパイプライン (API + データフロー) の完成が目的。

/// 1 衛星の Phase 7 拡張観測値。
/// `cnr_db_hz` + `lock_time_indicator` は MSM7 から抽出した品質情報 (Phase 7-3
/// は ref PRN 選定で cnr を、Phase 7-4 は cycle slip で lock_time を使う)。
pub const SatObsEx = struct {
    prn: u8,
    l1_m: ?f64,
    l2_m: ?f64,
    /// L1 cnr (両周波数のうち高い方が typical で良い)。null なら fallback で
    /// 0 dB-Hz 扱い → ref PRN 選定で不利になる。
    l1_cnr_db_hz: ?f64 = null,
    l2_cnr_db_hz: ?f64 = null,
    /// MSM7 DF407 lock time indicator (raw 10 bit)。Phase 7-4 で前 epoch
    /// との比較で cycle slip 検出。
    l1_lock_time: ?u16 = null,
    l2_lock_time: ?u16 = null,
};

/// 1 局の Phase 7 拡張観測値。
pub const StationObsEx = struct {
    coord: msm7.StationCoord,
    /// ECEF 座標 [m] (StationCoord.x/y/z を 3-tuple 化)
    ecef: [3]f64,
    /// 観測時刻 (GPS second of week)
    t_recv_sow: f64,
    obs: []const SatObsEx,
};

/// `PhaseObs` 列を `SatObsEx` 列に変換する (groupPhaseObs の Phase 7 版)。
/// 同一 PRN の L1/L2 をペアにし、cnr/lock_time を band 別に保持。
pub fn groupPhaseObsEx(
    allocator: std.mem.Allocator,
    phase_list: []const msm7.PhaseObs,
) ![]SatObsEx {
    var map = std.AutoHashMap(u8, SatObsEx).init(allocator);
    defer map.deinit();

    for (phase_list) |p| {
        const gop = try map.getOrPut(p.prn);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .prn = p.prn, .l1_m = null, .l2_m = null };
        }
        switch (p.band) {
            .l1 => {
                gop.value_ptr.*.l1_m = p.phase_m;
                gop.value_ptr.*.l1_cnr_db_hz = p.cnr_db_hz;
                gop.value_ptr.*.l1_lock_time = p.lock_time_indicator;
            },
            .l2 => {
                gop.value_ptr.*.l2_m = p.phase_m;
                gop.value_ptr.*.l2_cnr_db_hz = p.cnr_db_hz;
                gop.value_ptr.*.l2_lock_time = p.lock_time_indicator;
            },
            else => {},
        }
    }

    var list = std.ArrayList(SatObsEx).empty;
    var it = map.valueIterator();
    while (it.next()) |v| {
        try list.append(allocator, v.*);
    }
    return try list.toOwnedSlice(allocator);
}

/// 3 局で L1+L2 共通に見える PRN のうち、平均 CNR (3 局 × 2 band = 6 値) が
/// 最大のものを reference PRN として返す。タイは最小 PRN。
/// 各 PRN について ephemeris store に GPS eph が登録されている必要がある。
///
/// 返り値 null: 共通可視 PRN が無いか、eph が無い場合。
pub fn pickReferencePrn(
    stations: []const StationObsEx,
    eph_store: *const ephemeris.EphemerisStore,
) ?u8 {
    if (stations.len < 3) return null;

    var best_prn: ?u8 = null;
    var best_avg: f64 = -1.0; // 0 dB-Hz より小さい初期値 (null L1/L2 で 0 入る)

    for (stations[0].obs) |obs_a| {
        if (obs_a.l1_m == null or obs_a.l2_m == null) continue;
        const prn = obs_a.prn;
        if (eph_store.lookupGps(prn) == null) continue;

        // 他 2 局で同 PRN を探す + L1/L2 揃ってる
        const obs_b = findSatObsEx(stations[1].obs, prn) orelse continue;
        const obs_c = findSatObsEx(stations[2].obs, prn) orelse continue;
        if (obs_b.l1_m == null or obs_b.l2_m == null) continue;
        if (obs_c.l1_m == null or obs_c.l2_m == null) continue;

        const cnr_sum =
            (obs_a.l1_cnr_db_hz orelse 0.0) + (obs_a.l2_cnr_db_hz orelse 0.0) +
            (obs_b.l1_cnr_db_hz orelse 0.0) + (obs_b.l2_cnr_db_hz orelse 0.0) +
            (obs_c.l1_cnr_db_hz orelse 0.0) + (obs_c.l2_cnr_db_hz orelse 0.0);
        const avg = cnr_sum / 6.0;

        // 厳密一致のときは小さい PRN を優先 (= 後から見たより大きい PRN は採用しない)
        if (avg > best_avg) {
            best_avg = avg;
            best_prn = prn;
        }
    }
    return best_prn;
}

fn findSatObsEx(list: []const SatObsEx, prn: u8) ?SatObsEx {
    for (list) |obs| {
        if (obs.prn == prn) return obs;
    }
    return null;
}

/// 1 (PRN, station) の SD residual = L − ρ − c·dt_sat [m]。
/// L (observed phase [m]) と eph と station ECEF と受信時刻を取り、SI 残差を返す。
/// 戻り値の SD residual には station clock + iono + tropo + N·λ + ε が含まれる。
fn computeSdResidualGps(
    eph: ephemeris.GpsEphemeris,
    t_recv_sow: f64,
    sta_ecef: [3]f64,
    l_observed_m: f64,
    tgd_apply: bool,
) f64 {
    const gr = orbit.geometricRangeGps(eph, t_recv_sow, sta_ecef);
    const dt_sat = orbit.satClockBiasGps(eph, gr.t_emit_sow, gr.ecc_anomaly_rad, tgd_apply);
    return l_observed_m - gr.rho_m - orbit.C_LIGHT * dt_sat;
}

/// Phase 7-3 メイン: ephemeris ベースの DD residual から FKP plane fit。
///
/// 入力:
///   stations[0] = 中心局 A、[1] = 補助 B、[2] = 補助 C
///   eph_store: 各 PRN の GPS broadcast eph (1019 受信済)
///   ref_prn: reference PRN (`pickReferencePrn` 推奨。null だと auto)
///   options: 既存 `computeFkp` と同じ閾値判定 + 統計
///
/// 出力:
///   FkpParam[] (ref PRN 自身は含まない、DD ≡ 0 で意味なし)
///
/// アルゴリズム:
///   1. ref PRN の SD residual を 3 局で計算 → SD pair difference (B-A, C-A)
///   2. 各 non-ref PRN j について:
///      - SD residual を 3 局で計算 → SD pair difference
///      - DD = SD_j − SD_ref (L1/L2 別)
///      - LIF (α·L1−β·L2) / LGF (L1−L2) で平面 fit
///      - n_i/e_i/n_0/e_0 を FkpParam に格納
///   3. 閾値超過の PRN は棄却 (Phase 6a 維持)
pub fn computeFkpDd(
    allocator: std.mem.Allocator,
    stations: []const StationObsEx,
    eph_store: *const ephemeris.EphemerisStore,
    ref_prn_in: ?u8,
    options: ComputeOptions,
) ![]FkpParam {
    if (options.stats) |s| s.* = .{};
    if (stations.len < 3) return &.{};

    const ref_prn = ref_prn_in orelse pickReferencePrn(stations, eph_store) orelse return &.{};

    const sta_a = stations[0];
    const sta_b = stations[1];
    const sta_c = stations[2];

    // 座標差行列の逆行列 (既存 computeFkp と同じ)
    const dphi_b = sta_b.coord.lat - sta_a.coord.lat;
    const dlam_b = sta_b.coord.lon - sta_a.coord.lon;
    const dphi_c = sta_c.coord.lat - sta_a.coord.lat;
    const dlam_c = sta_c.coord.lon - sta_a.coord.lon;
    const inv_a = invert2x2(dphi_b, dlam_b, dphi_c, dlam_c) orelse return &.{};

    // ── ref PRN の SD pair difference を前計算 ────────────────────────
    const ref_eph_entry = eph_store.lookupGps(ref_prn) orelse return &.{};
    const ref_eph = ref_eph_entry.eph;
    const ref_obs_a = findSatObsEx(sta_a.obs, ref_prn) orelse return &.{};
    const ref_obs_b = findSatObsEx(sta_b.obs, ref_prn) orelse return &.{};
    const ref_obs_c = findSatObsEx(sta_c.obs, ref_prn) orelse return &.{};

    const ref_l1_a = ref_obs_a.l1_m orelse return &.{};
    const ref_l1_b = ref_obs_b.l1_m orelse return &.{};
    const ref_l1_c = ref_obs_c.l1_m orelse return &.{};
    const ref_l2_a = ref_obs_a.l2_m orelse return &.{};
    const ref_l2_b = ref_obs_b.l2_m orelse return &.{};
    const ref_l2_c = ref_obs_c.l2_m orelse return &.{};

    const ref_res_l1_a = computeSdResidualGps(ref_eph, sta_a.t_recv_sow, sta_a.ecef, ref_l1_a, true);
    const ref_res_l1_b = computeSdResidualGps(ref_eph, sta_b.t_recv_sow, sta_b.ecef, ref_l1_b, true);
    const ref_res_l1_c = computeSdResidualGps(ref_eph, sta_c.t_recv_sow, sta_c.ecef, ref_l1_c, true);
    const ref_res_l2_a = computeSdResidualGps(ref_eph, sta_a.t_recv_sow, sta_a.ecef, ref_l2_a, true);
    const ref_res_l2_b = computeSdResidualGps(ref_eph, sta_b.t_recv_sow, sta_b.ecef, ref_l2_b, true);
    const ref_res_l2_c = computeSdResidualGps(ref_eph, sta_c.t_recv_sow, sta_c.ecef, ref_l2_c, true);

    const sd_ref_l1_b = ref_res_l1_b - ref_res_l1_a;
    const sd_ref_l1_c = ref_res_l1_c - ref_res_l1_a;
    const sd_ref_l2_b = ref_res_l2_b - ref_res_l2_a;
    const sd_ref_l2_c = ref_res_l2_c - ref_res_l2_a;

    // ── 各 non-ref PRN ────────────────────────────────────────────────
    var fkp_list = std.ArrayList(FkpParam).empty;

    for (sta_a.obs) |obs_a| {
        const prn = obs_a.prn;
        if (prn == ref_prn) continue;

        const eph_entry = eph_store.lookupGps(prn) orelse continue;
        const eph = eph_entry.eph;

        const obs_b = findSatObsEx(sta_b.obs, prn) orelse continue;
        const obs_c = findSatObsEx(sta_c.obs, prn) orelse continue;

        const l1_a = obs_a.l1_m orelse continue;
        const l1_b = obs_b.l1_m orelse continue;
        const l1_c = obs_c.l1_m orelse continue;
        const l2_a = obs_a.l2_m orelse continue;
        const l2_b = obs_b.l2_m orelse continue;
        const l2_c = obs_c.l2_m orelse continue;

        const res_l1_a = computeSdResidualGps(eph, sta_a.t_recv_sow, sta_a.ecef, l1_a, true);
        const res_l1_b = computeSdResidualGps(eph, sta_b.t_recv_sow, sta_b.ecef, l1_b, true);
        const res_l1_c = computeSdResidualGps(eph, sta_c.t_recv_sow, sta_c.ecef, l1_c, true);
        const res_l2_a = computeSdResidualGps(eph, sta_a.t_recv_sow, sta_a.ecef, l2_a, true);
        const res_l2_b = computeSdResidualGps(eph, sta_b.t_recv_sow, sta_b.ecef, l2_b, true);
        const res_l2_c = computeSdResidualGps(eph, sta_c.t_recv_sow, sta_c.ecef, l2_c, true);

        const sd_l1_b = res_l1_b - res_l1_a;
        const sd_l1_c = res_l1_c - res_l1_a;
        const sd_l2_b = res_l2_b - res_l2_a;
        const sd_l2_c = res_l2_c - res_l2_a;

        // DD = SD_j − SD_ref
        const dd_l1_b = sd_l1_b - sd_ref_l1_b;
        const dd_l1_c = sd_l1_c - sd_ref_l1_c;
        const dd_l2_b = sd_l2_b - sd_ref_l2_b;
        const dd_l2_c = sd_l2_c - sd_ref_l2_c;

        const lgf_b = dd_l1_b - dd_l2_b;
        const lgf_c = dd_l1_c - dd_l2_c;
        const lif_b = ALPHA * dd_l1_b - BETA * dd_l2_b;
        const lif_c = ALPHA * dd_l1_c - BETA * dd_l2_c;

        const n_i = inv_a[0][0] * lgf_b + inv_a[0][1] * lgf_c;
        const e_i = inv_a[1][0] * lgf_b + inv_a[1][1] * lgf_c;
        const n_0 = inv_a[0][0] * lif_b + inv_a[0][1] * lif_c;
        const e_0 = inv_a[1][0] * lif_b + inv_a[1][1] * lif_c;

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
