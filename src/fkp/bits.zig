//! fkp/bits.zig — MSB-first ビット読み書きヘルパー
//! RTCM3 ペイロードはビット 0 がバイト 0 の MSB (最上位ビット)。

const std = @import("std");

/// MSB-first ビット読み出し
pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data, .pos = 0 };
    }

    /// n ビット (0–64) を unsigned として読み出す
    pub fn readU(self: *BitReader, n: u7) u64 {
        if (n == 0) return 0;
        var result: u64 = 0;
        var i: u7 = 0;
        while (i < n) : (i += 1) {
            const byte_idx = self.pos / 8;
            const bit_off: u3 = @truncate(7 - (self.pos % 8));
            const bit: u64 = if (byte_idx < self.data.len)
                (self.data[byte_idx] >> bit_off) & 1
            else
                0;
            result = (result << 1) | bit;
            self.pos += 1;
        }
        return result;
    }

    /// n ビットを 2の補数表現の signed として読み出す
    pub fn readS(self: *BitReader, n: u7) i64 {
        if (n == 0) return 0;
        const raw = self.readU(n);
        const shift: u6 = @truncate(n - 1);
        const sign_bit = @as(u64, 1) << shift;
        if (raw & sign_bit != 0) {
            // 符号拡張: 上位ビットを全て 1 にする
            const nbits: u6 = @truncate(n);
            const mask: u64 = if (n < 64) ~((@as(u64, 1) << nbits) - 1) else 0;
            return @as(i64, @bitCast(raw | mask));
        }
        return @as(i64, @intCast(raw));
    }

    /// n ビットをスキップ
    pub fn skip(self: *BitReader, n: usize) void {
        self.pos += n;
    }

    /// 現在のビット位置
    pub fn bitPos(self: *const BitReader) usize {
        return self.pos;
    }
};

/// MSB-first ビット書き込み
pub const BitWriter = struct {
    data: []u8,
    pos: usize = 0,

    pub fn init(data: []u8) BitWriter {
        return .{ .data = data, .pos = 0 };
    }

    /// n ビット (0–64) を unsigned として書き込む（上位ビットから）
    pub fn writeU(self: *BitWriter, n: u7, value: u64) void {
        if (n == 0) return;
        var i: u7 = n;
        while (i > 0) {
            i -= 1;
            const byte_idx = self.pos / 8;
            const bit_off: u3 = @truncate(7 - (self.pos % 8));
            if (byte_idx < self.data.len) {
                const shift: u6 = @truncate(i);
                const bit: u8 = @truncate((value >> shift) & 1);
                self.data[byte_idx] |= bit << bit_off;
            }
            self.pos += 1;
        }
    }

    /// n ビットを signed として書き込む（2の補数表現）
    pub fn writeS(self: *BitWriter, n: u7, value: i64) void {
        if (n == 0) return;
        const raw: u64 = @as(u64, @bitCast(value));
        // 下位 n ビットのみ使用
        const nbits: u6 = @truncate(n);
        const mask: u64 = if (n < 64) (@as(u64, 1) << nbits) - 1 else std.math.maxInt(u64);
        self.writeU(n, raw & mask);
    }
};

/// 任意 bit offset 位置に `n` bit (0..64) を書き込むスタンドアロン版。
/// 既存ビットをクリアしてから上書きするので in-place 書き換えに使える。
/// BitWriter と違い state を持たない (= ランダムアクセス書き込み用)。
pub fn writeBitsAt(data: []u8, bit_offset: usize, n: u7, value: u64) void {
    if (n == 0) return;
    var i: u7 = n;
    var pos = bit_offset;
    while (i > 0) {
        i -= 1;
        const byte_idx = pos / 8;
        const bit_off: u3 = @truncate(7 - (pos % 8));
        if (byte_idx < data.len) {
            const shift: u6 = @truncate(i);
            const bit: u8 = @truncate((value >> shift) & 1);
            data[byte_idx] = (data[byte_idx] & ~(@as(u8, 1) << bit_off)) |
                (bit << bit_off);
        }
        pos += 1;
    }
}

// ── テスト ────────────────────────────────────────────────────────────────────

test "BitReader: read 8 bits MSB first" {
    const data = [_]u8{0b10110010};
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u64, 0b10110010), br.readU(8));
}

test "BitReader: read across byte boundary" {
    const data = [_]u8{ 0xFF, 0x00 };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u64, 0xFF), br.readU(8));
    try std.testing.expectEqual(@as(u64, 0), br.readU(8));
}

test "BitReader: readS negative" {
    // 4 bit: 0b1100 = -4 in two's complement
    const data = [_]u8{0b11000000};
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(i64, -4), br.readS(4));
}

test "BitReader: readS positive" {
    // 4 bit: 0b0111 = 7
    const data = [_]u8{0b01110000};
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(i64, 7), br.readS(4));
}

test "BitWriter: write 8 bits" {
    var buf = [_]u8{0} ** 1;
    var bw = BitWriter.init(&buf);
    bw.writeU(8, 0xA5);
    try std.testing.expectEqual(@as(u8, 0xA5), buf[0]);
}

test "BitWriter: writeS negative" {
    var buf = [_]u8{0} ** 1;
    var bw = BitWriter.init(&buf);
    bw.writeS(4, -4); // 0b1100
    try std.testing.expectEqual(@as(u8, 0b11000000), buf[0]);
}

test "BitReader/BitWriter roundtrip" {
    var buf = [_]u8{0} ** 4;
    var bw = BitWriter.init(&buf);
    bw.writeU(12, 1005);
    bw.writeS(16, -1234);
    bw.writeU(4, 0b1010);

    var br = BitReader.init(&buf);
    try std.testing.expectEqual(@as(u64, 1005), br.readU(12));
    try std.testing.expectEqual(@as(i64, -1234), br.readS(16));
    try std.testing.expectEqual(@as(u64, 0b1010), br.readU(4));
}

test "writeBitsAt: overwrites existing bits" {
    var buf = [_]u8{ 0xFF, 0xFF };
    // bit offset 4 から 8 bit に 0x00 を書く → 上位 4bit=0xF / 中央 8bit=0x00 / 下位 4bit=0xF
    writeBitsAt(&buf, 4, 8, 0x00);
    try std.testing.expectEqual(@as(u8, 0xF0), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x0F), buf[1]);
}

test "writeBitsAt: roundtrip with BitReader at arbitrary offset" {
    var buf = [_]u8{0} ** 8;
    writeBitsAt(&buf, 13, 20, 0xABCDE);
    var br = BitReader.init(&buf);
    br.skip(13);
    try std.testing.expectEqual(@as(u64, 0xABCDE), br.readU(20));
}

test "writeBitsAt: 24-bit signed two's complement" {
    // -100000 を 24 bit に書いて読み戻すと同じ値になる
    var buf = [_]u8{0xFF} ** 4; // 既存値を立てておく (overwrite 検証)
    const val: i64 = -100000;
    const masked: u64 = @as(u64, @bitCast(val)) & ((@as(u64, 1) << 24) - 1);
    writeBitsAt(&buf, 0, 24, masked);
    var br = BitReader.init(&buf);
    try std.testing.expectEqual(@as(i64, -100000), br.readS(24));
}
