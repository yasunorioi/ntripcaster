//! embedded.zig — C-ABI entry points for the ESP-IDF (M5Stack Tab5) firmware.
//!
//! The `main/` C firmware calls `caster_start()` once the netif is up and the
//! USB CDC-ACM source is feeding `rtcm_sink`. This file is the bridge between
//! the firmware and the Zig caster:
//!
//!   - builds a `ServerState` from a compiled-in default config,
//!   - registers the locally-wired Mosaic base as a Source and feeds
//!     `source.runLocalSource` from the firmware's `rtcm_sink_read()`,
//!   - runs `server.listen` so rovers can pull the mount over TCP (lwip).
//!
//! Compiled into the embedded static library (`zig build caster-lib`). Its
//! `export fn`s are link roots, so building the lib force-analyses the whole
//! caster code path for the target — this is what turns "it compiles on host"
//! into "it cross-compiles for esp32p4".

const std = @import("std");
const builtin = @import("builtin");
const os = @import("os.zig");
const parser = @import("config/parser.zig");
const server = @import("server.zig");
const source = @import("ntrip/source.zig");

// ── firmware seam (main/rtcm_sink.h) ─────────────────────────────────────────
// Consumer side of the caster tee. The firmware's drain task reads the primary
// sink, feeds the monitor, then pushes the same bytes into a second StreamBuffer
// that we drain here (a StreamBuffer allows only one reader, so the monitor and
// the caster cannot share one). Blocks up to `timeout` ticks for >=1 byte, then
// returns up to `max_len`. TickType_t is uint32 on ESP-IDF.
extern fn rtcm_caster_read(out: [*]u8, max_len: usize, timeout: u32) usize;

/// Mount point the locally-wired Mosaic base is published under. Rovers pull
/// `GET /MOSAIC`. Kept short + uppercase to match sourcetable convention.
const LOCAL_MOUNT = "/MOSAIC";

/// FreeRTOS ticks to block per `rtcm_sink_read`. At 100 Hz tick (default) this
/// is ~200 ms — long enough to avoid busy-spinning, short enough that a
/// shutdown (src.active=false) is noticed promptly.
const SINK_READ_TIMEOUT_TICKS: u32 = 20;

// ── allocator ────────────────────────────────────────────────────────────────
// The caster allocates client/source structs and per-connection buffers off
// this. ESP-IDF routes malloc to PSRAM (32 MB on the Tab5), so the C allocator
// is the natural backend once libc is linked by the IDF build. Kept module-level
// so the ServerState (which outlives caster_start) has a stable allocator.
const allocator = std.heap.c_allocator;

// Long-lived state. caster_start spawns detached worker threads that borrow
// these for the process lifetime, so they must not live on caster_start's stack.
var g_config: parser.Config = undefined;
var g_state: server.ServerState = undefined;
var g_started: bool = false;

// Override std.log so direct `std.log.*` calls (config/parser.zig, and our own
// below) don't reach std.debug's stderr writer — on riscv32-freestanding that
// path pulls a pthread mutex + std.fs, both `void`. On the host this delegates
// to the default logger so behaviour is unchanged.
pub const std_options: std.Options = .{
    .logFn = casterLog,
};

fn casterLog(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!os.use_lwip) return std.log.defaultLog(level, scope, fmt, args);
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[" ++ comptime level.asText() ++ "] " ++ fmt ++ "\n", args) catch return;
    os.consoleWrite(line);
}

/// ByteReader glue: adapt the firmware's blocking `rtcm_sink_read` to the
/// caster's `source.ByteReader` contract (>0 bytes, 0 = none yet, <0 = fatal).
fn sinkRead(ctx: *anyopaque, buf: []u8) isize {
    _ = ctx;
    const n = rtcm_caster_read(buf.ptr, buf.len, SINK_READ_TIMEOUT_TICKS);
    // rtcm_caster_read only returns 0 (timeout) or a positive count; it never
    // signals a permanent error, so the feeder loop runs until src.active flips.
    return @intCast(n);
}

/// Worker: pull RTCM3 from the USB sink and publish it as the /MOSAIC source.
/// Blocks inside runLocalSource until the source is torn down.
fn localSourceWorker() void {
    const reader = source.ByteReader{ .ctx = undefined, .read_fn = &sinkRead };
    source.runLocalSource(&g_state, LOCAL_MOUNT, reader) catch |err| {
        g_state.logger.err("local source ended: {}", .{err});
    };
}

// ── C-ABI entry points (called from main/app_main.c) ─────────────────────────

/// Start the caster. Call once, after the netif is up and rtcm_sink is fed.
/// Returns 0 on success, negative on failure. Non-blocking.
///
/// All the real work (config parse, ServerState.init, feeder spawn, listen)
/// happens in a dedicated `casterMain` task, NOT in the caller's context — the
/// caller is typically the console REPL task whose ~4 KiB stack overflows if we
/// parse + build the server state on it (observed as a stack-protection fault).
export fn caster_start() c_int {
    if (g_started) return 0;
    g_started = true;
    // 16 KiB: config parse + ServerState.init + hashmap building need real room.
    _ = os.Thread.spawn(.{ .stack_size = 16 * 1024 }, casterMain, .{}) catch {
        g_started = false;
        return -1;
    };
    return 0;
}

/// Bootstrap task: owns the caster for the process lifetime. Parses config,
/// builds the server state, spawns the local-source feeder, then runs the TCP
/// listener loop (which blocks here until shutdown).
fn casterMain() void {
    g_config = parser.parse(allocator, "") catch |err| {
        std.log.err("caster: config parse failed: {}", .{err});
        return;
    };
    g_state = server.ServerState.init(allocator, &g_config, "");

    // Feeder task: USB sink → /MOSAIC source.
    _ = os.Thread.spawn(.{}, localSourceWorker, .{}) catch |err| {
        g_state.logger.err("caster: feeder spawn failed: {}", .{err});
        g_state.deinit();
        g_config.deinit();
        return;
    };

    g_state.logger.info("caster: starting listener on :{d}", .{g_config.port});
    server.listen(&g_state) catch |err| {
        g_state.logger.err("caster: listener ended: {}", .{err});
    };
}
