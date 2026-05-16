//! main.zig — NtripCaster 0.2.0 (Zig リライト) エントリポイント
//!
//! 使用例:
//!   ntripcaster -c /etc/ntripcaster/ntripcaster.conf

const std = @import("std");
const parser = @import("config/parser.zig");
const server_mod = @import("server.zig");
const admin_server = @import("admin/server.zig");
const fkp_runtime = @import("fkp/runtime.zig");
const fkp_vrs = @import("fkp/vrs.zig");

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

    // 設定文字列用 Arena（長寿命: サーバー終了まで保持）
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
        1024 * 1024,
    ) catch |err| {
        std.debug.print("Error: cannot read config file '{s}': {}\n", .{ config_path, err });
        std.process.exit(1);
    };

    var config = parser.parse(config_arena.allocator(), file_content) catch |err| {
        std.debug.print("Error: failed to parse '{s}': {}\n", .{ config_path, err });
        std.process.exit(1);
    };
    defer config.deinit();

    // conf_dir: 設定ファイルのディレクトリ（sourcetable.dat の場所）
    const conf_dir = std.fs.path.dirname(config_path) orelse "conf";

    // ── ServerState 初期化 ──────────────────────────────────────────────────
    var state = server_mod.ServerState.init(allocator, &config, conf_dir);
    defer state.deinit();

    const started_at_ms = std.time.milliTimestamp();

    // ── 起動バナー ──────────────────────────────────────────────────────────
    state.logger.info(
        "NtripCaster 0.2.0 (Zig) | server={s} port={d} max_clients={d} mounts={d}",
        .{
            config.server_name,
            config.port,
            config.max_clients,
            config.mounts.count(),
        },
    );

    // ── admin リスナー（バックグラウンドスレッド） ──────────────────────────
    var admin = admin_server.AdminState{
        .state = &state,
        .bind = config.admin_bind,
        .port = config.admin_port,
        .user = config.admin_user,
        .password = config.admin_password,
        .server_started_at_ms = started_at_ms,
        .alloc = allocator,
    };
    var admin_thread: ?std.Thread = null;
    if (config.admin_enable) {
        admin_thread = std.Thread.spawn(.{}, admin_server.listen, .{&admin}) catch |err| blk: {
            state.logger.err("admin spawn failed: {}", .{err});
            break :blk null;
        };
    }
    defer {
        admin.shutdown();
        if (admin_thread) |t| t.join();
    }

    // ── FKP runtime ────────────────────────────────────────────────────────
    // fkp_enable=true かつ 3 局以上の fkp_source、かつ fkp_mountpoint が
    // 指定されている場合に仮想 mountpoint を立ち上げる。条件未達なら警告
    // ログだけ出して通常 caster として動作。
    var fkp_rt: ?*fkp_runtime.Runtime = null;
    if (config.fkp_enable and config.fkp_sources.len >= 3 and config.fkp_mountpoint.len > 0) {
        fkp_rt = fkp_runtime.Runtime.create(allocator, &state) catch |err| blk: {
            state.logger.err("fkp runtime create failed: {}", .{err});
            break :blk null;
        };
        if (fkp_rt) |rt| {
            rt.start() catch |err| {
                state.logger.err("fkp runtime start failed: {}", .{err});
                rt.shutdown();
                rt.destroy();
                fkp_rt = null;
            };
        }
    } else if (config.fkp_enable) {
        state.logger.warn(
            "fkp_enable=true but fkp_sources={d} (need >=3) or fkp_mountpoint empty; FKP inactive",
            .{config.fkp_sources.len},
        );
    }
    defer if (fkp_rt) |rt| {
        rt.shutdown();
        rt.destroy();
    };

    // ── VRS runtime ────────────────────────────────────────────────────────
    // vrs_enable=true かつ vrs_mountpoint が指定されているとき、VRS rover を
    // 受け入れる dispatch を立てる。FKP runtime が動いていることが前提
    // (主上流 RTCM3 ストリームを使うので)。
    var vrs_rt: ?*fkp_vrs.Runtime = null;
    if (config.vrs_enable and config.vrs_mountpoint.len > 0) {
        if (fkp_rt == null) {
            state.logger.warn("vrs_enable=true but FKP runtime is not active; VRS disabled", .{});
        } else {
            vrs_rt = fkp_vrs.Runtime.create(allocator, &state) catch |err| blk: {
                state.logger.err("vrs runtime create failed: {}", .{err});
                break :blk null;
            };
            if (vrs_rt) |rt| {
                state.vrs = rt.handler();
            }
        }
    }
    defer if (vrs_rt) |rt| rt.destroy();

    // ── サーバー起動（SIGINT/SIGTERM で終了） ───────────────────────────────
    server_mod.listen(&state) catch |err| {
        state.logger.err("server error: {}", .{err});
        std.process.exit(1);
    };

    state.logger.info("NtripCaster stopped.", .{});
}
