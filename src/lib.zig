//! lib.zig — public surface of the ntripcaster module.
//! Used by the executable, tests, tools, and the upcoming admin server.

pub const config = @import("config/parser.zig");
pub const auth = @import("auth/basic.zig");
pub const io = @import("io.zig");
pub const log = @import("log.zig");
pub const relay = @import("relay/engine.zig");
pub const server = @import("server.zig");

pub const net = struct {
    pub const sockopt = @import("net/sockopt.zig");
};

pub const ntrip = struct {
    pub const protocol = @import("ntrip/protocol.zig");
    pub const sourcetable = @import("ntrip/sourcetable.zig");
    pub const rtcm3 = @import("ntrip/rtcm3.zig");
    pub const source = @import("ntrip/source.zig");
    pub const client = @import("ntrip/client.zig");
};

pub const fkp = struct {
    pub const bits = @import("fkp/bits.zig");
    pub const msm7 = @import("fkp/msm7.zig");
    pub const engine = @import("fkp/engine.zig");
    pub const type59 = @import("fkp/type59.zig");
    pub const ephemeris = @import("fkp/ephemeris.zig");
    pub const orbit = @import("fkp/orbit.zig");
    pub const upstream = @import("fkp/upstream.zig");
    pub const runtime = @import("fkp/runtime.zig");
    pub const vrs = @import("fkp/vrs.zig");
};

pub const admin = struct {
    pub const stats = @import("admin/stats.zig");
    pub const server = @import("admin/server.zig");
};

// src/ 配下の全ファイルの test ブロックをコンパイル単位に含めるため、
// すべてのモジュールに対し comptime 参照を作る。
// `pub const X = @import(..)` だけだと未使用扱いで lazy import になり、
// テストルートから test ブロックが見つからない (zig 0.15.2 確認済)。
comptime {
    _ = config;
    _ = auth;
    _ = io;
    _ = log;
    _ = relay;
    _ = server;
    _ = net.sockopt;
    _ = ntrip.protocol;
    _ = ntrip.sourcetable;
    _ = ntrip.rtcm3;
    _ = ntrip.source;
    _ = ntrip.client;
    _ = fkp.bits;
    _ = fkp.msm7;
    _ = fkp.engine;
    _ = fkp.type59;
    _ = fkp.ephemeris;
    _ = fkp.orbit;
    _ = fkp.upstream;
    _ = fkp.runtime;
    _ = fkp.vrs;
    _ = admin.stats;
    _ = admin.server;
}
