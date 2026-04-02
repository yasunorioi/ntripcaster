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
