//! lib.zig — テスト用モジュールエクスポート
//! src/ ツリーを単一モジュール "ntripcaster" として公開する。
//! zig build test が tests/ から src/ を参照するために使用。

pub const config = @import("config/parser.zig");
pub const auth = @import("auth/basic.zig");
pub const ntrip_protocol = @import("ntrip/protocol.zig");
pub const sourcetable = @import("ntrip/sourcetable.zig");
pub const relay = @import("relay/engine.zig");
pub const log_mod = @import("log.zig");
pub const server_mod = @import("server.zig");
