//! lib.zig — テスト用モジュールエクスポート
//! src/ ツリーを単一モジュール "ntripcaster" として公開する。
//! zig build test が tests/ から src/ を参照するために使用。

pub const config = @import("config/parser.zig");
pub const auth = @import("auth/basic.zig");
