//! tests/test_all.zig — テストアグリゲーター
//! `zig build test` でこのファイルのインポートツリー全体が走る。

const std = @import("std");

// 各テストモジュールをインポートすることで、
// そのファイル内の全 test ブロックが実行対象になる。
test {
    _ = @import("test_config.zig");
    _ = @import("test_auth.zig");
    _ = @import("test_protocol.zig");
    _ = @import("test_sourcetable.zig");
    _ = @import("test_rtcm3.zig");
    _ = @import("test_relay.zig");
    _ = @import("test_server.zig");
}
