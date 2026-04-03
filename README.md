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
- Connection limit enforcement (max_clients / max_clients_per_source / max_sources)
- Dynamic sourcetable generation from active sources
- RTCM 3 frame analysis (0xD3 sync, CRC-24Q, message type detection)
- FKP (Flächenkorrekturparameter) computation engine for Network RTK
- Cross-compile ready: `x86_64-linux-musl`, `aarch64-linux-musl`, `arm-linux-musleabihf`, `mipsel-linux-musl`
- systemd service unit with hardening options
- Single static binary — no runtime dependencies

## Build

Requires **Zig 0.15.x** (tested with 0.15.2).

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
| `encoder_password` | *(設定必須)* | Source 接続パスワード |
| `server_name` | `localhost` | サーバーホスト名 |
| `location` | *(任意)* | サーバー設置場所 |
| `max_clients` | `100` | 最大クライアント接続数 |
| `max_clients_per_source` | `100` | マウントポイントあたり最大クライアント数 |
| `max_sources` | `40` | 最大ソース接続数 |
| `logdir` | `logs` | ログ出力ディレクトリ |
| `logfile` | `ntripcaster.log` | ログファイル名 |

### FKP 設定

Network RTK の FKP (面補正パラメータ) 計算・配信機能。
3局以上の NTRIP 基準局から搬送波位相データを取得し、FKP を計算して仮想マウントポイントとして配信する。

```conf
# FKP 有効化（デフォルト: false）
fkp_enable true

# 上流基準局（3局以上必須）
# 書式: fkp_source host/mountpoint [user:password]
# ポート変更時: fkp_source host:port/mountpoint [user:password]
fkp_source rtk2go.com/nakagawa00 test@example.com:none
fkp_source rtk2go.com/Asahikawa-HAMA test@example.com:none
fkp_source rtk2go.com/UEMATSUDENKI-F9P test@example.com:none

# FKP 配信マウントポイント名
fkp_mountpoint /FKP_HOKKAIDO

# FKP 計算間隔（秒、デフォルト: 1）
fkp_interval 1
```

詳細は [`conf/ntripcaster.conf`](conf/ntripcaster.conf) を参照。

## Architecture

```
Source (NTRIP source device)
  │  SOURCE /mountpoint HTTP/1.0
  ▼
[server.zig] accept + auth/basic + connection limit check
  │
  ▼
[ntrip/source.zig]  ← mountpoint registration + RTCM3 frame analysis
  │
  ▼
[ntrip/sourcetable.zig]  ← dynamic sourcetable (active sources + format-details)
  │
  ▼
[RingBuffer per source]  ← relay/ring_buffer.zig
  │
  ├─▶ Client 1 (GET /mountpoint)
  ├─▶ Client 2
  └─▶ Client N

FKP Engine (optional):
  [rtk2go etc.] ──▶ [fkp/msm7.zig] ──▶ [fkp/engine.zig] ──▶ [fkp/type59.zig]
   3+ base stations    MSM7 phase        FKP computation       RTCM Type 59
                       extraction        (Tanaka 2003)         encoding
                                              │
                                              ▼
                                     Virtual mountpoint (/FKP_*)
```

詳細: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## FKP Demo

rtk2go.com の北海道フリー基地局3局を使った FKP 計算実証:

```bash
zig build
./zig-out/bin/fkp-demo
```

参考文献: 田中慎治 (2003)「ネットワークRTK-GPS測位に関する研究」東京商船大学修士論文

## Legacy C Implementation

`/legacy/` に BKG 原典 (NtripCaster 0.1.5, C言語) を保存。
プロトコル仕様・設定書式の照合ベースラインとして利用。

→ [`legacy/README.md`](legacy/README.md)

## License

GNU General Public License v2.0 — see [LICENSE](LICENSE).

Original NtripCaster: © BKG (Bundesamt für Geodäsie und Kartographie), Frankfurt, Germany.
Zig rewrite: © yasunorioi.
