//! os_lwip.zig — ESP-IDF / FreeRTOS backend for os.zig (threads / sync / sleep).
//!
//! Compiled ONLY when `-Dio-backend=lwip` (os.zig imports it behind a
//! comptime-false branch otherwise, so the host/posix build never parses it).
//!
//! This file does NOT @cImport freertos/*.h. Zig 0.16's translate-c cannot
//! resolve ESP-IDF newlib's `#include_next <sys/reent.h>` layering (it does not
//! continue an #include_next across -isystem dirs, though `zig cc` does), so
//! translating FreeRTOS headers fails. Instead the primitives are implemented
//! in a thin C shim (components/ntripcaster/caster_os.c) compiled by the IDF
//! GCC toolchain, and declared here as `extern fn`. See caster_shim.h for the
//! ABI contract. No FreeRTOS struct layouts or constants live on this side.
//!
//! Design notes:
//!   - Mutex / ResetEvent are value types (`= .{}` at the call sites) so they
//!     lazy-create their FreeRTOS handle on first use. In this caster every
//!     lock/event is first touched single-threaded (during ServerState.init,
//!     before any task spawns), so the lazy create is not racy in practice.
//!   - RwLock degrades to a plain mutex (readers are exclusive). FreeRTOS has no
//!     native rwlock; for a 5–10 rover base kit the lost read concurrency on the
//!     relay ring is negligible and correctness is preserved.
//!   - Thread.join() uses a completion semaphore; detach() lets the task
//!     self-delete on return. Caster worker threads are process-lifetime, so a
//!     detached closure is intentionally leaked (never freed) rather than
//!     tracked.

const std = @import("std");

// ── C shim (components/ntripcaster/caster_os.c) ──────────────────────────────
// Opaque FreeRTOS handles cross as ?*anyopaque; we never inspect them.
const Opaque = ?*anyopaque;

extern fn caster_time_us() i64;
extern fn caster_sleep_ns(ns: u64) void;

extern fn caster_mutex_create() Opaque;
extern fn caster_mutex_lock(h: Opaque) void;
extern fn caster_mutex_unlock(h: Opaque) void;

extern fn caster_event_create() Opaque;
extern fn caster_event_set(h: Opaque) void;
extern fn caster_event_clear(h: Opaque) void;
extern fn caster_event_wait(h: Opaque) void;

extern fn caster_sem_binary_create() Opaque;
extern fn caster_sem_give(h: Opaque) void;
extern fn caster_sem_take_block(h: Opaque) void;
extern fn caster_sem_delete(h: Opaque) void;

extern fn caster_task_create(
    entry: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
    stack_bytes: c_uint,
    prio: c_uint,
) c_int;
extern fn caster_task_delete_self() void;

pub fn sleep(ns: u64) void {
    caster_sleep_ns(ns);
}

// ── time ─────────────────────────────────────────────────────────────────────
// caster_time_us is esp_timer (monotonic microseconds since boot). The caster
// only ever takes differences (idle timeout / uptime), so a boot-relative clock
// suffices — no wall-clock epoch needed.

pub fn milliTimestamp() i64 {
    return @divTrunc(caster_time_us(), 1000);
}

pub fn timestamp() i64 {
    return @divTrunc(caster_time_us(), 1_000_000);
}

// ── console ──────────────────────────────────────────────────────────────────
// Log output sink provided by the firmware (caster_glue.c → ESP-IDF console).
extern fn caster_console_write(ptr: [*]const u8, len: usize) void;

pub fn consoleWrite(bytes: []const u8) void {
    caster_console_write(bytes.ptr, bytes.len);
}

// ── Mutex ────────────────────────────────────────────────────────────────────

pub const Mutex = struct {
    handle: Opaque = null,

    fn ensure(self: *Mutex) Opaque {
        if (self.handle == null) self.handle = caster_mutex_create();
        return self.handle;
    }

    pub fn lock(self: *Mutex) void {
        caster_mutex_lock(self.ensure());
    }

    pub fn unlock(self: *Mutex) void {
        caster_mutex_unlock(self.ensure());
    }
};

// ── RwLock (degraded to exclusive) ───────────────────────────────────────────

pub const RwLock = struct {
    m: Mutex = .{},

    pub fn lock(self: *RwLock) void {
        self.m.lock();
    }
    pub fn unlock(self: *RwLock) void {
        self.m.unlock();
    }
    pub fn lockShared(self: *RwLock) void {
        self.m.lock();
    }
    pub fn unlockShared(self: *RwLock) void {
        self.m.unlock();
    }
};

// ── ResetEvent ───────────────────────────────────────────────────────────────

pub const ResetEvent = struct {
    group: Opaque = null,

    fn ensure(self: *ResetEvent) Opaque {
        if (self.group == null) self.group = caster_event_create();
        return self.group;
    }

    pub fn set(self: *ResetEvent) void {
        caster_event_set(self.ensure());
    }

    pub fn reset(self: *ResetEvent) void {
        caster_event_clear(self.ensure());
    }

    pub fn wait(self: *ResetEvent) void {
        caster_event_wait(self.ensure());
    }
};

// ── Thread ───────────────────────────────────────────────────────────────────

pub const SpawnConfig = struct {
    /// FreeRTOS task stack in BYTES (ESP-IDF xTaskCreate semantics). The caster
    /// was written for desktop (MiB thread stacks); several hot paths put a
    /// 4 KiB buffer on the stack (runLocalSource's CHUNK_SIZE buf,
    /// handleConnection's header_buf), so 8 KiB overflows on FreeRTOS. 16 KiB
    /// gives those a comfortable margin.
    stack_size: usize = 16 * 1024,
};

pub const Thread = struct {
    done: Opaque = null,

    pub const SpawnError = error{SpawnFailed};

    pub fn spawn(cfg: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Thread {
        const Args = @TypeOf(args);
        const Closure = struct {
            args: Args,
            done: Opaque,

            fn entry(ctx: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                @call(.auto, f, self.args);
                caster_sem_give(self.done);
                caster_task_delete_self();
            }
        };

        // Completion semaphore. join() takes it; detach() leaves it (leaked with
        // the closure, which is fine for process-lifetime caster tasks).
        const done = caster_sem_binary_create();
        if (done == null) return error.SpawnFailed;

        // Heap-box the closure (task outlives this frame).
        const closure = std.heap.c_allocator.create(Closure) catch {
            caster_sem_delete(done);
            return error.SpawnFailed;
        };
        closure.* = .{ .args = args, .done = done };

        // priority 5: above IDLE, below the USB host task.
        const ok = caster_task_create(&Closure.entry, closure, @intCast(cfg.stack_size), 5);
        if (ok != 0) {
            std.heap.c_allocator.destroy(closure);
            caster_sem_delete(done);
            return error.SpawnFailed;
        }
        return .{ .done = done };
    }

    pub fn join(self: Thread) void {
        if (self.done != null) {
            caster_sem_take_block(self.done);
        }
    }

    pub fn detach(self: Thread) void {
        _ = self; // task self-deletes on return; nothing to reclaim here.
    }
};
