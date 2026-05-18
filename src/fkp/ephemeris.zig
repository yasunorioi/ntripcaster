//! fkp/ephemeris.zig — RTCM3 放送暦 (broadcast ephemeris) パースと保管
//!
//! 対応メッセージ (Phase 7-1 時点):
//!   1019 = GPS Ephemeris (488 bit)
//!
//! 後続 phase で 1020 (GLO) / 1042 (BDS) / 1045 (Gal F/NAV) / 1046 (Gal I/NAV)
//! を追加する想定。docs/phase7-design.md § 3 参照。
//!
//! パース時に raw scaled int から SI 単位 (s, m, rad) に変換するので、
//! 下流の orbit propagator は scale 定数を再記述しなくてよい。

const std = @import("std");
const bits = @import("bits.zig");

const BitReader = bits.BitReader;

/// GPS L1 周波数 (sat clock 補正に必要)
pub const GPS_L1_FREQ_HZ: f64 = 1575.42e6;

/// 単位変換定数。RTCM 10403.3 § 3.5.13 (DF079..DF137) の scale を使う。
const PI: f64 = std.math.pi;
const POW2_M5: f64 = 1.0 / 32.0; // 2^-5
const POW2_M19: f64 = 1.0 / 524288.0; // 2^-19
const POW2_M29: f64 = 1.0 / 536870912.0; // 2^-29
const POW2_M31: f64 = 1.0 / 2147483648.0; // 2^-31
const POW2_M33: f64 = 1.0 / 8589934592.0; // 2^-33
const POW2_M43: f64 = 1.0 / 8796093022208.0; // 2^-43
const POW2_M55: f64 = 1.0 / 36028797018963968.0; // 2^-55
const POW2_4: f64 = 16.0; // 2^4

/// GPS 衛星 1 機の broadcast ephemeris (RTCM 1019 由来)。
/// すべて SI 単位 (s / m / rad)。raw scaled int は parse 時に変換済。
pub const GpsEphemeris = struct {
    /// PRN (1..32)
    prn: u8,
    /// GPS week (mod 1024。絶対 week への展開は呼び出し側で行う)
    week_mod1024: u16,
    /// User Range Accuracy index (0..15、RTCM DF077 raw)
    sv_acc: u4,
    /// Code on L2 (DF078 raw)
    code_on_l2: u2,
    /// Issue of Data, Ephemeris (DF071) — 同一 PRN の eph 識別子
    iode: u8,
    /// Issue of Data, Clock (DF085)
    iodc: u10,
    /// SV health (DF102、0 = healthy)
    sv_health: u6,
    /// L2P data flag (DF103)
    l2p_flag: u1,
    /// fit interval flag (DF137): 0 = 4h, 1 = > 4h
    fit_interval_flag: u1,

    /// 時計補正基準時刻 [GPS second of week]
    toc_s: f64,
    /// 軌道要素基準時刻 [GPS second of week]
    toe_s: f64,

    /// 時計補正多項式 [s, s/s, s/s²]
    af0_s: f64,
    af1_s_per_s: f64,
    af2_s_per_s2: f64,

    /// 軌道摂動補正項 (調和項) [m, rad]
    crs_m: f64,
    crc_m: f64,
    cuc_rad: f64,
    cus_rad: f64,
    cic_rad: f64,
    cis_rad: f64,

    /// Keplerian 6 要素
    /// mean motion difference [rad/s]
    dn_rad_per_s: f64,
    /// mean anomaly at toe [rad]
    m0_rad: f64,
    /// eccentricity (dimensionless)
    ecc: f64,
    /// √(semi-major axis) [√m]
    sqrt_a_m: f64,

    /// longitude of ascending node at week start [rad]
    omega0_rad: f64,
    /// rate of right ascension [rad/s]
    omdot_rad_per_s: f64,
    /// inclination at toe [rad]
    i0_rad: f64,
    /// rate of inclination [rad/s]
    idot_rad_per_s: f64,
    /// argument of perigee [rad]
    argp_rad: f64,

    /// L1-L2 group delay differential [s]
    tgd_s: f64,
};

/// RTCM3 Type 1019 ペイロードから GpsEphemeris をパースする。
/// payload: msg_type(12bit) を含むペイロード全体。
///
/// 失敗時は null:
///   - payload 長が 488 bit (= 61 byte) 未満
///   - msg_type フィールドが 1019 でない
pub fn parseMsg1019(payload: []const u8) ?GpsEphemeris {
    // 488 bit = 61 byte
    if (payload.len < 61) return null;
    var br = BitReader.init(payload);

    const msg = br.readU(12);
    if (msg != 1019) return null;

    const prn: u8 = @truncate(br.readU(6));
    const week_mod1024: u16 = @truncate(br.readU(10));
    const sv_acc: u4 = @truncate(br.readU(4));
    const code_on_l2: u2 = @truncate(br.readU(2));
    const idot_raw = br.readS(14);
    const iode: u8 = @truncate(br.readU(8));
    const toc_raw = br.readU(16);
    const af2_raw = br.readS(8);
    const af1_raw = br.readS(16);
    const af0_raw = br.readS(22);
    const iodc: u10 = @truncate(br.readU(10));
    const crs_raw = br.readS(16);
    const dn_raw = br.readS(16);
    const m0_raw = br.readS(32);
    const cuc_raw = br.readS(16);
    const ecc_raw = br.readU(32);
    const cus_raw = br.readS(16);
    const sqrt_a_raw = br.readU(32);
    const toe_raw = br.readU(16);
    const cic_raw = br.readS(16);
    const omega0_raw = br.readS(32);
    const cis_raw = br.readS(16);
    // `i0_raw` だと Zig が primitive integer type prefix `i0` と誤認するため
    // `inc_raw` (inclination) を使う。
    const inc_raw = br.readS(32);
    const crc_raw = br.readS(16);
    const argp_raw = br.readS(32);
    const omdot_raw = br.readS(24);
    const tgd_raw = br.readS(8);
    const sv_health: u6 = @truncate(br.readU(6));
    const l2p_flag: u1 = @truncate(br.readU(1));
    const fit_interval_flag: u1 = @truncate(br.readU(1));

    return .{
        .prn = prn,
        .week_mod1024 = week_mod1024,
        .sv_acc = sv_acc,
        .code_on_l2 = code_on_l2,
        .iode = iode,
        .iodc = iodc,
        .sv_health = sv_health,
        .l2p_flag = l2p_flag,
        .fit_interval_flag = fit_interval_flag,

        .toc_s = @as(f64, @floatFromInt(toc_raw)) * POW2_4,
        .toe_s = @as(f64, @floatFromInt(toe_raw)) * POW2_4,

        .af0_s = @as(f64, @floatFromInt(af0_raw)) * POW2_M31,
        .af1_s_per_s = @as(f64, @floatFromInt(af1_raw)) * POW2_M43,
        .af2_s_per_s2 = @as(f64, @floatFromInt(af2_raw)) * POW2_M55,

        .crs_m = @as(f64, @floatFromInt(crs_raw)) * POW2_M5,
        .crc_m = @as(f64, @floatFromInt(crc_raw)) * POW2_M5,
        .cuc_rad = @as(f64, @floatFromInt(cuc_raw)) * POW2_M29,
        .cus_rad = @as(f64, @floatFromInt(cus_raw)) * POW2_M29,
        .cic_rad = @as(f64, @floatFromInt(cic_raw)) * POW2_M29,
        .cis_rad = @as(f64, @floatFromInt(cis_raw)) * POW2_M29,

        // semi-circles → radians: × π
        .dn_rad_per_s = @as(f64, @floatFromInt(dn_raw)) * POW2_M43 * PI,
        .m0_rad = @as(f64, @floatFromInt(m0_raw)) * POW2_M31 * PI,
        .ecc = @as(f64, @floatFromInt(ecc_raw)) * POW2_M33,
        .sqrt_a_m = @as(f64, @floatFromInt(sqrt_a_raw)) * POW2_M19,

        .omega0_rad = @as(f64, @floatFromInt(omega0_raw)) * POW2_M31 * PI,
        .omdot_rad_per_s = @as(f64, @floatFromInt(omdot_raw)) * POW2_M43 * PI,
        .i0_rad = @as(f64, @floatFromInt(inc_raw)) * POW2_M31 * PI,
        .idot_rad_per_s = @as(f64, @floatFromInt(idot_raw)) * POW2_M43 * PI,
        .argp_rad = @as(f64, @floatFromInt(argp_raw)) * POW2_M31 * PI,

        .tgd_s = @as(f64, @floatFromInt(tgd_raw)) * POW2_M31,
    };
}

/// GPS 衛星 PRN → GpsEphemeris の最新エントリ。
/// 同一 PRN で IODE が異なる新着が来たら上書き保管 (broadcast eph は数十分
/// ごとに更新される)。スレッド安全性は呼び出し側 (Upstream) の Mutex に
/// 委ねる — store 自体は lock を持たない。
pub const EphemerisStore = struct {
    alloc: std.mem.Allocator,
    /// PRN → eph + 受信時刻 [ms]
    gps: std.AutoHashMapUnmanaged(u8, Entry) = .{},

    pub const Entry = struct {
        eph: GpsEphemeris,
        received_at_ms: i64,
    };

    pub fn init(alloc: std.mem.Allocator) EphemerisStore {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *EphemerisStore) void {
        self.gps.deinit(self.alloc);
    }

    /// GPS eph を 1 件 upsert。同一 PRN は常に上書き (受信順 = 新しさ)。
    pub fn upsertGps(self: *EphemerisStore, eph: GpsEphemeris, now_ms: i64) !void {
        try self.gps.put(self.alloc, eph.prn, .{ .eph = eph, .received_at_ms = now_ms });
    }

    /// PRN 指定で最新 GPS eph を返す。未登録なら null。
    /// 注: fit interval 内かどうかは呼び出し側が toe_s と現 GPS week 時刻を
    ///     比較して判断する (本 store は age 判定を持たない)。
    pub fn lookupGps(self: *const EphemerisStore, prn: u8) ?Entry {
        return self.gps.get(prn);
    }

    /// 登録 PRN 数 (デバッグ用)
    pub fn countGps(self: *const EphemerisStore) usize {
        return self.gps.count();
    }
};
