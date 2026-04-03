//! fkp/demo.zig — FKP計算実証クライアント（北海道3局 / rtk2go）
//!
//! 使用法: zig build fkp-demo && ./zig-out/bin/fkp-demo
//!
//! rtk2go.com:2101 の以下の3局に同時接続してFKPを計算・配信する:
//!   nakagawa00      (中川   44.80°N 142.06°E)
//!   Asahikawa-HAMA  (旭川   43.80°N 142.43°E)
//!   UEMATSUDENKI-F9P (赤平  43.58°N 142.00°E)
//!
//! Phase 4 実証フロー:
//!   1. 3局並列NTRIP接続
//!   2. MSM7 受信 → 搬送波位相抽出
//!   3. FKP 計算
//!   4. RTCM Type59 エンコード → stdout に出力
//!      (本番では ntripcaster の仮想マウントに配信)

const std = @import("std");
const ntripcaster = @import("ntripcaster");
const msm7 = ntripcaster.fkp_msm7;
const engine = ntripcaster.fkp_engine;
const type59 = ntripcaster.fkp_type59;
const rtcm3 = ntripcaster.rtcm3;

/// rtk2go北海道3局の設定
const STATIONS = [3]struct {
    mount: []const u8,
    host: []const u8,
    port: u16,
}{
    .{ .mount = "nakagawa00", .host = "rtk2go.com", .port = 2101 },
    .{ .mount = "Asahikawa-HAMA", .host = "rtk2go.com", .port = 2101 },
    .{ .mount = "UEMATSUDENKI-F9P", .host = "rtk2go.com", .port = 2101 },
};

/// NTRIP GET リクエスト送信
fn sendNtripGet(stream: std.net.Stream, mount: []const u8, host: []const u8, port: u16) !void {
    // Basic認証: rtk2go は user:password 形式（任意メール:none）
    const auth_str = "test@example.com:none";
    var auth_b64: [64]u8 = undefined;
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(auth_str.len);
    _ = encoder.encode(auth_b64[0..encoded_len], auth_str);

    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf,
        "GET /{s} HTTP/1.0\r\n" ++
        "Host: {s}:{d}\r\n" ++
        "Ntrip-Version: Ntrip/1.0\r\n" ++
        "User-Agent: NTRIP NtripFkpDemo/0.1\r\n" ++
        "Authorization: Basic {s}\r\n" ++
        "\r\n",
        .{ mount, host, port, auth_b64[0..encoded_len] },
    );
    try stream.writeAll(req);
}

/// NTRIP ICY 200 OK レスポンスを受信して確認する
fn waitIcy(stream: std.net.Stream) !void {
    var buf: [256]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "ICY 200 OK") != null) return;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }
    return error.NotIcy200;
}

/// 1局から MSM7 データを受信してPhaseObsを収集する
/// timeout_ms 分だけ受信してから返す
const CollectResult = struct {
    coord: ?msm7.StationCoord,
    phase_list: []msm7.PhaseObs,
};

fn collectStation(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    timeout_ms: u64,
) !CollectResult {
    var buf: [8192]u8 = undefined;
    var parse_buf: [8192]u8 = undefined;
    var parse_len: usize = 0;

    var coord: ?msm7.StationCoord = null;
    var all_obs = std.ArrayList(msm7.PhaseObs){};

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() < deadline) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;

        // parse_buf に追記
        const chunk = buf[0..n];
        if (parse_len + chunk.len <= parse_buf.len) {
            @memcpy(parse_buf[parse_len .. parse_len + chunk.len], chunk);
            parse_len += chunk.len;
        } else {
            const copy_len = @min(chunk.len, parse_buf.len);
            @memcpy(parse_buf[0..copy_len], chunk[chunk.len - copy_len ..]);
            parse_len = copy_len;
        }

        // RTCM3 フレームスキャン
        var pos: usize = 0;
        while (pos < parse_len) {
            if (parse_buf[pos] != rtcm3.PREAMBLE) {
                pos += 1;
                continue;
            }
            const frame_result = rtcm3.parseFrame(parse_buf[pos..]) orelse {
                if (parse_len - pos < 6) break;
                pos += 1;
                continue;
            };

            const payload = parse_buf[pos + 3 .. pos + frame_result.consumed - 3];
            switch (frame_result.msg_type) {
                1005, 1006 => {
                    if (coord == null) {
                        coord = msm7.parseMsg1005(parse_buf[pos + 3 .. pos + frame_result.consumed - 3]);
                    }
                    _ = payload;
                },
                1077, 1087, 1097 => {
                    const obs = msm7.extractPhase(allocator, parse_buf[pos + 3 .. pos + frame_result.consumed - 3]) catch &.{};
                    for (obs) |o| {
                        all_obs.append(allocator, o) catch {};
                    }
                    allocator.free(obs);
                },
                else => {},
            }
            pos += frame_result.consumed;
        }

        // 消費済みシフト
        const remaining = parse_len - pos;
        if (remaining > 0 and pos > 0) {
            std.mem.copyForwards(u8, parse_buf[0..remaining], parse_buf[pos..parse_len]);
        }
        parse_len = remaining;
    }

    return .{
        .coord = coord,
        .phase_list = try all_obs.toOwnedSlice(allocator),
    };
}

/// スレッド引数
const ThreadArg = struct {
    allocator: std.mem.Allocator,
    mount: []const u8,
    host: []const u8,
    port: u16,
    result: ?CollectResult = null,
    err: bool = false,
};

fn stationThread(arg: *ThreadArg) void {
    const stream = std.net.tcpConnectToHost(arg.allocator, arg.host, arg.port) catch {
        arg.err = true;
        return;
    };
    defer stream.close();

    sendNtripGet(stream, arg.mount, arg.host, arg.port) catch {
        arg.err = true;
        return;
    };
    waitIcy(stream) catch {
        arg.err = true;
        return;
    };

    arg.result = collectStation(arg.allocator, stream, 10000) catch {
        arg.err = true;
        return;
    };
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stderr().writeAll(msg) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log("FKP Demo: 北海道3局 rtk2go 実証\n", .{});
    log("接続先: {s}:{d}\n", .{ STATIONS[0].host, STATIONS[0].port });

    // 3スレッド並列接続
    var args: [3]ThreadArg = undefined;
    var threads: [3]std.Thread = undefined;

    for (0..3) |i| {
        args[i] = .{
            .allocator = allocator,
            .mount = STATIONS[i].mount,
            .host = STATIONS[i].host,
            .port = STATIONS[i].port,
        };
        threads[i] = try std.Thread.spawn(.{}, stationThread, .{&args[i]});
    }

    for (0..3) |i| {
        threads[i].join();
    }

    // 結果収集
    var station_obs_list: [3]?engine.StationObs = .{ null, null, null };
    var all_sat_obs: [3]?[]engine.SatObs = .{ null, null, null };
    defer for (all_sat_obs) |s| if (s) |sl| allocator.free(sl);

    var valid_count: usize = 0;
    for (0..3) |i| {
        if (args[i].err or args[i].result == null) {
            log("[{s}] 接続失敗\n", .{STATIONS[i].mount});
            continue;
        }
        const result = args[i].result.?;
        const coord = result.coord orelse {
            log("[{s}] 座標取得失敗\n", .{STATIONS[i].mount});
            allocator.free(result.phase_list);
            continue;
        };

        const sat_obs = try engine.groupPhaseObs(allocator, result.phase_list);
        allocator.free(result.phase_list);
        all_sat_obs[i] = sat_obs;

        station_obs_list[i] = .{ .coord = coord, .obs = sat_obs };
        log("[{s}] 局座標: lat={d:.4} lon={d:.4} 衛星数={d}\n", .{
            STATIONS[i].mount,
            coord.lat * 180.0 / std.math.pi,
            coord.lon * 180.0 / std.math.pi,
            sat_obs.len,
        });
        valid_count += 1;
    }

    if (valid_count < 3) {
        log("3局揃わず({d}局)。FKP計算スキップ。\n", .{valid_count});
        return;
    }

    // FKP 計算
    var stations: [3]engine.StationObs = undefined;
    for (0..3) |i| {
        stations[i] = station_obs_list[i].?;
    }
    const fkp_params = try engine.computeFkp(allocator, &stations);
    defer allocator.free(fkp_params);

    log("FKP計算完了: {d}衛星\n", .{fkp_params.len});
    for (fkp_params) |p| {
        log("  PRN{d:02}: N_I={d:.4} E_I={d:.4} N_0={d:.4} E_0={d:.4}\n", .{
            p.prn, p.n_i, p.e_i, p.n_0, p.e_0,
        });
    }

    // Type 59 エンコード → stdout にバイナリ出力
    const tow_ms: u32 = @truncate(@as(u64, @intCast(std.time.timestamp())) % (7 * 24 * 3600) * 1000);
    const frame = try type59.encodeType59(allocator, stations[0].coord.ref_station_id, tow_ms, fkp_params);
    defer allocator.free(frame);

    std.fs.File.stdout().writeAll(frame) catch {};
    log("Type59 フレーム出力: {d} bytes\n", .{frame.len});
}
