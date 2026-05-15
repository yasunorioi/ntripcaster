//! lib.zig — public surface of the ntripcaster module.
//! Used by the executable, tests, tools, and the upcoming admin server.

pub const config = @import("config/parser.zig");
pub const auth = @import("auth/basic.zig");
pub const log = @import("log.zig");
pub const relay = @import("relay/engine.zig");
pub const server = @import("server.zig");

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
    pub const upstream = @import("fkp/upstream.zig");
    pub const runtime = @import("fkp/runtime.zig");
};

pub const admin = struct {
    pub const stats = @import("admin/stats.zig");
    pub const server = @import("admin/server.zig");
};
