//! relay/engine.zig — RTCMリレーエンジン（リングバッファ）
//!
//! 原典 source.c の add_chunk() / source_write_to_client() を Zig で再設計。
//!
//! 設計変更点（C版からの改善）:
//!   - CHUNK_SIZE: 1000 → 4096 (RTCM3最大フレーム長に合わせる)
//!   - clients_left カウンタ廃止: クライアントが自身の read_pos を管理
//!   - スレッドセーフ: Mutex で writeChunk/readChunk を保護

const std = @import("std");

/// RTCMデータのリングバッファ。ソース→クライアントへの透過転送に使用。
///
/// クライアントは `currentWritePos()` で初期 read_pos を取得し、
/// `readChunk(read_pos, buf)` で順次データを読み取る。
pub const RingBuffer = struct {
    pub const CHUNK_SIZE: usize = 4096;
    pub const NUM_CHUNKS: usize = 64;

    chunks: [NUM_CHUNKS][CHUNK_SIZE]u8 = undefined,
    lengths: [NUM_CHUNKS]usize = [1]usize{0} ** NUM_CHUNKS,
    write_pos: usize = 0,
    mutex: std.Thread.Mutex = .{},

    /// ソースからのデータをリングバッファに格納する。
    ///
    /// `data` が CHUNK_SIZE を超える場合は先頭 CHUNK_SIZE バイトのみ格納する。
    /// 古いデータを無条件に上書きする（遅延クライアントはオーバーランエラーを受け取る）。
    pub fn writeChunk(self: *RingBuffer, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pos = self.write_pos % NUM_CHUNKS;
        const len = @min(data.len, CHUNK_SIZE);
        @memcpy(self.chunks[pos][0..len], data[0..len]);
        self.lengths[pos] = len;
        self.write_pos +%= 1;
    }

    pub const ReadError = error{
        /// クライアントが遅延しすぎてデータが上書きされた
        BufferOverrun,
    };

    pub const ReadResult = struct {
        /// コピーしたバイト数
        len: usize,
        /// 次回の readChunk に渡す read_pos
        next_pos: usize,
    };

    /// クライアントの `read_pos` 位置のチャンクを `buf` にコピーする。
    ///
    /// 戻り値:
    ///   - null              … まだデータなし (write_pos == read_pos)
    ///   - ReadResult        … コピー成功。next_pos を次回の read_pos として使う
    ///   - error.BufferOverrun … 遅延しすぎてデータが上書きされている
    pub fn readChunk(self: *RingBuffer, read_pos: usize, buf: []u8) ReadError!?ReadResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const write_pos = self.write_pos;

        // データなし
        if (read_pos == write_pos) return null;

        // オーバーラン検出: write_pos が read_pos を NUM_CHUNKS より多く追い越している
        if (write_pos -% read_pos > NUM_CHUNKS) return error.BufferOverrun;

        const pos = read_pos % NUM_CHUNKS;
        const chunk_len = self.lengths[pos];
        const copy_len = @min(chunk_len, buf.len);
        @memcpy(buf[0..copy_len], self.chunks[pos][0..copy_len]);

        return .{
            .len = copy_len,
            .next_pos = read_pos +% 1,
        };
    }

    /// クライアントが接続した時点の write_pos を返す（初期 read_pos として使う）。
    pub fn currentWritePos(self: *RingBuffer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.write_pos;
    }
};
