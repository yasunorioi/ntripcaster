//! auth/basic.zig — NTRIP Basic認証
//!
//! 原典 client.c の `con_get_user()` + `authenticate_user_request()` を
//! Zig で再実装。
//!
//! 担当する処理:
//!   1. "Authorization: Basic <base64>" ヘッダー値から user:pass を抽出
//!   2. マウントテーブルに対して認証判定
//!
//! 外部依存: std.base64 のみ（ゼロ外部ライブラリ）

const std = @import("std");
const Config = @import("../config/parser.zig").Config;
const MountAuth = @import("../config/parser.zig").MountAuth;

// ── エラー型 ──────────────────────────────────────────────────────────────────

pub const AuthError = error{
    /// "Basic " プレフィックスがない
    InvalidHeader,
    /// Base64 デコード失敗
    InvalidBase64,
    /// デコード後に ":" 区切りが見つからない
    MissingColon,
    /// デコード結果がバッファに収まらない
    BufferTooSmall,
};

// ── Base64 デコード ────────────────────────────────────────────────────────────

/// Base64 エンコード文字列を `buf` にデコードし、デコード結果のスライスを返す。
/// `buf` は十分な大きさが必要（`encoded.len * 3 / 4 + 2` 以上を推奨）。
pub fn decodeBase64(encoded: []const u8, buf: []u8) AuthError![]u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
        return error.InvalidBase64;
    if (decoded_len > buf.len) return error.BufferTooSmall;
    std.base64.standard.Decoder.decode(buf[0..decoded_len], encoded) catch
        return error.InvalidBase64;
    return buf[0..decoded_len];
}

// ── 認証情報パース ────────────────────────────────────────────────────────────

/// user:pass ペアの型（parseCredentials / extractCredentials 共通）
pub const Credentials = struct {
    user: []const u8,
    pass: []const u8,
};

/// デコード済みの `"user:password"` 文字列を分割する。
/// ':' が見つからなければ null を返す。
pub fn parseCredentials(decoded: []const u8) ?Credentials {
    const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return null;
    return Credentials{
        .user = decoded[0..colon],
        .pass = decoded[colon + 1 ..],
    };
}

/// "Authorization:" ヘッダーの**値**部分（"Basic dXNlcjE6cGFzc3dvcmQx" 等）から
/// ユーザー名とパスワードを抽出する。
///
/// `buf` は一時バッファ（スタック上 512 バイト推奨）。
/// 返却スライスは `buf` の部分スライスを指す。
pub fn extractCredentials(header_value: []const u8, buf: []u8) AuthError!Credentials {
    const prefix = "Basic ";
    if (!std.mem.startsWith(u8, header_value, prefix)) return error.InvalidHeader;

    // プレフィックス除去 + 末尾空白トリム
    const encoded = std.mem.trimRight(u8, header_value[prefix.len..], " \t\r\n");

    const decoded = try decodeBase64(encoded, buf);
    return parseCredentials(decoded) orelse error.MissingColon;
}

// ── 認証判定 ──────────────────────────────────────────────────────────────────

/// NTRIP クライアントの認証を判定する。
///
/// `mount`: マウントパス（"/" で始まる、例: "/BUCU0"）
/// `user`, `pass`: extractCredentials から得た認証情報
///
/// 返り値:
///   - true  … 認証成功（またはオープンマウント）
///   - false … マウント不明 / ユーザー不一致 / パスワード不一致
pub fn authenticateClient(
    config: *const Config,
    mount: []const u8,
    user: []const u8,
    pass: []const u8,
) bool {
    const auth = config.mounts.get(mount) orelse return false;

    if (auth.open) return true;

    for (auth.users) |u| {
        if (std.mem.eql(u8, u.name, user) and std.mem.eql(u8, u.password, pass)) {
            return true;
        }
    }
    return false;
}

/// NTRIP ソース（基準局）の認証を判定する。
/// 原典: `authenticate_source()` / `encoder_password` 平文比較
pub fn authenticateSource(config: *const Config, password: []const u8) bool {
    return std.mem.eql(u8, config.encoder_password, password);
}
