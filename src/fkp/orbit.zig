//! fkp/orbit.zig — GPS 衛星軌道計算 (broadcast ephemeris ベース)
//!
//! 入力: GpsEphemeris (パース済 SI 単位) + GPS second-of-week
//! 出力: 衛星 ECEF [x, y, z] [m]、+ sat clock bias [s] + geometric range
//!
//! アルゴリズム: IS-GPS-200L (2020-09) Table 20-IV
//! "User Algorithm for SV Position Determination"。
//!
//! 摂動補正は cuc/cus/crs/crc/cic/cis の調和項 + dn/idot/omdot の secular。
//! Kepler 方程式は Newton 反復 (~10 step) で 1e-13 rad 収束を保証。
//!
//! Phase 7-3 以降の DD residual / FKP 計算で `geometricRangeGps` を使う。

const std = @import("std");
const eph_mod = @import("ephemeris.zig");

const GpsEphemeris = eph_mod.GpsEphemeris;

// ── 物理定数 ─────────────────────────────────────────────────────────────────

/// 地球重力定数 (WGS-84, ICD-GPS-200) [m³/s²]
pub const GM_EARTH: f64 = 3.986005e14;
/// 地球自転角速度 (WGS-84) [rad/s]
pub const OMEGA_EARTH: f64 = 7.2921151467e-5;
/// 光速 [m/s]
pub const C_LIGHT: f64 = 299792458.0;
/// 相対論補正係数 F = -2·sqrt(GM) / c² [s/√m]
pub const RELATIVISTIC_F: f64 = -4.442807633e-10;
/// GPS week 秒数
pub const SECONDS_PER_WEEK: f64 = 7.0 * 24.0 * 3600.0;

// ── 衛星 ECEF 計算 ───────────────────────────────────────────────────────────

/// 衛星 ECEF 位置計算の結果。
pub const SatPosition = struct {
    /// ECEF 座標 [m]
    x: f64,
    y: f64,
    z: f64,
    /// Kepler 反復で解いた偏心近点角 E [rad] (光行差補正・相対論補正で再利用)
    eccentric_anomaly_rad: f64,
};

/// `GpsEphemeris` と GPS second-of-week `t_sow` から衛星 ECEF 位置を計算する。
/// `t_sow` は signal-emission 時刻 (=送信時刻、受信時刻から τ を引いたもの)。
///
/// IS-GPS-200L Table 20-IV 準拠。GPS week rollover は呼び出し側が tk の符号
/// を 1 週単位で補正してから渡す前提 (`t_sow - toe_s` が ±302400 s 超えたら
/// ±SECONDS_PER_WEEK 補正)。
pub fn gpsSatEcef(eph: GpsEphemeris, t_sow: f64) SatPosition {
    // semi-major axis
    const a = eph.sqrt_a_m * eph.sqrt_a_m;

    // mean motion (corrected)
    const n0 = std.math.sqrt(GM_EARTH / (a * a * a));
    const n = n0 + eph.dn_rad_per_s;

    // time from ephemeris reference (with week wrap correction)
    var tk = t_sow - eph.toe_s;
    if (tk > 302400.0) tk -= SECONDS_PER_WEEK;
    if (tk < -302400.0) tk += SECONDS_PER_WEEK;

    // mean anomaly
    const mk = eph.m0_rad + n * tk;

    // eccentric anomaly: Newton iteration on Kepler equation M = E - e·sin(E)
    var ek = mk;
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        const sin_ek = @sin(ek);
        const cos_ek = @cos(ek);
        const f = ek - eph.ecc * sin_ek - mk;
        const f_prime = 1.0 - eph.ecc * cos_ek;
        const delta = f / f_prime;
        ek -= delta;
        if (@abs(delta) < 1e-13) break;
    }

    // true anomaly
    const sin_ek = @sin(ek);
    const cos_ek = @cos(ek);
    const sqrt_1me2 = std.math.sqrt(1.0 - eph.ecc * eph.ecc);
    const vk = std.math.atan2(sqrt_1me2 * sin_ek, cos_ek - eph.ecc);

    // argument of latitude
    const phi_k = vk + eph.argp_rad;
    const sin_2phi = @sin(2.0 * phi_k);
    const cos_2phi = @cos(2.0 * phi_k);

    // second harmonic perturbations
    const du = eph.cus_rad * sin_2phi + eph.cuc_rad * cos_2phi;
    const dr = eph.crs_m * sin_2phi + eph.crc_m * cos_2phi;
    const di = eph.cis_rad * sin_2phi + eph.cic_rad * cos_2phi;

    // corrected argument of latitude / radius / inclination
    const u = phi_k + du;
    const r = a * (1.0 - eph.ecc * cos_ek) + dr;
    const incl = eph.i0_rad + eph.idot_rad_per_s * tk + di;

    // in-plane position
    const xp = r * @cos(u);
    const yp = r * @sin(u);

    // corrected longitude of ascending node (account for Earth rotation since toe)
    const omega = eph.omega0_rad +
        (eph.omdot_rad_per_s - OMEGA_EARTH) * tk -
        OMEGA_EARTH * eph.toe_s;

    const sin_omega = @sin(omega);
    const cos_omega = @cos(omega);
    const sin_incl = @sin(incl);
    const cos_incl = @cos(incl);

    return .{
        .x = xp * cos_omega - yp * cos_incl * sin_omega,
        .y = xp * sin_omega + yp * cos_incl * cos_omega,
        .z = yp * sin_incl,
        .eccentric_anomaly_rad = ek,
    };
}

// ── 衛星時計補正 ─────────────────────────────────────────────────────────────

/// 衛星時計バイアス [s]。観測値補正は `t_observed - bias`。
///
/// 内訳:
///   - 多項式: af0 + af1·dt + af2·dt²
///   - 相対論補正: F · e · sqrtA · sin(E)
///   - グループ遅延 tgd は L1 利用者向けに減算 (L2 や iono-free combination
///     の場合は別途扱う; ここでは L1 を返す)
///
/// `t_sow` は emission time。`tgd_apply` で L1 用補正の有無を切り替え。
pub fn satClockBiasGps(eph: GpsEphemeris, t_sow: f64, ecc_anomaly_rad: f64, tgd_apply: bool) f64 {
    var dt = t_sow - eph.toc_s;
    if (dt > 302400.0) dt -= SECONDS_PER_WEEK;
    if (dt < -302400.0) dt += SECONDS_PER_WEEK;

    const poly = eph.af0_s + (eph.af1_s_per_s + eph.af2_s_per_s2 * dt) * dt;
    const relativistic = RELATIVISTIC_F * eph.ecc * eph.sqrt_a_m * @sin(ecc_anomaly_rad);

    var bias = poly + relativistic;
    if (tgd_apply) bias -= eph.tgd_s;
    return bias;
}

// ── Geometric range + 光行差時間補正 ────────────────────────────────────────

/// Geometric range 計算結果。
pub const GeometricRange = struct {
    /// signal emission 時の衛星 ECEF (地球回転補正済) [m]
    sat_ecef_corrected: [3]f64,
    /// 光行差時間 [s] (typical: 0.067 - 0.087 s)
    tau_s: f64,
    /// geometric range [m] (typical: 20000 - 26000 km)
    rho_m: f64,
    /// 光行差収束後の偏心近点角 E [rad]。`satClockBiasGps` の相対論項で
    /// 再利用するため同伴。
    ecc_anomaly_rad: f64,
    /// signal emission 時刻 (= t_recv_sow − tau_s) [GPS sow]。
    /// sat clock bias 計算で受信時刻ではなく emission 時刻を使う必要がある。
    t_emit_sow: f64,
};

/// 受信時刻 `t_recv_sow` (GPS sow) と station ECEF から、衛星 emission 時の
/// 位置と geometric range を反復で求める。
///
/// 1. τ = 0.075 s で初期化 (≈ GPS 平均距離 / c)
/// 2. emission 時の sat ECEF を計算
/// 3. Earth rotation (Ωe × τ で z 軸回転) で受信時刻系に変換
/// 4. ρ = ‖sat − sta‖、τ' = ρ / c
/// 5. |τ' − τ| < 1e-12 なら終了 (通常 2-3 iter)
pub fn geometricRangeGps(
    eph: GpsEphemeris,
    t_recv_sow: f64,
    sta_ecef: [3]f64,
) GeometricRange {
    var tau: f64 = 0.075;
    var sat_x: f64 = 0;
    var sat_y: f64 = 0;
    var sat_z: f64 = 0;
    var ecc_anomaly: f64 = 0;
    var t_emit: f64 = 0;

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        t_emit = t_recv_sow - tau;
        const sat = gpsSatEcef(eph, t_emit);
        ecc_anomaly = sat.eccentric_anomaly_rad;

        // Earth rotation correction: rotate sat ECEF by Ωe·τ around z
        const theta = OMEGA_EARTH * tau;
        const cos_t = @cos(theta);
        const sin_t = @sin(theta);
        sat_x = cos_t * sat.x + sin_t * sat.y;
        sat_y = -sin_t * sat.x + cos_t * sat.y;
        sat_z = sat.z;

        const dx = sat_x - sta_ecef[0];
        const dy = sat_y - sta_ecef[1];
        const dz = sat_z - sta_ecef[2];
        const rho = std.math.sqrt(dx * dx + dy * dy + dz * dz);
        const tau_new = rho / C_LIGHT;
        if (@abs(tau_new - tau) < 1e-12) {
            tau = tau_new;
            break;
        }
        tau = tau_new;
    }

    const dx = sat_x - sta_ecef[0];
    const dy = sat_y - sta_ecef[1];
    const dz = sat_z - sta_ecef[2];
    const rho = std.math.sqrt(dx * dx + dy * dy + dz * dz);

    return .{
        .sat_ecef_corrected = .{ sat_x, sat_y, sat_z },
        .tau_s = tau,
        .rho_m = rho,
        .ecc_anomaly_rad = ecc_anomaly,
        .t_emit_sow = t_emit,
    };
}
