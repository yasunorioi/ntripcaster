//! log.zig — ログ出力モジュール
//!
//! 原典 log.c の write_log() / xa_debug() を Zig で再実装。
//! ファイル + stderr 二重出力、ログレベル(info/warn/err)、タイムスタンプ付き。

const std = @import("std");

pub const Level = enum { info, warn, err };

/// タイムスタンプ付きログ出力器。
/// `Logger{}` でスタックに確保してそのまま使える（mutex embedded）。
pub const Logger = struct {
    file: ?std.fs.File = null,
    /// false にするとstderr出力を抑制する（テスト時に使用）。
    stderr: bool = true,
    mutex: std.Thread.Mutex = .{},

    /// ログレベルとメッセージを書き出す。
    pub fn log(self: *Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        const prefix = switch (level) {
            .info => "INFO",
            .warn => "WARN",
            .err  => "ERR ",
        };

        var buf: [4096]u8 = undefined;
        const ts = std.time.timestamp();

        // タイムスタンプ + レベルのヘッダーを先頭に書く
        const header_slice = std.fmt.bufPrint(&buf, "[{d}] [{s}] ", .{ ts, prefix }) catch return;
        // その後ろにメッセージを書く
        const body_slice = std.fmt.bufPrint(buf[header_slice.len..], fmt ++ "\n", args) catch return;
        const line = buf[0 .. header_slice.len + body_slice.len];

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stderr) std.fs.File.stderr().writeAll(line) catch {};
        if (self.file) |f| f.writeAll(line) catch {};
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    /// ログファイルをオープンして追記モードにする。
    pub fn openFile(self: *Logger, path: []const u8) !void {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
        errdefer f.close();
        try f.seekFromEnd(0);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.file = f;
    }

    /// ログファイルをクローズする。
    pub fn closeFile(self: *Logger) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
    }
};
