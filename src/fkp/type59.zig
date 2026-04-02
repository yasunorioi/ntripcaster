//! fkp/type59.zig — RTCM3 Type 59 (FKP) エンコード
//!
//! Type 59 は RTCM 10403.3 の "reserved" メッセージ番号をプロプライエタリ拡張として使用。
//! BKG/EUREF 方式に近似した簡易フォーマット（互換性よりも動作実証を優先）。
//!
//! フレーム構造:
//!   ヘッダー: msg_num(12) + ref_id(12) + tow_ms(30) + multi_msg(1) + nsat(6) = 61 bit
//!   衛星毎:  prn(8) + N_I(16) + E_I(16) + N_0(16) + E_0(16) = 72 bit
//!
//! スケーリング:
//!   N_I, E_I (電離層): 1 LSB = 1e-5 m/rad
//!   N_0, E_0 (幾何学): 1 LSB = 1e-4 m/rad

const std = @import("std");
const engine = @import("engine.zig");
const rtcm3 = @import("../ntrip/rtcm3.zig");
const bits = @import("bits.zig");

const BitWriter = bits.BitWriter;

pub const MSG_TYPE: u16 = 59;

/// 電離層パラメータスケーリング [m/rad → LSB]
pub const SCALE_I: f64 = 1.0e5;
/// 幾何学パラメータスケーリング [m/rad → LSB]
pub const SCALE_0: f64 = 1.0e4;

/// i64 値を i16 にクランプ変換
fn clampI16(v: f64, scale: f64) i16 {
    const scaled = v * scale;
    const clamped = @max(-32768.0, @min(32767.0, scaled));
    return @as(i16, @intFromFloat(@trunc(clamped)));
}

/// RTCM Type 59 FKP フレームをエンコードする。
///
/// ref_station_id: 参照局 ID
/// tow_ms:         GPS Time of Week [ms]
/// fkp_params:     FKP パラメータスライス（最大 63 衛星）
///
/// 返却値: 完全な RTCM3 フレーム（CRC 含む）。allocator で解放すること。
pub fn encodeType59(
    allocator: std.mem.Allocator,
    ref_station_id: u16,
    tow_ms: u32,
    fkp_params: []const engine.FkpParam,
) ![]u8 {
    const nsat: u6 = @truncate(@min(fkp_params.len, 63));

    // ペイロードサイズ: ヘッダー(61bit) + 衛星毎(72bit) → バイト単位に切り上げ
    const payload_bits: usize = 61 + @as(usize, nsat) * 72;
    const payload_bytes: usize = (payload_bits + 7) / 8;
    const frame_len = 3 + payload_bytes + 3;

    const buf = try allocator.alloc(u8, frame_len);
    @memset(buf, 0);

    // RTCM3 フレームヘッダー
    buf[0] = rtcm3.PREAMBLE;
    buf[1] = @truncate((payload_bytes >> 8) & 0x03);
    buf[2] = @truncate(payload_bytes & 0xFF);

    // ペイロード
    var bw = BitWriter.init(buf[3 .. 3 + payload_bytes]);
    bw.writeU(12, MSG_TYPE);
    bw.writeU(12, ref_station_id);
    bw.writeU(30, tow_ms);
    bw.writeU(1, 0); // multiple message: no
    bw.writeU(6, nsat);

    for (fkp_params[0..nsat]) |p| {
        bw.writeU(8, p.prn);
        bw.writeS(16, clampI16(p.n_i, SCALE_I));
        bw.writeS(16, clampI16(p.e_i, SCALE_I));
        bw.writeS(16, clampI16(p.n_0, SCALE_0));
        bw.writeS(16, clampI16(p.e_0, SCALE_0));
    }

    // CRC-24Q
    const crc = rtcm3.crc24q(buf[0 .. 3 + payload_bytes]);
    buf[3 + payload_bytes + 0] = @truncate(crc >> 16);
    buf[3 + payload_bytes + 1] = @truncate(crc >> 8);
    buf[3 + payload_bytes + 2] = @truncate(crc);

    return buf;
}

/// Type 59 フレームをデコードして FkpParam スライスを返す。
/// 検証: msg_type == 59, CRC OK
pub fn decodeType59(
    allocator: std.mem.Allocator,
    frame: []const u8,
) ![]engine.FkpParam {
    // CRC 検証
    if (frame.len < 6) return &.{};
    const length: usize = (@as(usize, frame[1] & 0x03) << 8) | frame[2];
    const total = 3 + length + 3;
    if (frame.len < total) return &.{};

    const crc_expected = rtcm3.crc24q(frame[0 .. 3 + length]);
    const crc_actual: u32 = (@as(u32, frame[3 + length]) << 16) |
        (@as(u32, frame[3 + length + 1]) << 8) |
        @as(u32, frame[3 + length + 2]);
    if (crc_expected != crc_actual) return &.{};

    const payload = frame[3 .. 3 + length];
    var br = bits.BitReader.init(payload);

    const msg_type = br.readU(12);
    if (msg_type != MSG_TYPE) return &.{};

    _ = br.readU(12); // ref_station_id
    _ = br.readU(30); // tow_ms
    _ = br.readU(1); // multiple message
    const nsat: usize = @intCast(br.readU(6));

    var list = std.ArrayList(engine.FkpParam){};
    for (0..nsat) |_| {
        const prn: u8 = @truncate(br.readU(8));
        const n_i = @as(f64, @floatFromInt(br.readS(16))) / SCALE_I;
        const e_i = @as(f64, @floatFromInt(br.readS(16))) / SCALE_I;
        const n_0 = @as(f64, @floatFromInt(br.readS(16))) / SCALE_0;
        const e_0 = @as(f64, @floatFromInt(br.readS(16))) / SCALE_0;
        try list.append(allocator, .{ .prn = prn, .n_i = n_i, .e_i = e_i, .n_0 = n_0, .e_0 = e_0 });
    }
    return try list.toOwnedSlice(allocator);
}
