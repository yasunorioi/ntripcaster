//! net/sockopt.zig — NTRIP source / client コネクション共通の socket 設定
//!
//! 想定環境: 農機 (LTE 弱電界 / Starlink / 工場系 EMI 多発) と、基準局
//! (光回線だが時々瞬断) の両側。半開放 TCP / 詰まった writeAll が
//! コネクション枠を食い続けるのを防ぐため、以下を有効化する。

const io = @import("../io.zig");

/// 長寿命ストリーミング接続向け socket 設定。client / source 両方に適用する。
///
/// - SO_SNDTIMEO=10s: writeAll が詰まった client を 10 秒で drop。LTE 弱電界の
///   ACK 不達 / Starlink 切替で send buffer が詰まる典型シナリオを kick する。
/// - SO_KEEPALIVE + TCP_KEEPIDLE=60 + KEEPINTVL=5 + KEEPCNT=3:
///   半開放 (LTE エリア跨ぎ / caster 側回線瞬断後の reconnect で発生) を
///   約 60 + 5*3 = 75 秒で kernel に死亡判定させる。
///
/// 失敗は無視する (古い kernel で TCP_KEEP* 系を持ってない等で die しない
/// よう、`catch {}` する)。
pub fn configureStreamingSocket(stream: io.Stream) void {
    // SO_SNDTIMEO=10s: 詰まった client を drop。
    io.setSendTimeoutMs(stream.handle, 10_000);
    // KEEPALIVE + KEEPIDLE=60 + KEEPINTVL=5 + KEEPCNT=3 → 半開放を ~75s で検出。
    io.enableKeepAlive(stream.handle, 60, 5, 3);
}
