# Changelog

All notable changes to this project are documented here.

---

## [unreleased] — VRS Phase 4 (work-in-progress, on phase4-vrs branch)

VRS (Virtual Reference Station) Phase 4a (GGA 受信) + 4b-lite (Type 1005 注入)
+ 4d (セル境界) を実装。Phase 4c (MSM7 補正適用) は MSM7 エンコーダが必要
なため未着手 → Phase 5 で対応予定。

- `src/fkp/vrs.zig` 新規 (~400 行): VrsRuntime/VrsRover + GGA ASCII パーサ
  + 1 rover = 1 スレッドの双方向 TCP ハンドラ + 主上流 RingBuffer からの
  フレーム単位フィルタ転送 (1005/59 除外) + 仮想 Type 1005 注入 + セル
  距離チェック (Haversine)
- `src/fkp/msm7.zig`: `latLonAltToEcef()` + `encodeMsg1005()` 追加
  (parseMsg1005 の対称ペア)
- `src/server.zig`: `VrsHandler` dispatch 構造体追加 (循環依存回避用の
  関数ポインタ抽象)
- `src/ntrip/client.zig`: VRS mountpoint マッチ時に VrsRuntime に丸投げ
- `src/main.zig`: VrsRuntime 起動シーケンス (FKP runtime 依存)
- `src/config/parser.zig`: vrs_enable / vrs_mountpoint / vrs_cell_center_lat
  / vrs_cell_center_lon / vrs_cell_radius_km / vrs_initial_gga_timeout_sec
  / vrs_inject_1005_interval_sec
- `conf/rtk2go-hiroshima.conf`: vrs サンプル設定追加
- `docs/vrs-design.md`: VRS の設計判断と Phase 分割の根拠

### Phase 4 既知問題の調査 (進行中)

**Type 1005 注入バグ調査**:
- `forwardFiltered` / `handleGgaLine` / `parseDdmm` の unit test 追加 → 全て
  仕様通りに動作することを確認 (encodeMsg1005 で生成した実 1005 フレーム
  も含めて drop される)。コード上の filter は正常。
- 「178 Type 1005 frames at /VRS_HIROSHIMA」観測の出所が不明 → 計測経路
  の取り違え (/FKP_HIROSHIMA への誤接続等) の可能性。次回テストで
  追加 diagnostic ログから断定する。
- 診断ログ追加: 初回 GGA パース時 / 初回 inject 1005 時 / 5 秒ごとの
  filter stats (forwarded / dropped_1005 / inject_1005_count) / rover
  切断時の総計サマリ。これで「GGA 受信成否」「inject 発火回数」「実際の
  filter 通過状況」が log だけで分かるようになった。
- `src/fkp/vrs.zig`: forwardFiltered を anytype writer 化 (テスト時に
  std.net.Stream を使わずに済むよう CaptureWriter で hook 可能に)
- `src/lib.zig`: src/ 配下の `test {}` ブロックを test runner に拾わせる
  ための comptime ref を追加
- `build.zig`: lib.zig をルートにした `src_tests` step を併走 (これまで
  `tests/test_all.zig` のモジュール境界で src 配下の test が集約されて
  いなかった)
- Test count: 141 → 157 (16 件追加: vrs 7 + 既存 src 9)

**未解決**:
- ⚠️ 「0x4000+ の VRS 注入 ID が観測されない」: GGA を送らない test client
  (curl 等) で観測されたものなら期待通り (has_position=false で inject1005
  が走らないため)。次回テストで「first GGA parsed」log が出るか確認する。
- ⚠️ `src/fkp/upstream.zig` 長時間稼働後に `parse_len - pos` integer
  overflow で SIGSEGV。発生条件未特定だが `@min(pos, parse_len)` で防御
  パッチ済み。根本原因は次セッションで再現させて修正

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
