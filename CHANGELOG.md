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

### Phase 4 既知問題の修正

**Type 1005 注入バグ — 真因: ref_id 12-bit truncation (修正済)**:
- `inject1005` が `ref_id = 0x4000 | (rover.id & 0x0FFF)` で u16 にトランケー
  ト後、`encodeMsg1005` の `BitWriter.writeU(12, ref_station_id)` で低 12 bit
  のみ書き込まれていたため、0x4000 マーカービット (bit 14) が silent に欠落。
  結果 rover からは ref_id=0x001 (=1) としてしか見えなかった。
- 修正: VRS 仮想マーカー範囲を 12-bit 内 (`0x800 | (rover.id & 0x7FF)` →
  2048..4095) に変更。`encodeMsg1005` 側にも `RefIdOutOfRange` バリデー
  ション追加で再発防止。
- centipede.fr の Paris 3 局 (CROI / IPGP / SGC) を上流にして実機テスト
  (rtk2go は依然レート制限中だったため代替)。RTKLIB str2str で
  /VRS_PARIS に GGA 送信付き接続 → 受信 RTCM3 を python で msg_type 集計:
  - 修正前 (前 commit): ref_id=0x0801 期待 → ref_id=0x0001 観測 (再現)
  - 修正後: ref_id=0x0801 (2049) が 5 frames / 25s で観測 ✅

**診断ログ + テスト整備**:
- 初回 GGA パース時 / 初回 inject 1005 時 / 5 秒ごとの filter stats
  (forwarded / dropped_1005 / inject_1005_count) / rover 切断時の総計
  サマリを info ログに追加。問題発生時に「GGA 受信成否」「inject 発火回数」
  「実際の filter 通過状況」がログだけで切り分けられる。
- `src/fkp/vrs.zig`: forwardFiltered を anytype writer 化 (CaptureWriter で
  socket なしテスト可能に)。ref_id 12-bit roundtrip regression test 追加。
- `src/lib.zig`: src/ 配下の `test {}` ブロックを test runner に拾わせる
  comptime ref。lazy import 解決。
- `build.zig`: lib.zig をルートにした `src_tests` step 併走 (tests/
  test_all.zig のモジュール境界で src 配下の test が集約されない問題)。
- `conf/centipede-paris.conf`: 再現テスト用設定 (rtk2go レート制限回避)。
- Test count: 141 → 159 (18 件追加: vrs 9 件 + 既存 src 9 件)

**Type 1006 を filter に追加 (修正済)**:
- 1006 は 1005 + Antenna Height で機能的に等価。upstream のものを
  passthrough すると rover に異なる ref_id の 1005 / 1006 が両方届いて
  conflict するため、`forwardFiltered` の drop 条件に追加。
- `frames_dropped_1006` カウンタ + 5 秒 stats log と切断時サマリにも反映。
- 実機検証 (centipede.fr 上流): 修正前は Type 1006 が 1 frame leak → 修正後
  0 frames で Type 1005 (ref_id=0x0801) のみ出ることを確認。

**upstream.zig SIGSEGV — 真因: parseFrame に渡す slice の範囲ミス (修正済)**:
- `rtcm3.parseFrame(parse_buf[pos..])` で渡す slice が `parse_buf[pos..parse_buf.len]`
  (= 8192 - pos バイト) であり、parseFrame は valid data が末尾まで詰まって
  いると信じて動作する。stale バイト (parse_len 以降の未到達領域) で length
  field を読み、CRC が偶然一致した場合に `consumed > (parse_len - pos)` の
  "success" を返す。これを受けて `pos += consumed` で `pos > parse_len`
  状態となり、後段の shift で `parse_len - pos` が usize underflow → 巨大
  値 → @memcpy / copyForwards で OOB → SIGSEGV。
- 修正: `parse_buf[pos..parse_len]` に slice を絞る (1 単語追加)。これで
  parseFrame の契約 `consumed <= data.len` が valid range のみに適用される。
- 実機検証 (centipede.fr): 修正前は ~30 分 / inject_1005=412 で
  `pos > parse_len` の assertion fire (SIGSEGV 相当)。修正後は同条件で
  43 分 / inject_1005=538 経過しても crash ゼロ。
- `@min(pos, parse_len)` 防御パッチも削除 (不要になった)。
- `tests/test_rtcm3.zig`: 呼び出し側 slice 範囲の正しさを示す regression
  test 追加。

**未解決**:
- ⚠️ Phase 5: MSM7 ref_id が upstream の値 (=1) のまま rover に届き、
  VRS 注入 1005 の ref_id (0x801) と一致しないため rover が
  「異なる station からの観測」として扱う。MSM7 encoder + ref_id
  書き換えが必要 (Phase 5 design)。

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
