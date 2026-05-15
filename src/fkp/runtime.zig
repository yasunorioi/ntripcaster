//! src/fkp/runtime.zig — FKP オーケストレータ
//!
//! 役割:
//!   1. config.fkp_sources で指定された 3 局以上の上流 NTRIP caster に接続を維持する
//!   2. 最初の upstream (主上流) の生 RTCM3 を仮想 Source の RingBuffer にパススルー
//!   3. fkp_interval 秒ごとに全上流から phase observation スナップショットを取り、
//!      engine.computeFkp() で FKP パラメータを算出して RTCM Type59 を生成
//!   4. Type59 フレームを同じ仮想 Source に注入
//!
//! 結果として、下流クライアントは `GET /<fkp_mountpoint>` で
//!   - 主上流の RTCM3 (1005, MSM7, ephemeris 等)
//!   - 定期的に挟まる Type59 (FKP 補正)
//! を受け取る。これでネットワーク RTK サービスとして機能する。

const std = @import("std");
const parser = @import("../config/parser.zig");
const server = @import("../server.zig");
const source_mod = @import("../ntrip/source.zig");
const log_mod = @import("../log.zig");
const relay = @import("../relay/engine.zig");
const engine = @import("engine.zig");
const type59 = @import("type59.zig");
const upstream_mod = @import("upstream.zig");

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    state: *server.ServerState,
    cfg: *const parser.Config,

    /// 仮想 mountpoint (state.sources に登録済み)
    virtual_src: *server.Source,

    /// 上流接続。`upstreams[0]` が主上流 (生 RTCM3 をパススルー)。
    upstreams: []*upstream_mod.Upstream,

    /// 制御用フラグ + 周期スレッド
    active: std.atomic.Value(bool),
    thread: ?std.Thread,

    /// 主上流のパススルー callback コンテキスト (writeRawToVirtual から逆引きする)
    passthrough_ctx: PassthroughCtx,

    /// 仮想 mountpoint に書き込んだ Type59 フレーム数の累計 (ログ用)
    fkp_frames_emitted: u64,

    pub const PassthroughCtx = struct {
        runtime: *Runtime,
    };

    /// 設定検証 + 仮想 Source 登録 + 上流の起動。返り値の Runtime は
    /// `start()` でスレッドを開始しないとアイドルのまま。`destroy()` は
    /// `state.unregisterSource()` も行うので shutdown 順序に注意。
    pub fn create(
        alloc: std.mem.Allocator,
        state: *server.ServerState,
    ) !*Runtime {
        const cfg = state.config;
        if (!cfg.fkp_enable) return error.FkpDisabled;
        if (cfg.fkp_sources.len < 3) return error.NotEnoughUpstreams;
        if (cfg.fkp_mountpoint.len == 0) return error.MissingMountpoint;

        const rt = try alloc.create(Runtime);
        errdefer alloc.destroy(rt);

        // mountpoint 名は内部レジストリ的には先頭 "/" 込み (normal source も同様)。
        // 設定で "/" 抜きでも自動補完する。
        const mount_with_slash = if (cfg.fkp_mountpoint[0] == '/')
            cfg.fkp_mountpoint
        else blk: {
            const buf = try alloc.alloc(u8, cfg.fkp_mountpoint.len + 1);
            buf[0] = '/';
            @memcpy(buf[1..], cfg.fkp_mountpoint);
            break :blk buf;
        };

        // 仮想 Source を作って登録 (peer_addr はダミー 0.0.0.0:0)
        const dummy_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        const virt = try source_mod.Source.create(alloc, mount_with_slash, dummy_addr);
        errdefer virt.destroy();
        virt.rtcm_detected = true;  // 主上流の RTCM3 を流すので最初から true
        try state.registerSource(virt);
        errdefer state.unregisterSource(mount_with_slash);

        // クライアント認証用に config.mounts にもオープン登録しておく
        // (authenticateClient が config.mounts.get() しないと弾く設計のため)
        // 注: config.mounts の MountAuth 型は parser モジュール内に隠蔽されていないので、
        //     直接 put する。なぜ FKP runtime が config を mutate するか? = 設計の妥協。
        const auth_kv = parser.MountAuth{ .open = true, .users = &.{} };
        // config は *const Config として渡されているので mut にするため @constCast
        var cfg_mut: *parser.Config = @constCast(state.config);
        cfg_mut.mounts.put(mount_with_slash, auth_kv) catch {};

        // 上流クライアント生成
        const ups = try alloc.alloc(*upstream_mod.Upstream, cfg.fkp_sources.len);
        errdefer alloc.free(ups);

        var initialized: usize = 0;
        errdefer for (ups[0..initialized]) |u| u.destroy();

        for (cfg.fkp_sources, 0..) |src, i| {
            const ucfg: upstream_mod.Config = .{
                .host = src.host,
                .port = src.port,
                .mount = src.mountpoint,
                .user = src.user,
                .pass = src.password,
                .gga_lat_deg = cfg.fkp_gga_lat,
                .gga_lon_deg = cfg.fkp_gga_lon,
            };
            ups[i] = try upstream_mod.Upstream.create(alloc, ucfg, state.logger);
            initialized += 1;
        }

        rt.* = .{
            .alloc = alloc,
            .state = state,
            .cfg = cfg,
            .virtual_src = virt,
            .upstreams = ups,
            .active = std.atomic.Value(bool).init(false),
            .thread = null,
            .passthrough_ctx = .{ .runtime = rt },
            .fkp_frames_emitted = 0,
        };

        // 主上流にパススルー設定
        ups[0].setPassthrough(&rt.passthrough_ctx, primaryPassthrough);

        return rt;
    }

    /// 上流接続スレッド + FKP 計算スレッドを起動
    pub fn start(self: *Runtime) !void {
        self.active.store(true, .seq_cst);

        for (self.upstreams) |u| {
            try u.start();
        }
        self.thread = try std.Thread.spawn(.{}, fkpLoop, .{self});

        self.state.logger.info(
            "FKP runtime started: mountpoint={s} sources={d} interval={d}s",
            .{
                self.cfg.fkp_mountpoint,
                self.upstreams.len,
                self.cfg.fkp_interval,
            },
        );
    }

    /// スレッド停止通知 + join (ブロッキング)
    pub fn shutdown(self: *Runtime) void {
        self.active.store(false, .seq_cst);
        for (self.upstreams) |u| u.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // 仮想 source の active も false にしてクライアントループを終了させる
        self.virtual_src.active.store(false, .seq_cst);
    }

    pub fn destroy(self: *Runtime) void {
        // shutdown() を呼び済みであることを前提
        // 仮想 source を state から外す (virtual_src.mount は "/" 込みで保管済み)
        self.state.unregisterSource(self.virtual_src.mount);
        // 現在接続中の下流クライアントが居れば clientLoop が抜けるのを待つ
        // (source.zig handleSource() と同じパターン)
        var waited: u32 = 0;
        while (self.virtual_src.client_count.load(.seq_cst) > 0 and waited < 200) : (waited += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        self.virtual_src.destroy();

        for (self.upstreams) |u| u.destroy();
        self.alloc.free(self.upstreams);
        self.alloc.destroy(self);
    }
};

// ── パススルー callback (主上流の生 RTCM3 を仮想 Source に流す) ───────────

fn primaryPassthrough(ctx: *anyopaque, data: []const u8) void {
    const pctx: *Runtime.PassthroughCtx = @ptrCast(@alignCast(ctx));
    const rt = pctx.runtime;
    writeToVirtual(rt, data);
}

/// 仮想 Source に書き込む共通処理。RingBuffer 1 chunk == 4096 byte なので
/// 4096 を超える場合は分割する。bytes_in / last_data_at_ms も更新。
fn writeToVirtual(rt: *Runtime, data: []const u8) void {
    const chunk_size = relay.RingBuffer.CHUNK_SIZE;
    var off: usize = 0;
    while (off < data.len) {
        const end = @min(off + chunk_size, data.len);
        rt.virtual_src.ring.writeChunk(data[off..end]);
        off = end;
    }
    rt.virtual_src.msg_lock.lock();
    rt.virtual_src.bytes_in += data.len;
    rt.virtual_src.last_data_at_ms = std.time.milliTimestamp();
    rt.virtual_src.msg_lock.unlock();
}

// ── FKP 計算ループ ───────────────────────────────────────────────────────

fn fkpLoop(rt: *Runtime) void {
    // 起動直後の小さな猶予 (上流接続が立ち上がる時間)
    std.Thread.sleep(2 * std.time.ns_per_s);

    const interval_ns = @as(u64, @intCast(rt.cfg.fkp_interval)) * std.time.ns_per_s;

    while (rt.active.load(.seq_cst)) {
        runOneFkpCycle(rt);
        std.Thread.sleep(interval_ns);
    }
}

fn runOneFkpCycle(rt: *Runtime) void {
    var arena = std.heap.ArenaAllocator.init(rt.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 全上流からスナップショット取得
    var stations = std.ArrayList(engine.StationObs){};

    // 上流ごとの snapshot を一旦保持 (deinit で arena が解放)
    for (rt.upstreams) |u| {
        const snap = u.takeSnapshot(alloc) catch continue;
        if (snap.coord == null or snap.phase_list.len == 0) continue;

        // PhaseObs → SatObs に変換
        const sat_obs = engine.groupPhaseObs(alloc, snap.phase_list) catch continue;
        if (sat_obs.len == 0) continue;

        stations.append(alloc, .{
            .coord = snap.coord.?,
            .obs = sat_obs,
        }) catch return;
    }

    if (stations.items.len < 3) {
        rt.state.logger.warn(
            "[fkp] cycle skipped: only {d}/{d} stations have data",
            .{ stations.items.len, rt.upstreams.len },
        );
        return;
    }

    // FKP 計算
    const fkp_params = engine.computeFkp(alloc, stations.items) catch |err| {
        rt.state.logger.warn("[fkp] computeFkp failed: {}", .{err});
        return;
    };
    if (fkp_params.len == 0) {
        rt.state.logger.warn("[fkp] no parameters produced (singular matrix or no overlap)", .{});
        return;
    }

    // Type59 エンコード
    const tow_ms: u32 = @truncate(@as(u64, @intCast(std.time.timestamp())) % (7 * 24 * 3600) * 1000);
    const frame = type59.encodeType59(
        alloc,
        stations.items[0].coord.ref_station_id,
        tow_ms,
        fkp_params,
    ) catch |err| {
        rt.state.logger.warn("[fkp] encodeType59 failed: {}", .{err});
        return;
    };

    writeToVirtual(rt, frame);

    // Type59 を msg_types に記録 (passthrough は raw を流すだけなので、
    // 注入した Type59 のみここで明示的にカウント)
    rt.virtual_src.msg_lock.lock();
    const gop = rt.virtual_src.msg_types.getOrPut(rt.virtual_src.alloc, type59.MSG_TYPE) catch {
        rt.virtual_src.msg_lock.unlock();
        return;
    };
    if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    rt.virtual_src.msg_lock.unlock();

    rt.fkp_frames_emitted += 1;

    if (rt.fkp_frames_emitted % 30 == 0 or rt.fkp_frames_emitted == 1) {
        rt.state.logger.info(
            "[fkp] cycle ok: {d} satellites, {d} bytes, total {d} frames",
            .{ fkp_params.len, frame.len, rt.fkp_frames_emitted },
        );
    }
}
