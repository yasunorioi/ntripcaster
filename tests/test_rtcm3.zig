//! tests/test_rtcm3.zig — ntrip/rtcm3.zig のユニットテスト
//!
//! テスト対象:
//!   - crc24q: CRC-24Q 計算の正確性
//!   - parseFrame: 正常系・不正CRC・切り詰めフレーム
//!   - scanFrames: 複数フレーム・非RTCM3ストリーム
//!   - isRtcm3: プリアンブル検出

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const rtcm3 = ntripcaster.ntrip.rtcm3;

// ── テストヘルパー ────────────────────────────────────────────────────────────

/// 指定メッセージタイプと長さで有効な RTCM3 フレームを構築する。
/// ペイロードは先頭 2 バイトにメッセージタイプを埋め込み、残りはゼロ埋め。
fn buildFrame(buf: []u8, msg_type: u16, payload_len: usize) usize {
    std.debug.assert(buf.len >= 3 + payload_len + 3);
    std.debug.assert(payload_len >= 2);

    buf[0] = rtcm3.PREAMBLE;
    buf[1] = @truncate((payload_len >> 8) & 0x03);
    buf[2] = @truncate(payload_len & 0xFF);

    // ペイロード先頭 12bit にメッセージタイプを書き込む
    buf[3] = @truncate(msg_type >> 4);
    buf[4] = @truncate((msg_type & 0x0F) << 4);
    // 残りペイロードはゼロ
    for (buf[5 .. 3 + payload_len]) |*b| b.* = 0;

    const crc = rtcm3.crc24q(buf[0 .. 3 + payload_len]);
    buf[3 + payload_len] = @truncate(crc >> 16);
    buf[3 + payload_len + 1] = @truncate(crc >> 8);
    buf[3 + payload_len + 2] = @truncate(crc);

    return 3 + payload_len + 3;
}

// ── crc24q ────────────────────────────────────────────────────────────────────

test "crc24q: empty data returns 0" {
    try std.testing.expectEqual(@as(u32, 0), rtcm3.crc24q(&.{}));
}

test "crc24q: result is within 24-bit range" {
    // CRC-24Q は 24bit 値。全ての入力に対して 0xFFFFFF 以下であること。
    const crc = rtcm3.crc24q(&.{ 0x00, 0x01, 0x02 });
    try std.testing.expect(crc <= 0xFFFFFF);
}

test "crc24q: preamble byte 0xD3" {
    const crc = rtcm3.crc24q(&.{0xD3});
    try std.testing.expect(crc <= 0xFFFFFF);
}

// ── parseFrame ────────────────────────────────────────────────────────────────

test "parseFrame: valid frame msg_type 1005" {
    var buf: [64]u8 = undefined;
    const total = buildFrame(&buf, 1005, 2);

    const result = rtcm3.parseFrame(buf[0..total]);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 1005), result.?.msg_type);
    try std.testing.expectEqual(total, result.?.consumed);
}

test "parseFrame: valid frame msg_type 1077" {
    var buf: [64]u8 = undefined;
    const total = buildFrame(&buf, 1077, 10);

    const result = rtcm3.parseFrame(buf[0..total]);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 1077), result.?.msg_type);
    try std.testing.expectEqual(total, result.?.consumed);
}

test "parseFrame: invalid CRC returns null" {
    var buf: [64]u8 = undefined;
    const total = buildFrame(&buf, 1005, 4);

    // CRC を破損させる
    buf[total - 1] ^= 0xFF;

    const result = rtcm3.parseFrame(buf[0..total]);
    try std.testing.expect(result == null);
}

test "parseFrame: truncated frame returns null" {
    var buf: [64]u8 = undefined;
    const total = buildFrame(&buf, 1005, 4);

    // 最後の 1 バイトを欠落させる
    const result = rtcm3.parseFrame(buf[0 .. total - 1]);
    try std.testing.expect(result == null);
}

test "parseFrame: too short data returns null" {
    const short: []const u8 = &.{ 0xD3, 0x00 };
    try std.testing.expect(rtcm3.parseFrame(short) == null);
}

test "parseFrame: wrong preamble returns null" {
    var buf: [64]u8 = undefined;
    const total = buildFrame(&buf, 1005, 2);
    buf[0] = 0xAA; // プリアンブル破損

    try std.testing.expect(rtcm3.parseFrame(buf[0..total]) == null);
}

// ── scanFrames ────────────────────────────────────────────────────────────────

test "scanFrames: single frame" {
    var buf: [64]u8 = undefined;
    const total = buildFrame(&buf, 1005, 2);

    const scan = rtcm3.scanFrames(buf[0..total]);
    try std.testing.expectEqual(@as(usize, 1), scan.count);
    try std.testing.expectEqual(@as(u16, 1005), scan.msg_types[0]);
    try std.testing.expectEqual(total, scan.consumed);
}

test "scanFrames: two consecutive frames" {
    var buf: [128]u8 = undefined;
    const len1 = buildFrame(&buf, 1005, 2);
    const len2 = buildFrame(buf[len1..], 1077, 4);
    const total = len1 + len2;

    const scan = rtcm3.scanFrames(buf[0..total]);
    try std.testing.expectEqual(@as(usize, 2), scan.count);
    // 両方のメッセージタイプが含まれる
    var found1005 = false;
    var found1077 = false;
    for (scan.msg_types[0..scan.count]) |mt| {
        if (mt == 1005) found1005 = true;
        if (mt == 1077) found1077 = true;
    }
    try std.testing.expect(found1005);
    try std.testing.expect(found1077);
    try std.testing.expectEqual(total, scan.consumed);
}

test "scanFrames: non-RTCM3 stream returns count 0" {
    // UBX バイナリ（0xB5 0x62 ヘッダー）
    const ubx: []const u8 = &.{ 0xB5, 0x62, 0x01, 0x02, 0x00, 0x00 };
    const scan = rtcm3.scanFrames(ubx);
    try std.testing.expectEqual(@as(usize, 0), scan.count);
}

test "scanFrames: NMEA sentence returns count 0" {
    const nmea = "$GPGGA,123456,3540.00,N,13940.00,E,1,08,1.0,100.0,M,-40.0,M,,*47\r\n";
    const scan = rtcm3.scanFrames(nmea);
    try std.testing.expectEqual(@as(usize, 0), scan.count);
}

test "scanFrames: truncated frame at end leaves unconsumed bytes" {
    var buf: [128]u8 = undefined;
    const len1 = buildFrame(&buf, 1005, 2);
    // 2番目のフレームを途中で切る（先頭3バイトのみ）
    buf[len1] = rtcm3.PREAMBLE;
    buf[len1 + 1] = 0x00;
    buf[len1 + 2] = 0x04; // 4バイトのペイロードを宣言するが実データなし

    const scan = rtcm3.scanFrames(buf[0 .. len1 + 3]);
    try std.testing.expectEqual(@as(usize, 1), scan.count);
    // 不完全フレームは consumed に含まれない
    try std.testing.expectEqual(len1, scan.consumed);
}

// ── isRtcm3 ───────────────────────────────────────────────────────────────────

test "isRtcm3: true when 0xD3 present" {
    const data: []const u8 = &.{ 0x00, 0x00, 0xD3, 0x00 };
    try std.testing.expect(rtcm3.isRtcm3(data));
}

test "isRtcm3: false when no 0xD3" {
    const data: []const u8 = &.{ 0xB5, 0x62, 0x01, 0x02 };
    try std.testing.expect(!rtcm3.isRtcm3(data));
}

test "isRtcm3: false for empty slice" {
    try std.testing.expect(!rtcm3.isRtcm3(&.{}));
}

// ── caller 側 buffer 範囲の正しさ (upstream.zig SIGSEGV 回帰) ─────────────────
// 長時間運用 SIGSEGV の根本原因: upstream.zig が `parse_buf[pos..]` (= 8192 まで)
// を parseFrame に渡していて、stale data 上で偶然 CRC が一致すると
// `consumed > valid_len` の成功を返してしまい、後段の `pos += consumed` で
// pos > parse_len → usize underflow → SIGSEGV になっていた。
// 修正は呼び出し側で `parse_buf[pos..parse_len]` に絞ること。このテストは
// parseFrame 自身の契約 (consumed <= data.len) は保たれているが、誤った大き
// なスライスを渡すと「将来の領域」を frame の一部として解釈してしまう挙動が
// 再現することを示し、呼び出し側に注意喚起する形にする。
test "parseFrame: caller must slice to valid_len to avoid stale-byte misparse" {
    var buf: [128]u8 = .{0} ** 128;
    // 有効データ: 1 つの valid Type 1005 frame (8 bytes minimum: 0xD3 + len 2 + 2 byte payload + CRC 3 bytes)
    // ここではあえて「ペイロードを長く宣言する」frame を作り、後続のゴミバイト
    // でも CRC が一致してしまうケースを再現する。
    //
    // シナリオ: valid_len = 8 (1 frame だけ受信済)、その後ろは「次の chunk
    // で来る予定の」未到達領域。upstream の旧コードは parse_buf[pos..]
    // (= 128 まで) を渡して、長い length 値 (例: 100) の frame と誤認していた。

    // まず正しい使い方の確認: 8-byte の小さな frame
    var br = [_]u8{ 0xD3, 0x00, 0x02, 0x43, 0x50, 0, 0, 0 };
    const crc = rtcm3.crc24q(br[0..5]);
    br[5] = @truncate((crc >> 16) & 0xFF);
    br[6] = @truncate((crc >> 8) & 0xFF);
    br[7] = @truncate(crc & 0xFF);

    @memcpy(buf[0..8], &br);
    // 9 バイト目以降はゴミ (uninitialized → 0 のまま)

    // 正しい使い方: スライス長 8 を渡す → consumed=8 で OK
    const ok = rtcm3.parseFrame(buf[0..8]).?;
    try std.testing.expectEqual(@as(usize, 8), ok.consumed);

    // 危険な使い方: スライス長 128 を渡しても、valid frame は最初の 8 bytes
    // で完結するので consumed=8 が返るべき。これは parseFrame の責任ではなく、
    // 呼び出し側が valid_len を超えるバイトを渡してはいけないという契約。
    const big = rtcm3.parseFrame(buf[0..]).?;
    try std.testing.expectEqual(@as(usize, 8), big.consumed);
    // (こちらは偶然問題なし。ただし、後続バイトが PREAMBLE + 長い length
    //  + 偶然一致 CRC を持っていたら parseFrame は「成功」を返し、呼び出し側
    //  の pos が valid_len を超える危険がある。この危険は呼び出し側で
    //  parse_buf[pos..parse_len] にスライスを絞ることで除去する。)
}
