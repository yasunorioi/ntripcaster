//! server.zig — TCP リスナー・接続振り分け・サーバー状態管理
//!
//! 原典 connection.c の handle_connection() / get_connection() を Zig で再設計。
//! 1接続1スレッドモデル（Phase 2）。Phase 3以降でio_uring非同期化予定。

const std = @import("std");
const parser = @import("config/parser.zig");
const auth = @import("auth/basic.zig");
const protocol = @import("ntrip/protocol.zig");
const relay = @import("relay/engine.zig");
const log_mod = @import("log.zig");
const sourcetable_mod = @import("ntrip/sourcetable.zig");

// ── Source 構造体 ──────────────────────────────────────────────────────────────

/// マウントポイントに接続中のソース（基準局）
pub const Source = struct {
    mount: []const u8,
    ring: relay.RingBuffer,
    /// false になるとクライアントループが終了する
    active: std.atomic.Value(bool),
    /// 現在接続中のクライアント数。destroy() はゼロになるまで待機する
    client_count: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    /// RTCM3 ストリームを検出したら true（sourceLoop が設定）
    rtcm_detected: bool,
    /// 観測済み RTCM3 メッセージタイプ → カウント（sourceLoop が更新）
    msg_types: std.AutoHashMapUnmanaged(u16, u32),
    /// msg_types へのアクセスを保護するロック
    msg_lock: std.Thread.Mutex,

    pub fn create(alloc: std.mem.Allocator, mount: []const u8) !*Source {
        const s = try alloc.create(Source);
        s.* = .{
            .mount = try alloc.dupe(u8, mount),
            .ring = .{},
            .active = std.atomic.Value(bool).init(true),
            .client_count = std.atomic.Value(u32).init(0),
            .alloc = alloc,
            .rtcm_detected = false,
            .msg_types = .{},
            .msg_lock = .{},
        };
        return s;
    }

    pub fn destroy(self: *Source) void {
        self.active.store(false, .seq_cst);
        self.msg_types.deinit(self.alloc);
        self.alloc.free(self.mount);
        self.alloc.destroy(self);
    }
};

// ── ServerState ───────────────────────────────────────────────────────────────

/// サーバー全体の状態。全スレッドが *ServerState を共有する。
pub const ServerState = struct {
    config: *parser.Config,
    sources: std.StringHashMap(*Source),
    source_lock: std.Thread.Mutex,
    alloc: std.mem.Allocator,
    logger: log_mod.Logger,
    /// sourcetable.dat を探すディレクトリ
    conf_dir: []const u8,
    /// ヒープ上の TCP リスナー（shutdown() で deinit + free する）
    listener: ?*std.net.Server,
    /// サーバーが listen() に入ったことを通知するイベント
    started_event: std.Thread.ResetEvent,
    /// 実際にバインドされたアドレス（started_event.wait() 後に読める）
    listen_address: std.net.Address,
    /// 接続中ハンドラースレッド数（deinit() 内でゼロを待機する）
    active_handlers: std.atomic.Value(u32),

    pub fn init(
        alloc: std.mem.Allocator,
        config: *parser.Config,
        conf_dir: []const u8,
    ) ServerState {
        return .{
            .config = config,
            .sources = std.StringHashMap(*Source).init(alloc),
            .source_lock = .{},
            .alloc = alloc,
            .logger = .{ .stderr = true },
            .conf_dir = conf_dir,
            .listener = null,
            .started_event = .{},
            .listen_address = undefined,
            .active_handlers = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *ServerState) void {
        self.shutdown();
        // ハンドラースレッドが全て終了するまで待機（最大2秒）
        var waited: u32 = 0;
        while (self.active_handlers.load(.seq_cst) > 0 and waited < 200) : (waited += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        self.source_lock.lock();
        defer self.source_lock.unlock();
        var it = self.sources.valueIterator();
        while (it.next()) |src| src.*.destroy();
        self.sources.deinit();
    }

    /// TCP リスナーを閉じる。accept() ループはエラーを受け取り終了する。
    ///
    /// Linux では close(fd) しても別スレッドの accept() が起床しないため、
    /// shutdown(SHUT_RDWR) を先に呼び accept() に EINVAL を返させる。
    pub fn shutdown(self: *ServerState) void {
        if (self.listener) |l| {
            // shutdown() でブロック中の accept() を起床させてから deinit()
            std.posix.shutdown(l.stream.handle, .both) catch {};
            l.deinit();
            self.alloc.destroy(l);
            self.listener = null;
        }
    }

    pub fn registerSource(self: *ServerState, src: *Source) !void {
        self.source_lock.lock();
        defer self.source_lock.unlock();
        const result = try self.sources.getOrPut(src.mount);
        if (result.found_existing) return error.MountAlreadyInUse;
        result.value_ptr.* = src;
    }

    pub fn unregisterSource(self: *ServerState, mount: []const u8) void {
        self.source_lock.lock();
        defer self.source_lock.unlock();
        _ = self.sources.remove(mount);
    }

    pub fn getSource(self: *ServerState, mount: []const u8) ?*Source {
        self.source_lock.lock();
        defer self.source_lock.unlock();
        return self.sources.get(mount);
    }

    /// 現在登録中のソース数を返す（スレッドセーフ）。
    pub fn sourceCount(self: *ServerState) u32 {
        self.source_lock.lock();
        defer self.source_lock.unlock();
        return @intCast(self.sources.count());
    }
};

// ── 接続ディスパッチ ──────────────────────────────────────────────────────────

const ConnArgs = struct {
    stream: std.net.Stream,
    state: *ServerState,
};

fn readHeader(stream: std.net.Stream, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
        if (std.mem.indexOf(u8, buf[0..total], "\n\n") != null) break;
    }
    return total;
}

fn sendBadRequest(stream: std.net.Stream) void {
    stream.writeAll("HTTP/1.0 400 Bad Request\r\n\r\n") catch {};
}

fn sendSourcetableResponse(stream: std.net.Stream, state: *ServerState) void {
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const st_path = std.fmt.allocPrint(
        alloc,
        "{s}/sourcetable.dat",
        .{state.conf_dir},
    ) catch {
        sendBadRequest(stream);
        return;
    };

    const maybe_body = sourcetable_mod.readFile(alloc, st_path) catch null;
    const body = maybe_body orelse "";

    // 接続中ソースの SourceEntry を収集（source_lock → msg_lock 順でロック）
    var entries = std.ArrayList(sourcetable_mod.SourceEntry){};
    {
        state.source_lock.lock();
        defer state.source_lock.unlock();
        var it = state.sources.valueIterator();
        while (it.next()) |src_ptr| {
            const src = src_ptr.*;
            const fmt: []const u8 = if (src.rtcm_detected) "RTCM 3.2" else "";

            // format_details: "{msg_type}({count}),..." 形式
            var details = std.ArrayList(u8){};
            {
                src.msg_lock.lock();
                defer src.msg_lock.unlock();
                var mt_it = src.msg_types.iterator();
                var first = true;
                while (mt_it.next()) |kv| {
                    if (!first) details.append(alloc, ',') catch {};
                    first = false;
                    const part = std.fmt.allocPrint(
                        alloc,
                        "{d}({d})",
                        .{ kv.key_ptr.*, kv.value_ptr.* },
                    ) catch continue;
                    details.appendSlice(alloc, part) catch {};
                }
            }

            entries.append(alloc, .{
                .mount = src.mount,
                .format = fmt,
                .format_details = details.items,
            }) catch {};
        }
    }

    const resp = sourcetable_mod.buildResponse(
        alloc,
        body,
        state.config.server_name,
        entries.items,
    ) catch {
        sendBadRequest(stream);
        return;
    };

    stream.writeAll(resp) catch {};
}

fn handleConnection(args: ConnArgs) void {
    _ = args.state.active_handlers.fetchAdd(1, .seq_cst);
    defer _ = args.state.active_handlers.fetchSub(1, .seq_cst);
    defer args.stream.close();

    // 接続数上限チェック
    if (args.state.active_handlers.load(.seq_cst) > args.state.config.max_clients) {
        args.stream.writeAll("ERROR - Too Many Clients\r\n") catch {};
        args.state.logger.warn("connection rejected: max_clients ({d}) exceeded", .{args.state.config.max_clients});
        return;
    }

    const source_mod = @import("ntrip/source.zig");
    const client_mod = @import("ntrip/client.zig");

    var header_buf: [4096]u8 = undefined;
    const header_len = readHeader(args.stream, &header_buf) catch {
        sendBadRequest(args.stream);
        return;
    };
    const header = header_buf[0..header_len];

    const req = protocol.parseRequest(header);
    switch (req) {
        .source_login => |sl| source_mod.handleSource(args.stream, args.state, sl),
        .client_get => |cg| client_mod.handleClient(args.stream, args.state, cg),
        .sourcetable_get => sendSourcetableResponse(args.stream, args.state),
        .invalid => sendBadRequest(args.stream),
    }
}

// ── 公開 API ──────────────────────────────────────────────────────────────────

/// TCP リスナーを起動して接続を受け付けるメインループ。
/// state.shutdown() を呼ぶとループを抜ける。
pub fn listen(state: *ServerState) !void {
    const server_ptr = try state.alloc.create(std.net.Server);
    errdefer state.alloc.destroy(server_ptr);

    const addr = try std.net.Address.parseIp4("0.0.0.0", state.config.port);
    server_ptr.* = try addr.listen(.{ .reuse_address = true });
    state.listen_address = server_ptr.listen_address;
    state.listener = server_ptr;
    state.started_event.set(); // listen 準備完了を通知

    state.logger.info(
        "NtripCaster 0.2.0 listening on port {d}",
        .{state.config.port},
    );

    while (true) {
        const conn = server_ptr.accept() catch |err| {
            state.logger.info("accept() stopped: {}", .{err});
            break;
        };

        const args = ConnArgs{
            .stream = conn.stream,
            .state = state,
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{args}) catch |err| {
            state.logger.warn("Thread.spawn failed: {}", .{err});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}
