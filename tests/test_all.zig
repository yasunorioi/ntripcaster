//! tests/test_all.zig — テストアグリゲーター
//! `zig build test` でこのファイルのインポートツリー全体が走る。

const std = @import("std");

// 各テストモジュールをインポートすることで、
// そのファイル内の全 test ブロックが実行対象になる。
test {
    _ = @import("test_config.zig");
    _ = @import("test_auth.zig");
}
