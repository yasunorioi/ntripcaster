//! main.zig — NtripCaster 0.2.0 (Zig リライト) エントリポイント
//!
//! Phase 2a: 設定読み込みまで実装。サーバー起動は Phase 2c で追加。
//!
//! 使用例:
//!   ntripcaster -c /etc/ntripcaster/ntripcaster.conf

const std = @import("std");
const parser = @import("config/parser.zig");

const usage =
    \\Usage: ntripcaster [-c <configfile>] [-h]
    \\
    \\Options:
    \\  -c, --config <file>   Path to configuration file
    \\                        (default: conf/ntripcaster.conf)
    \\  -h, --help            Show this help message
    \\
    \\NtripCaster 0.2.0 — Zig rewrite of BKG Standard NtripCaster 0.1.5
    \\Zero external dependencies. Cross-compiles to x86_64/aarch64 Linux & macOS.
    \\
;

pub fn main() !void {
    // ── アロケータ初期化 ────────────────────────────────────────────────────
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 設定文字列用 Arena（長寿命）
    var config_arena = std.heap.ArenaAllocator.init(allocator);
    defer config_arena.deinit();

    // ── CLI 引数解析 ────────────────────────────────────────────────────────
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path: []const u8 = "conf/ntripcaster.conf";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: {s} requires a path argument\n\n{s}", .{ arg, usage });
                std.process.exit(1);
            }
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else {
            std.debug.print("Unknown option: {s}\n\n{s}", .{ arg, usage });
            std.process.exit(1);
        }
    }

    // ── 設定ファイル読み込み ────────────────────────────────────────────────
    const file_content = std.fs.cwd().readFileAlloc(
        config_arena.allocator(),
        config_path,
        1024 * 1024, // 最大 1 MiB
    ) catch |err| {
        std.debug.print("Error: cannot read config file '{s}': {}\n", .{ config_path, err });
        std.process.exit(1);
    };

    var config = parser.parse(config_arena.allocator(), file_content) catch |err| {
        std.debug.print("Error: failed to parse '{s}': {}\n", .{ config_path, err });
        std.process.exit(1);
    };
    defer config.deinit();

    // ── 起動バナー ──────────────────────────────────────────────────────────
    std.debug.print(
        \\NtripCaster 0.2.0 (Zig)
        \\Config file : {s}
        \\server_name : {s}
        \\port        : {d}
        \\max_clients : {d}
        \\max_sources : {d}
        \\encoder_pass: {s}
        \\logdir      : {s}
        \\mounts      : {d}
        \\
        \\(Server startup not yet implemented — Phase 2c)
        \\
    , .{
        config_path,
        config.server_name,
        config.port,
        config.max_clients,
        config.max_sources,
        config.encoder_password,
        config.logdir,
        config.mounts.count(),
    });
}
