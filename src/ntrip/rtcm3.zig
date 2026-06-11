//! ntrip/rtcm3.zig — RTCM3フレーム解析
//!
//! RTCM 10403.3 フレーム構造:
//!   [0xD3][len_hi][len_lo][payload(len bytes)][CRC-24Q(3 bytes)]
//!
//!   len  = (byte[1] & 0x03) << 8 | byte[2]  (10 bit)
//!   総長 = 3 + len + 3
//!
//! CRC-24Q 多項式: 0x1864CFB
//! メッセージタイプ: ペイロード先頭 12bit
//!   msg_type = (payload[0] << 4) | (payload[1] >> 4)

const std = @import("std");

/// RTCM3 プリアンブルバイト
pub const PREAMBLE: u8 = 0xD3;

/// CRC-24Q 計算。
/// RTCM3 標準に従い、計算対象は [preamble + len_hi + len_lo + payload] の全バイト。
pub fn crc24q(data: []const u8) u32 {
    var crc: u32 = 0;
    for (data) |byte| {
        crc ^= @as(u32, byte) << 16;
        for (0..8) |_| {
            crc <<= 1;
            if (crc & 0x1000000 != 0) crc ^= 0x1864cfb;
        }
    }
    return crc & 0xFFFFFF;
}

/// parseFrame の返却値
pub const ParseResult = struct {
    msg_type: u16,
    /// このフレームが消費したバイト数（次フレームへのオフセット）
    consumed: usize,
};

/// data[0] == PREAMBLE と仮定してフレームをパースする。
///
/// - データ不足（不完全フレーム）: null
/// - CRC 不一致:                  null
/// - ペイロード 2 バイト未満:      null（メッセージタイプ抽出不能）
pub fn parseFrame(data: []const u8) ?ParseResult {
    // 最小サイズ: preamble(1) + len(2) + CRC(3) = 6
    if (data.len < 6) return null;
    if (data[0] != PREAMBLE) return null;

    const length: usize = (@as(usize, data[1] & 0x03) << 8) | data[2];
    const total = 3 + length + 3;

    if (data.len < total) return null; // 不完全フレーム
    if (length < 2) return null; // メッセージタイプ抽出に 2 バイト必要

    // CRC 検証
    const expected = crc24q(data[0 .. 3 + length]);
    const actual: u32 = (@as(u32, data[3 + length]) << 16) |
        (@as(u32, data[3 + length + 1]) << 8) |
        @as(u32, data[3 + length + 2]);

    if (expected != actual) return null;

    const msg_type: u16 = (@as(u16, data[3]) << 4) | (data[4] >> 4);

    return .{
        .msg_type = msg_type,
        .consumed = total,
    };
}

/// 基準局座標 (RTCM3 MSG 1005 / 1006 から抽出)
pub const StationCoord = struct {
    ref_station_id: u16,
    /// ECEF 座標 [m]
    x: f64,
    y: f64,
    z: f64,
    /// WGS84 緯度経度 [deg]
    lat_deg: f64,
    lon_deg: f64,
    /// 1006 のときアンテナ高 [m]、1005 のときは 0.0
    antenna_height_m: f64,
};

/// scanFrames の返却値
pub const ScanResult = struct {
    /// data 先頭から消費したバイト数
    consumed: usize,
    /// 発見したメッセージタイプ（最大 64 件）
    msg_types: [64]u16,
    count: usize,
    /// 1005 / 1006 が見つかったときに格納される基準局座標。
    /// 1 回の scan で複数見つかった場合は最後のものが残る。
    station: ?StationCoord = null,
};

/// data 内の RTCM3 フレームを全てスキャンする。
///
/// - 0xD3 バイトを探してフレームパースを試みる。
/// - CRC 不一致はその位置をスキップして次を探す。
/// - 末尾に不完全フレームがある場合は consumed < data.len になる。
/// - 1005 / 1006 フレームが含まれていれば `result.station` に座標を入れる。
pub fn scanFrames(data: []const u8) ScanResult {
    var result = ScanResult{
        .consumed = 0,
        .msg_types = undefined,
        .count = 0,
    };
    var pos: usize = 0;

    while (pos < data.len) {
        if (data[pos] != PREAMBLE) {
            pos += 1;
            continue;
        }

        if (parseFrame(data[pos..])) |frame| {
            if (result.count < result.msg_types.len) {
                result.msg_types[result.count] = frame.msg_type;
                result.count += 1;
            }
            // 1005 / 1006 を見つけたら座標を抽出
            if (frame.msg_type == 1005 or frame.msg_type == 1006) {
                const payload_len: usize = (@as(usize, data[pos + 1] & 0x03) << 8) | data[pos + 2];
                const payload = data[pos + 3 .. pos + 3 + payload_len];
                if (parseStation(payload)) |sc| result.station = sc;
            }
            pos += frame.consumed;
        } else {
            // 末尾まで 6 バイト未満なら不完全フレームとして待機
            if (data.len - pos < 6) break;
            // それ以外は CRC エラーなので 1 バイトスキップ
            pos += 1;
        }
    }

    result.consumed = pos;
    return result;
}

// ── 1005 / 1006 station coordinate parser ─────────────────────────────────────

/// RTCM3 payload (msg_type 12bit から始まる) から MSB ファーストで bit 単位読み出し。
const BitReader = struct {
    data: []const u8,
    bit_pos: usize,

    fn init(data: []const u8) BitReader {
        return .{ .data = data, .bit_pos = 0 };
    }

    /// 指定 bit 数を unsigned で読む (最大 64 bit)
    fn readU(self: *BitReader, n: u7) u64 {
        var v: u64 = 0;
        var remaining: u7 = n;
        while (remaining > 0) {
            const byte_idx = self.bit_pos / 8;
            const bit_idx: u3 = @intCast(self.bit_pos % 8);
            if (byte_idx >= self.data.len) return v;
            const bits_in_byte: u7 = 8 - @as(u7, bit_idx);
            const take: u7 = @min(remaining, bits_in_byte);
            const byte = self.data[byte_idx];
            const shifted: u8 = byte >> @intCast(bits_in_byte - take);
            // take は 1..=8 なのでマスクを u16 で組み立てて u8 にトリム
            const mask: u8 = @truncate((@as(u16, 1) << @intCast(take)) - 1);
            v = (v << @intCast(take)) | (shifted & mask);
            self.bit_pos += take;
            remaining -= take;
        }
        return v;
    }

    fn readS(self: *BitReader, n: u7) i64 {
        const u = self.readU(n);
        // n bit の値を sign-extend
        const sign_bit: u64 = @as(u64, 1) << @intCast(n - 1);
        if ((u & sign_bit) != 0) {
            const mask: u64 = (~@as(u64, 0)) << @intCast(n);
            return @bitCast(u | mask);
        }
        return @intCast(u);
    }

    fn skip(self: *BitReader, n: u7) void {
        self.bit_pos += n;
    }
};

/// MSG 1005 / 1006 ペイロード (msg_type 12bit から始まる) から StationCoord を取り出す。
/// 1005: payload >= 19 byte、1006: payload >= 21 byte (末尾にアンテナ高 16bit)。
pub fn parseStation(payload: []const u8) ?StationCoord {
    if (payload.len < 19) return null;
    var br = BitReader.init(payload);
    const msg_type = br.readU(12);
    if (msg_type != 1005 and msg_type != 1006) return null;
    const ref_id: u16 = @truncate(br.readU(12));
    br.skip(6); // ITRF realization year
    br.skip(4); // GPS / GLONASS / Galileo indicators + station indicator
    const x_raw = br.readS(38);
    br.skip(2); // single receiver osc + reserved
    const y_raw = br.readS(38);
    br.skip(1); // quarter cycle indicator
    const z_raw = br.readS(38);

    var ant_h: f64 = 0.0;
    if (msg_type == 1006) {
        if (payload.len < 21) return null;
        const h_raw = br.readU(16);
        ant_h = @as(f64, @floatFromInt(h_raw)) * 0.0001;
    }

    const x: f64 = @as(f64, @floatFromInt(x_raw)) * 0.0001;
    const y: f64 = @as(f64, @floatFromInt(y_raw)) * 0.0001;
    const z: f64 = @as(f64, @floatFromInt(z_raw)) * 0.0001;

    const ll = ecefToLatLonDeg(x, y, z);
    return .{
        .ref_station_id = ref_id,
        .x = x,
        .y = y,
        .z = z,
        .lat_deg = ll[0],
        .lon_deg = ll[1],
        .antenna_height_m = ant_h,
    };
}

/// ECEF [m] → WGS84 緯度経度 [deg] (Bowring 1985 閉形式近似)
fn ecefToLatLonDeg(x: f64, y: f64, z: f64) [2]f64 {
    const a: f64 = 6378137.0;
    const e2: f64 = 0.00669437999014; // WGS84 first eccentricity squared
    const ep2: f64 = e2 / (1.0 - e2);
    const b: f64 = a * @sqrt(1.0 - e2);
    const p = @sqrt(x * x + y * y);
    const theta = std.math.atan2(z * a, p * b);
    const sin_t = @sin(theta);
    const cos_t = @cos(theta);
    const lat = std.math.atan2(z + ep2 * b * sin_t * sin_t * sin_t, p - e2 * a * cos_t * cos_t * cos_t);
    const lon = std.math.atan2(y, x);
    const rad2deg: f64 = 180.0 / std.math.pi;
    return .{ lat * rad2deg, lon * rad2deg };
}

/// data の先頭付近に RTCM3 プリアンブル (0xD3) が含まれるかを判定する。
/// NTRIP ストリーム種別の簡易自動判別に使用。
pub fn isRtcm3(data: []const u8) bool {
    for (data) |byte| {
        if (byte == PREAMBLE) return true;
    }
    return false;
}
