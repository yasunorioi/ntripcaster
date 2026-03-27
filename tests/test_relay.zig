//! tests/test_relay.zig — relay/engine.zig のユニットテスト
//!
//! テスト対象:
//!   - RingBuffer: 書き込み → 読み出し
//!   - RingBuffer: データなし (null 返却)
//!   - RingBuffer: 複数チャンク順次読み出し
//!   - RingBuffer: CHUNK_SIZE 超えデータの切り詰め
//!   - RingBuffer: バッファオーバーラン検出
//!   - RingBuffer: リング折り返し（NUM_CHUNKS 周回後の書き込み）
//!   - RingBuffer: 複数リーダーが独立した read_pos を管理
//!   - RingBuffer: currentWritePos

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const engine = ntripcaster.relay;

const RB = engine.RingBuffer;

// ── 基本操作 ──────────────────────────────────────────────────────────────────

test "RingBuffer: write and read single chunk" {
    var rb = RB{};

    const data = "Hello RTCM3";
    rb.writeChunk(data);

    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    const result = try rb.readChunk(0, &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, data.len), result.?.len);
    try std.testing.expectEqualSlices(u8, data, buf[0..result.?.len]);
    try std.testing.expectEqual(@as(usize, 1), result.?.next_pos);
}

test "RingBuffer: no data returns null" {
    var rb = RB{};

    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    const result = try rb.readChunk(0, &buf);
    try std.testing.expect(result == null);
}

test "RingBuffer: read after current write_pos returns null" {
    var rb = RB{};
    rb.writeChunk("data");

    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    // write_pos = 1 に対して read_pos = 1 → データなし
    const result = try rb.readChunk(1, &buf);
    try std.testing.expect(result == null);
}

// ── 複数チャンク ──────────────────────────────────────────────────────────────

test "RingBuffer: sequential reads of multiple chunks" {
    var rb = RB{};

    rb.writeChunk("chunk1");
    rb.writeChunk("chunk2");
    rb.writeChunk("chunk3");

    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    var pos: usize = 0;

    const r1 = try rb.readChunk(pos, &buf);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualSlices(u8, "chunk1", buf[0..r1.?.len]);
    pos = r1.?.next_pos;

    const r2 = try rb.readChunk(pos, &buf);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualSlices(u8, "chunk2", buf[0..r2.?.len]);
    pos = r2.?.next_pos;

    const r3 = try rb.readChunk(pos, &buf);
    try std.testing.expect(r3 != null);
    try std.testing.expectEqualSlices(u8, "chunk3", buf[0..r3.?.len]);
    pos = r3.?.next_pos;

    // 全チャンク読了後は null
    const r4 = try rb.readChunk(pos, &buf);
    try std.testing.expect(r4 == null);
}

// ── CHUNK_SIZE 切り詰め ────────────────────────────────────────────────────────

test "RingBuffer: data larger than CHUNK_SIZE is truncated" {
    var rb = RB{};

    var large: [RB.CHUNK_SIZE + 100]u8 = undefined;
    @memset(&large, 0xAB);
    rb.writeChunk(&large);

    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    const result = try rb.readChunk(0, &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(RB.CHUNK_SIZE, result.?.len);
    // 全バイトが 0xAB
    for (buf[0..result.?.len]) |b| {
        try std.testing.expectEqual(@as(u8, 0xAB), b);
    }
}

// ── バッファオーバーラン ──────────────────────────────────────────────────────

test "RingBuffer: buffer overrun returns error" {
    var rb = RB{};

    const start_pos: usize = 0;

    // NUM_CHUNKS + 1 回書き込む → slot 0 が上書きされる
    for (0..RB.NUM_CHUNKS + 1) |_| {
        rb.writeChunk("data");
    }

    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    try std.testing.expectError(
        error.BufferOverrun,
        rb.readChunk(start_pos, &buf),
    );
}

test "RingBuffer: exactly NUM_CHUNKS writes does not overrun" {
    var rb = RB{};

    for (0..RB.NUM_CHUNKS) |_| {
        rb.writeChunk("ok");
    }

    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    // read_pos=0, write_pos=NUM_CHUNKS → diff=NUM_CHUNKS → オーバーランではない
    const result = try rb.readChunk(0, &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "ok", buf[0..result.?.len]);
}

// ── リング折り返し ─────────────────────────────────────────────────────────────

test "RingBuffer: ring wraps around after NUM_CHUNKS writes" {
    var rb = RB{};

    // NUM_CHUNKS 回書き込む（slot 0..63 が埋まる）
    for (0..RB.NUM_CHUNKS) |i| {
        var d: [4]u8 = undefined;
        std.mem.writeInt(u32, &d, @intCast(i), .little);
        rb.writeChunk(&d);
    }

    // 接続した新規クライアントは write_pos=NUM_CHUNKS から開始
    const client_pos = rb.currentWritePos();
    try std.testing.expectEqual(@as(usize, RB.NUM_CHUNKS), client_pos);

    // さらに1回書く → slot 0 を上書き（wrap）
    rb.writeChunk("WRAP");

    // クライアントは read_pos=NUM_CHUNKS から "WRAP" を読める
    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    const result = try rb.readChunk(client_pos, &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "WRAP", buf[0..result.?.len]);
    try std.testing.expectEqual(RB.NUM_CHUNKS + 1, result.?.next_pos);
}

// ── 複数リーダー ──────────────────────────────────────────────────────────────

test "RingBuffer: multiple readers at independent positions" {
    var rb = RB{};

    rb.writeChunk("A");
    rb.writeChunk("B");

    var buf1: [RB.CHUNK_SIZE]u8 = undefined;
    var buf2: [RB.CHUNK_SIZE]u8 = undefined;

    // Reader 1: pos=0 → "A"
    const r1a = try rb.readChunk(0, &buf1);
    try std.testing.expect(r1a != null);
    try std.testing.expectEqualSlices(u8, "A", buf1[0..r1a.?.len]);

    // Reader 2: pos=0 → "A"（同じデータを独立して読める）
    const r2a = try rb.readChunk(0, &buf2);
    try std.testing.expect(r2a != null);
    try std.testing.expectEqualSlices(u8, "A", buf2[0..r2a.?.len]);

    // Reader 1 が進む: pos=1 → "B"
    const r1b = try rb.readChunk(r1a.?.next_pos, &buf1);
    try std.testing.expect(r1b != null);
    try std.testing.expectEqualSlices(u8, "B", buf1[0..r1b.?.len]);

    // Reader 2 はまだ pos=1 で "B" を読める
    const r2b = try rb.readChunk(r2a.?.next_pos, &buf2);
    try std.testing.expect(r2b != null);
    try std.testing.expectEqualSlices(u8, "B", buf2[0..r2b.?.len]);
}

// ── currentWritePos ───────────────────────────────────────────────────────────

test "RingBuffer: currentWritePos starts at 0" {
    var rb = RB{};
    try std.testing.expectEqual(@as(usize, 0), rb.currentWritePos());
}

test "RingBuffer: currentWritePos increments with writes" {
    var rb = RB{};
    rb.writeChunk("a");
    try std.testing.expectEqual(@as(usize, 1), rb.currentWritePos());
    rb.writeChunk("b");
    try std.testing.expectEqual(@as(usize, 2), rb.currentWritePos());
}

// ── バイナリデータ ────────────────────────────────────────────────────────────

test "RingBuffer: binary RTCM3-like data preserved" {
    var rb = RB{};

    // RTCM3 フレームヘッダー: 0xD3 + 2バイト長 + データ
    const rtcm3: []const u8 = &.{ 0xD3, 0x00, 0x04, 0x01, 0x02, 0x03, 0x04 };
    rb.writeChunk(rtcm3);

    var buf: [RB.CHUNK_SIZE]u8 = undefined;
    const result = try rb.readChunk(0, &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(rtcm3.len, result.?.len);
    try std.testing.expectEqualSlices(u8, rtcm3, buf[0..result.?.len]);
}
