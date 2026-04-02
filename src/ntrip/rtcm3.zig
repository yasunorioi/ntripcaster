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

/// scanFrames の返却値
pub const ScanResult = struct {
    /// data 先頭から消費したバイト数
    consumed: usize,
    /// 発見したメッセージタイプ（最大 64 件）
    msg_types: [64]u16,
    count: usize,
};

/// data 内の RTCM3 フレームを全てスキャンする。
///
/// - 0xD3 バイトを探してフレームパースを試みる。
/// - CRC 不一致はその位置をスキップして次を探す。
/// - 末尾に不完全フレームがある場合は consumed < data.len になる。
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

/// data の先頭付近に RTCM3 プリアンブル (0xD3) が含まれるかを判定する。
/// NTRIP ストリーム種別の簡易自動判別に使用。
pub fn isRtcm3(data: []const u8) bool {
    for (data) |byte| {
        if (byte == PREAMBLE) return true;
    }
    return false;
}
