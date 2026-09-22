//! os.zig — backend-swappable OS-service layer (threads / sync / sleep).
//!
//! Sibling of io.zig. Where io.zig abstracts the *socket* surface
//! (Stream / Address), this abstracts the *runtime* surface that the caster
//! leans on: mutexes, an rwlock, a reset-event, thread spawn/join/detach, and
//! sleep. On the host these are 1:1 aliases of `std.Thread.*` (zero behavior
//! change — the posix build is byte-for-byte the same). On ESP-IDF (Tab5) the
//! `std.Thread` machinery collapses to `void` (riscv32-freestanding has no
//! pthread), so the lwip build routes every primitive to os_lwip.zig, which
//! backs them with FreeRTOS (semaphores / xTaskCreate / vTaskDelay).
//!
//! Backend is chosen by the same `-Dio-backend` option io.zig reads, so a
//! single flag flips both the socket and runtime layers together.
//!
//! API surface (kept minimal — exactly what the caster uses):
//!   Mutex       .lock() .unlock()
//!   RwLock      .lock() .unlock() .lockShared() .unlockShared()
//!   ResetEvent  .set()  .wait()   .reset()
//!   Thread      .spawn(cfg, fn, args) → Thread  |  .join() .detach()
//!   sleep(ns)

const std = @import("std");
const build_options = @import("build_options");

/// true when building the ESP-IDF / FreeRTOS backend.
pub const use_lwip = build_options.io_backend == .lwip;

/// FreeRTOS-backed implementations. Behind a comptime-false branch on the host
/// so os_lwip.zig (FreeRTOS header deps) is never parsed by the posix build —
/// same guarding pattern as io.zig ↔ io_lwip.zig.
const lwip = if (use_lwip) @import("os_lwip.zig") else struct {};

// ── std.Io runtime (posix backend) ───────────────────────────────────────────
// Zig 0.16 で同期 (Mutex/RwLock) と sleep は std.Io interface に統一され、
// io ハンドルの受け渡しが必須になった。ハンドラ全段に `io: std.Io` を貫通させる
// 代わりに、posix backend では単一の std.Io.Threaded シングルトンをここに置き、
// os.Mutex 等のラッパが内部で参照する。これで既存の `.lock()/.unlock()` 呼び
// 出し (io 引数なし) を全 call site 無改変で維持できる。
//
// Threaded.init の allocator は async/concurrent (VTable.async 等) でしか使われ
// ない。本 caster は Io.async を一切使わない (thread-per-connection のみ) ため
// `.failing` allocator で init してよい — メモリ確保は発生しない。
// posix build 専用の runtime state。comptime 分岐に置くことで lwip
// (riscv32-freestanding) build では std.Io.Threaded 型が一切参照されない
// (freestanding に pthread/signal が無く Threaded は成立しないため)。
const Runtime = if (use_lwip) struct {} else struct {
    var threaded: std.Io.Threaded = undefined;
    var io_val: ?std.Io = null;
};

/// posix runtime を初期化する。main の最初に呼ぶ。スレッド生成前 (single-thread)
/// に呼ばれる前提なので内部にロックは持たない。lwip backend では no-op。
pub fn initRuntime() void {
    if (use_lwip) return;
    Runtime.threaded = std.Io.Threaded.init(.failing, .{});
    Runtime.io_val = Runtime.threaded.io();
}

/// グローバル std.Io ハンドル。initRuntime 未呼び出しでも安全なよう遅延初期化
/// (static-init 中の log ロック等がスレッド生成前に触るケースを吸収する)。
pub fn rt() std.Io {
    return Runtime.io_val orelse {
        Runtime.threaded = std.Io.Threaded.init(.failing, .{});
        Runtime.io_val = Runtime.threaded.io();
        return Runtime.io_val.?;
    };
}

/// Mutual exclusion. Value type, default-initialised with `= .{}` at every call
/// site (no explicit init/deinit), so the lwip impl must honour that too. posix:
/// std.Io.Mutex を包み、lock/unlock 内でグローバル io を供給する。
pub const Mutex = if (use_lwip) lwip.Mutex else PosixMutex;

const PosixMutex = struct {
    inner: std.Io.Mutex = .init,
    pub fn lock(self: *PosixMutex) void {
        self.inner.lockUncancelable(rt());
    }
    pub fn unlock(self: *PosixMutex) void {
        self.inner.unlock(rt());
    }
};

/// Reader/writer lock (relay ring buffer: many readers, one writer).
pub const RwLock = if (use_lwip) lwip.RwLock else PosixRwLock;

const PosixRwLock = struct {
    inner: std.Io.RwLock = .init,
    pub fn lock(self: *PosixRwLock) void {
        self.inner.lockUncancelable(rt());
    }
    pub fn unlock(self: *PosixRwLock) void {
        self.inner.unlock(rt());
    }
    pub fn lockShared(self: *PosixRwLock) void {
        self.inner.lockSharedUncancelable(rt());
    }
    pub fn unlockShared(self: *PosixRwLock) void {
        self.inner.unlockShared(rt());
    }
};

/// One-shot "server started / condition reached" signal (server + admin listen).
/// 0.16 で std.Thread.ResetEvent が撤去されたため posix でも自前実装。現状
/// waiter は無く set() のみ呼ばれる (listen 準備完了の記録) が、将来の wait() に
/// 備え atomic フラグ + io sleep スピンで一応の待機も提供する。
pub const ResetEvent = if (use_lwip) lwip.ResetEvent else PosixResetEvent;

const PosixResetEvent = struct {
    is_set: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pub fn set(self: *PosixResetEvent) void {
        self.is_set.store(true, .release);
    }
    pub fn reset(self: *PosixResetEvent) void {
        self.is_set.store(false, .release);
    }
    pub fn isSet(self: *PosixResetEvent) bool {
        return self.is_set.load(.acquire);
    }
    pub fn wait(self: *PosixResetEvent) void {
        while (!self.isSet()) sleep(1_000_000); // 1ms poll (startup barrier のみ)
    }
    /// timeout_ns 以内に set されなければ error.Timeout。旧 std.Thread.ResetEvent
    /// との互換用 (現状 test の listen 待ちでのみ使用)。
    pub fn timedWait(self: *PosixResetEvent, timeout_ns: u64) error{Timeout}!void {
        const deadline = milliTimestamp() + @as(i64, @intCast(timeout_ns / 1_000_000));
        while (!self.isSet()) {
            if (milliTimestamp() >= deadline) return error.Timeout;
            sleep(1_000_000); // 1ms poll
        }
    }
};

/// Thread handle. Posix: std.Thread (spawn/join/detach as-is). lwip: a thin
/// FreeRTOS task wrapper exposing the same three methods.
pub const Thread = if (use_lwip) lwip.Thread else std.Thread;

/// Stack for a per-connection handler task. On lwip the handler holds two 4 KiB
/// buffers (server.handleConnection's header_buf + clientLoop's chunk buf) live
/// at once, plus the std.fmt / lwip-send call chain — 16 KiB overflows (observed
/// as a stack-protection fault on real inbound connections), 32 KiB gives room.
/// On posix, keep std.Thread's large default: 32 KiB would overflow a glibc
/// thread (this size is in bytes for both backends).
pub const conn_stack_size: usize = if (use_lwip) 32 * 1024 else 16 * 1024 * 1024;

/// Sleep the current thread/task for `ns` nanoseconds. lwip rounds up to whole
/// FreeRTOS ticks (vTaskDelay); sub-tick sleeps become a single-tick yield.
pub fn sleep(ns: u64) void {
    if (use_lwip) return lwip.sleep(ns);
    // .awake = CLOCK_MONOTONIC 相当 (相対 sleep 用)。
    std.Io.sleep(rt(), .fromNanoseconds(@intCast(ns)), .awake) catch {};
}

/// Write a log line to the console. Posix writes to stderr. lwip hands the bytes
/// to the firmware (extern `caster_console_write` → ESP-IDF UART/USB-Serial-JTAG),
/// because riscv32-freestanding has no stderr / std.fs. Used by log.zig and the
/// `std.log` override so neither path pulls std.debug's stderr writer (which
/// drags in a pthread mutex that is `void` on freestanding).
pub fn consoleWrite(bytes: []const u8) void {
    if (use_lwip) return lwip.consoleWrite(bytes);
    // 0.16: std.posix.write は撤去、書き込みは std.Io.File の Writer 経由。
    // writerStreaming (逐次 write) を使う。既定の .writer() は positional (pwrite)
    // で、stderr がリダイレクトされ seekable な場合に毎回 offset 0 へ書いて上書き
    // してしまう。小バッファに載せて即 flush (呼び出しは 1 ログ行単位)。
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stderr().writerStreaming(rt(), &buf);
    fw.interface.writeAll(bytes) catch return;
    fw.interface.flush() catch return;
}

/// Milliseconds since an arbitrary epoch. Posix: wall-clock (std.time). lwip:
/// microseconds-since-boot / 1000 (esp_timer, monotonic) — the caster only
/// takes differences (idle timeouts, uptime), so a boot epoch is fine.
pub fn milliTimestamp() i64 {
    if (use_lwip) return lwip.milliTimestamp();
    // 0.16: std.time.milliTimestamp は撤去。std.Io の .real クロックから読む。
    return std.Io.Timestamp.now(rt(), .real).toMilliseconds();
}

/// Seconds since an arbitrary epoch (log line stamps). Same epoch caveat.
pub fn timestamp() i64 {
    if (use_lwip) return lwip.timestamp();
    return std.Io.Timestamp.now(rt(), .real).toSeconds();
}
