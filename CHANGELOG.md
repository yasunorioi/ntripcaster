# Changelog

All notable changes to this project are documented here.

---

## [0.3.0] — 2026-05-15 — FKP runtime wire-up (Phase 3)

FKP モジュール群を起動時に常時稼働するサービスへ昇格。これまで `tools/fkp_demo.zig` でしか実行できなかった「3 局並列接続 → MSM7 抽出 → FKP 計算 → Type 59 エンコード」を、caster 本体の永続バックグラウンドスレッドに統合した。

- `src/fkp/upstream.zig` 新規: 単一上流 NTRIP rover (GET 接続維持 + RTCM3 ストリーミング + 1005/MSM7 抽出 + 任意のパススルー callback + 指数バックオフ再接続)
- `src/fkp/runtime.zig` 新規: FKP オーケストレータ。`fkp_enable=true` かつ `fkp_sources>=3` かつ `fkp_mountpoint` 指定時に仮想 `Source` を `state.sources` に登録し、主上流の生 RTCM3 を `RingBuffer` にパススルー + `fkp_interval` 秒ごとに Type 59 を注入。
- `src/main.zig`: ServerState 初期化後・listen() 前に `Runtime.create()` → `start()`、shutdown 時に `shutdown()` → `destroy()`。
- 既存テスト全パス、追加リグレッションなし。Mermaid 図の `fkp_engine -.-> source/client` (点線=未配線) を実線エッジに更新。

これで rover は単一マウントポイント (`GET /FKP_REGION`) で主上流の RTCM3 + FKP 補正を取得できる、ネットワーク RTK サービスとして完成した状態に到達。

## [0.2.1] — 2026-03-28 — Zig 0.15.2 migration

- Migrate all source to Zig 0.15.2 API (ArrayList, std.fs.File, std.Thread)
- Update CI/CD workflows to Zig 0.15.2
- build.zig: adopt .root_module pattern (0.15 style)

## [0.2.0] — 2026-03-28 — Zig rewrite

Complete rewrite of the BKG C implementation in Zig.
Original C source preserved in `/legacy/` without modification.

### Phase 2 — Zig フルリライト (cmd_463)

**Phase 2d** — 相互運用テスト + クロスコンパイル完成
- BKG原典 C実装との相互運用テスト全通過（SOURCE/GET/SOURCETABLE）
- クロスコンパイル: `aarch64-linux-musl` / `x86_64-linux-musl`
- use-after-free バグ修正（relay 切断時の RingBuffer アクセス）

**Phase 2c** — サーバー統合 (subtask_1025)
- `server.zig`: TCP accept ループ + HTTP dispatch
- `source.zig`: SOURCE コネクション + RingBuffer 書き込み
- `client.zig`: GET コネクション + RingBuffer 読み出し
- `main.zig`: CLI エントリポイント完成

**Phase 2b** — プロトコル層実装 (subtask_1024)
- `ntrip/protocol.zig`: NTRIP v1 HTTP パーサー（SOURCE/GET/SOURCETABLE）
- `ntrip/sourcetable.zig`: mountpoint 登録・Sourcetable 生成
- `relay/ring_buffer.zig`: ロックフリー Ring Buffer（複数クライアント対応）
- `log.zig`: 構造化ログ出力

**Phase 2a** — ビルド基盤 + 設定 + 認証 (cmd_463 Phase 2a)
- `build.zig`: zig build system (build/test/cross-compile target 定義)
- `config/parser.zig`: ntripcaster.conf パーサー
- `auth/basic.zig`: HTTP Basic 認証
- `main.zig`: stub エントリポイント

### Phase 1 — systemd サービス化 + パッケージ整備 (cmd_461)
- `ntripcaster.service`: systemd unit（DynamicUser + NoNewPrivileges ハードニング）
- `Makefile`: `install` / `deb` / `rpm` ターゲット追加
- パッケージメタデータ整備

### Phase 0 — ビルドシステム修正 + musl 対応 (cmd_459)
- `build.zig.zon`: Zig パッケージマニフェスト
- autoconf/automake regenerate (`autoreconf -fi`)
- `--prefix` によるコンフィグパス解決（ハードコード排除）
- musl libc 互換対応（Alpine Linux / OpenWrt）
- `.gitignore` 整備

---

## [0.1.5] — Original C implementation

**BKG NtripCaster 0.1.5**
Copyright (C) BKG (Bundesamt für Geodäsie und Kartographie), Frankfurt.
Developed by Lesparre, Weber — BKG.

- NTRIP v1 caster (server/source/client relay)
- HTTP Basic 認証
- Source table 管理
- autoconf/automake ビルドシステム
- GNU GPL v2

Original source archived in `/legacy/`.
