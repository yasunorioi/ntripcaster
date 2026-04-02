//! lib.zig — テスト用モジュールエクスポート
//! src/ ツリーを単一モジュール "ntripcaster" として公開する。
//! zig build test が tests/ から src/ を参照するために使用。

pub const config = @import("config/parser.zig");
pub const auth = @import("auth/basic.zig");
pub const ntrip_protocol = @import("ntrip/protocol.zig");
pub const sourcetable = @import("ntrip/sourcetable.zig");
pub const rtcm3 = @import("ntrip/rtcm3.zig");
pub const relay = @import("relay/engine.zig");
pub const log_mod = @import("log.zig");
pub const server_mod = @import("server.zig");
pub const fkp_bits = @import("fkp/bits.zig");
pub const fkp_msm7 = @import("fkp/msm7.zig");
pub const fkp_engine = @import("fkp/engine.zig");
pub const fkp_type59 = @import("fkp/type59.zig");
