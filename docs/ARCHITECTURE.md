# Architecture — ntripcaster (Zig rewrite)

## Module Structure

```
src/
├── main.zig              # CLI エントリポイント / サーバー起動
├── server.zig            # TCP acceptループ / HTTP dispatch
├── source.zig            # SOURCE コネクション管理
├── client.zig            # GET クライアント管理
├── lib.zig               # 共有型定義 / エラー型
├── log.zig               # 構造化ログ出力
├── auth/
│   └── basic.zig         # HTTP Basic 認証
├── config/
│   └── parser.zig        # ntripcaster.conf パーサー
├── ntrip/
│   ├── protocol.zig      # NTRIP v1 HTTP パーサー
│   ├── sourcetable.zig   # Sourcetable 生成 / mountpoint 管理
│   ├── source.zig        # Source セッション型
│   ├── client.zig        # Client セッション型
│   └── engine.zig        # Relay エンジン（Source/Client 対応表）
└── relay/
    └── ring_buffer.zig   # ロックフリー Ring Buffer
```

## Data Flow: Source → RingBuffer → Client

```
[NTRIP Source Device]
  │  SOURCE /mountpoint HTTP/1.0
  │  Authorization: Basic ...
  │  (RTCM data stream)
  ▼
[server.zig] TCP accept
  │
  ▼
[ntrip/protocol.zig] HTTPリクエスト解析
  │  SOURCE → source handler
  │  GET    → client handler
  ▼
[auth/basic.zig] 認証チェック
  │
  ├─[Source path]─────────────────────────────┐
  │  ntrip/engine.zig に mountpoint 登録       │
  │  relay/ring_buffer.zig に RTCM データ書込  │
  │                                           │
  └─[Client path]──────────────────────────── ┘
     ntrip/engine.zig で mountpoint を検索
     relay/ring_buffer.zig からデータ読出し
     クライアントへ ICY 200 OK + ストリーム送信
```

## Design Decisions

### Ring Buffer（ロックフリー）
- 1 Source : N Clients の fan-out を効率化
- 各クライアントが独立した read pointer を持つ
- Source が高速でもクライアントが遅い場合は古いデータを上書き（最新優先）
- Zig の `std.atomic` を使用。Mutex 不要

### HTTP/NTRIP v1 プロトコル
- NTRIP v1 は HTTP/1.0 ベースだが非標準レスポンス（`ICY 200 OK`）を使用
- BKG原典の挙動を interoperability test で確認し、完全互換を保証
- sourcetable リクエスト（`GET / HTTP/1.0`）は専用ハンドラで処理

### クロスコンパイル
- Zig の built-in cross-compile により、開発機（x86_64）から RPi（aarch64）向けバイナリを生成可能
- `musl` libc で完全静的リンク → 本番環境に Zig 不要

### 設定ファイル互換性
- `ntripcaster.conf` フォーマットは BKG 原典と互換
- `legacy/conf/ntripcaster.conf` をそのまま使用可能

## Interoperability Test

```
tests/interop/
├── test_source_connect.sh   # BKG C実装 ↔ Zig実装の相互接続
├── test_sourcetable.sh      # Sourcetable 形式の一致確認
└── test_relay.sh            # SOURCE→CLIENT リレーの整合性確認
```

BKG原典 C実装をリファレンスとして、全テスト通過を確認済み（Phase 2d）。
