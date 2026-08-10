//! os_lwip.zig — ESP-IDF / FreeRTOS backend for os.zig (threads / sync / sleep).
//!
//! Compiled ONLY when `-Dio-backend=lwip` (os.zig imports it behind a
//! comptime-false branch otherwise, so the host/posix build never parses it).
//!
//! Requires FreeRTOS headers on the include path — provided by the ESP-IDF
//! build that compiles this Zig tree as a static library. Like io_lwip.zig this
//! file is NOT verifiable with a plain host `zig build`; it is the embedded
//! (Tab5) implementation and is exercised by `idf.py build`.
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

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("freertos/semphr.h");
    @cInclude("freertos/event_groups.h");
    @cInclude("esp_timer.h");
});

/// Convert nanoseconds to whole FreeRTOS ticks, rounding up so a sub-tick sleep
/// still yields for at least one tick.
fn nsToTicks(ns: u64) c.TickType_t {
    const ns_per_tick: u64 = 1_000_000_000 / c.configTICK_RATE_HZ;
    const ticks = (ns + ns_per_tick - 1) / ns_per_tick;
    return @intCast(ticks);
}

pub fn sleep(ns: u64) void {
    const ticks = nsToTicks(ns);
    c.vTaskDelay(if (ticks == 0) 1 else ticks);
}

// ── time (std.time.{milliTimestamp,timestamp} は posix clock_gettime に依存) ──
// esp_timer は boot からの経過マイクロ秒 (monotonic)。caster は基本的に差分
// (idle timeout / uptime) しか見ないので wall-clock epoch でなくても成立する。

pub fn milliTimestamp() i64 {
    return @divTrunc(c.esp_timer_get_time(), 1000);
}

pub fn timestamp() i64 {
    return @divTrunc(c.esp_timer_get_time(), 1_000_000);
}

// ── console ──────────────────────────────────────────────────────────────────
// Log output sink provided by the firmware (main/). Maps to the ESP-IDF console
// (UART / USB-Serial-JTAG). Declared extern so this file needs no esp_log header.
extern fn caster_console_write(ptr: [*]const u8, len: usize) void;

pub fn consoleWrite(bytes: []const u8) void {
    caster_console_write(bytes.ptr, bytes.len);
}

// ── Mutex ────────────────────────────────────────────────────────────────────

pub const Mutex = struct {
    handle: c.SemaphoreHandle_t = null,

    fn ensure(self: *Mutex) c.SemaphoreHandle_t {
        if (self.handle == null) self.handle = c.xSemaphoreCreateMutex();
        return self.handle.?;
    }

    pub fn lock(self: *Mutex) void {
        _ = c.xSemaphoreTake(self.ensure(), c.portMAX_DELAY);
    }

    pub fn unlock(self: *Mutex) void {
        _ = c.xSemaphoreGive(self.ensure());
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
    group: c.EventGroupHandle_t = null,
    const BIT: c.EventBits_t = 0x1;

    fn ensure(self: *ResetEvent) c.EventGroupHandle_t {
        if (self.group == null) self.group = c.xEventGroupCreate();
        return self.group.?;
    }

    pub fn set(self: *ResetEvent) void {
        _ = c.xEventGroupSetBits(self.ensure(), BIT);
    }

    pub fn reset(self: *ResetEvent) void {
        _ = c.xEventGroupClearBits(self.ensure(), BIT);
    }

    pub fn wait(self: *ResetEvent) void {
        _ = c.xEventGroupWaitBits(self.ensure(), BIT, c.pdFALSE, c.pdTRUE, c.portMAX_DELAY);
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
    done: c.SemaphoreHandle_t = null,

    pub const SpawnError = error{SpawnFailed};

    pub fn spawn(cfg: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Thread {
        const Args = @TypeOf(args);
        const Closure = struct {
            args: Args,
            done: c.SemaphoreHandle_t,

            fn entry(ctx: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                @call(.auto, f, self.args);
                _ = c.xSemaphoreGive(self.done);
                c.vTaskDelete(null);
            }
        };

        // Completion semaphore (dynamic — the static variant's macro doesn't
        // translate cleanly). join() takes it; detach() leaves it (leaked with
        // the closure, which is fine for process-lifetime caster tasks).
        const done = c.xSemaphoreCreateBinary();
        if (done == null) return error.SpawnFailed;

        // Heap-box the closure (task outlives this frame).
        const closure = std.heap.c_allocator.create(Closure) catch {
            c.vSemaphoreDelete(done);
            return error.SpawnFailed;
        };
        closure.* = .{ .args = args, .done = done };

        var task: c.TaskHandle_t = null;
        // NOTE: ESP-IDF's xTaskCreate takes the stack depth in BYTES (it
        // deviates from vanilla FreeRTOS, where it is in StackType_t words).
        // Pass cfg.stack_size straight through — do NOT divide by the word size.
        const ok = c.xTaskCreate(
            Closure.entry,
            "caster",
            @intCast(cfg.stack_size),
            closure,
            5, // priority: above IDLE, below the USB host task
            &task,
        );
        if (ok != c.pdPASS) {
            std.heap.c_allocator.destroy(closure);
            c.vSemaphoreDelete(done);
            return error.SpawnFailed;
        }
        return .{ .done = done };
    }

    pub fn join(self: Thread) void {
        if (self.done) |sem| {
            _ = c.xSemaphoreTake(sem, c.portMAX_DELAY);
        }
    }

    pub fn detach(self: Thread) void {
        _ = self; // task self-deletes on return; nothing to reclaim here.
    }
};
