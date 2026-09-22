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

/// Mutual exclusion. Value type, default-initialised with `= .{}` at every call
/// site (no explicit init/deinit), so the lwip impl must honour that too.
pub const Mutex = if (use_lwip) lwip.Mutex else std.Thread.Mutex;

/// Reader/writer lock (relay ring buffer: many readers, one writer).
pub const RwLock = if (use_lwip) lwip.RwLock else std.Thread.RwLock;

/// One-shot "server started / condition reached" signal (server + admin listen).
pub const ResetEvent = if (use_lwip) lwip.ResetEvent else std.Thread.ResetEvent;

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
    std.Thread.sleep(ns);
}

/// Write a log line to the console. Posix writes to stderr. lwip hands the bytes
/// to the firmware (extern `caster_console_write` → ESP-IDF UART/USB-Serial-JTAG),
/// because riscv32-freestanding has no stderr / std.fs. Used by log.zig and the
/// `std.log` override so neither path pulls std.debug's stderr writer (which
/// drags in a pthread mutex that is `void` on freestanding).
pub fn consoleWrite(bytes: []const u8) void {
    if (use_lwip) return lwip.consoleWrite(bytes);
    std.fs.File.stderr().writeAll(bytes) catch {};
}

/// Milliseconds since an arbitrary epoch. Posix: wall-clock (std.time). lwip:
/// microseconds-since-boot / 1000 (esp_timer, monotonic) — the caster only
/// takes differences (idle timeouts, uptime), so a boot epoch is fine.
pub fn milliTimestamp() i64 {
    if (use_lwip) return lwip.milliTimestamp();
    return std.time.milliTimestamp();
}

/// Seconds since an arbitrary epoch (log line stamps). Same epoch caveat.
pub fn timestamp() i64 {
    if (use_lwip) return lwip.timestamp();
    return std.time.timestamp();
}
