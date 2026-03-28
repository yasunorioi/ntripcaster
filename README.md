# ntripcaster

NTRIP v1 caster — Zig rewrite of the BKG reference implementation.

> **Originally developed by BKG (Bundesamt für Geodäsie und Kartographie)**
> as part of the NTRIP protocol reference implementation (NtripCaster 0.1.5).
> Original C source preserved in [`/legacy/`](legacy/).

---

## Features

- NTRIP v1 server / source / client relay
- HTTP Basic authentication (sourcetable, per-mountpoint)
- Ring-buffer per source stream (zero-copy relay to multiple clients)
- Cross-compile ready: `x86_64-linux-musl`, `aarch64-linux-musl`
- systemd service unit with hardening options
- Single static binary — no runtime dependencies

## Build

Requires **Zig 0.14.0**.

```bash
# ネイティブビルド
zig build

# テスト実行
zig build test

# リリースビルド
zig build -Doptimize=ReleaseSafe
```

### クロスコンパイル

```bash
# Raspberry Pi / ARM64 Linux (musl)
zig build -Dtarget=aarch64-linux-musl

# x86_64 Alpine / OpenWrt
zig build -Dtarget=x86_64-linux-musl
```

成果物は `zig-out/bin/ntripcaster` に生成される。

## Install

```bash
# /usr/local/bin + /etc/ntripcaster/conf にインストール
sudo make install

# Debian/Ubuntu パッケージ生成 (.deb)
make deb

# RPM パッケージ生成
make rpm
```

## systemd 運用

```bash
# サービス有効化・起動
sudo systemctl enable ntripcaster
sudo systemctl start ntripcaster

# 状態確認
sudo systemctl status ntripcaster

# ログ確認
sudo journalctl -u ntripcaster -f
```

## 設定ファイル

デフォルト: `/etc/ntripcaster/conf/ntripcaster.conf`

主要設定項目:

| 項目 | デフォルト | 説明 |
|------|-----------|------|
| `port` | `2101` | NTRIP caster ポート番号 |
| `rtsp_port` | `554` | RTSP ポート（無効化可） |
| `encoder_password` | *(設定必須)* | Source 接続パスワード |
| `server_name` | `NtripCaster` | Sourcetable に表示する名前 |
| `location` | *(任意)* | サーバー設置場所 |
| `conf_dir` | `/etc/ntripcaster/conf` | 設定ディレクトリパス |
| `log_dir` | `/var/log/ntripcaster` | ログ出力ディレクトリ |
| `max_clients` | `100` | 最大クライアント接続数 |
| `max_sources` | `40` | 最大ソース接続数 |

詳細は [`conf/ntripcaster.conf`](conf/ntripcaster.conf) を参照。

## Architecture

```
Source (NTRIP source device)
  │  SOURCE /mountpoint HTTP/1.0
  ▼
[server.zig] accept + auth/basic
  │
  ▼
[ntrip/sourcetable.zig]  ← mountpoint 登録
  │
  ▼
[RingBuffer per source]  ← relay/ring_buffer.zig
  │
  ├─▶ Client 1 (GET /mountpoint)
  ├─▶ Client 2
  └─▶ Client N
```

詳細: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## Legacy C Implementation

`/legacy/` に BKG 原典 (NtripCaster 0.1.5, C言語) を保存。
プロトコル仕様・設定書式の照合ベースラインとして利用。

→ [`legacy/README.md`](legacy/README.md)

## License

GNU General Public License v2.0 — see [LICENSE](LICENSE).

Original NtripCaster: © BKG (Bundesamt für Geodäsie und Kartographie), Frankfurt, Germany.
Zig rewrite: © yasunorioi.
