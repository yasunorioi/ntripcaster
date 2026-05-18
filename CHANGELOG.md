# Changelog

All notable changes to this project are documented here.

---

## [0.4.0] — 2026-05-18 — VRS + Network RTK foundation (Phase 4 → 7-3)

Phase 3 (FKP runtime wire-up, v0.3.0) 以降の作業をまとめてリリース。
0.3.0 → 0.4.0 で大きく変わったのは、caster が **Network RTK サービスの
配線完成** に到達した点:

- **VRS (Virtual Reference Station)** が動く (Phase 4 + 5a)。rover の
  GGA を受け、仮想基準局として Type 1005 注入 + station_id 書き換え。
- **ephemeris-based DD residual パイプライン** が整った (Phase 7-1/2/3)。
  Type 1019 (GPS) パーサ + Keplerian propagator + 光行差/相対論補正 +
  SD/DD residual + reference PRN 選定の各モジュールを実装、`computeFkpDd`
  として新 API 提供。
- **設計の試行錯誤** も明示的に記録 (Phase 6b 撤去 — 案 B の前提誤読)。

ただし **本物の cm 級 FKP には未到達**。理由:
- Phase 7-3 で `computeFkpDd` は DD residual を作るが、N·λ DD bias が
  そのまま乗るので magnitude は依然大きい。Phase 7-4 (LAMBDA / MLAMBDA
  で整数 ambiguity fix) が次の課題。
- 現状の runtime は Phase 6a 互換 path (生 phase + 閾値) のまま。Phase
  7-5 で `computeFkpDd` 切替を予定。

### Phase 4: VRS 基盤 (4a/4b-lite/4d、5a が後付け)

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

Phase 4 既知 bug 修正:
- Type 1005 ref_id 12-bit truncation (silent bit 14 loss → ref_id=0x001
  に化けていたのを 12-bit 内マーカー範囲 0x800..0xFFF に変更)
- Type 1006 (= 1005 + Antenna Height) を filter に追加 (両方 leak すると
  rover で conflict)
- upstream.zig SIGSEGV — parseFrame に渡す slice 範囲を valid range に
  限定 (~30 分運用で再現していた長時間 crash の根本原因解消)

### Phase 5a: ref_id 書き換えで VRS が単一基準局として correlate

MSM7 / legacy obs / 1033 / 1230 の station_id を持つメッセージ
(1001..1012 / 1033 / 1071..1077 / 1081..1087 / 1091..1097 / 1101..1107 /
1111..1117 / 1121..1127 / 1131..1137 / 1230) の payload bits 12-23 を
rover.vrs_ref_id に書き換え + CRC-24Q 再計算。rover はすべて単一基準局
として認識。実機検証 (centipede-paris): rover 側で全 station_id 持ち
フレームが ref_id=0x801 に揃った。

### Phase 5b: MSM7 phase 補正の配線 (5b-1/2/3)

- `msm7.applyPhaseCorrection(frame, deltas)`: MSM7 ペイロードの fine_phase
  を in-place 補正し CRC-24Q を再計算する (Phase 5b-1)。
- `FkpSnapshotStore` で最新 FKP パラメータをスレッド安全に保持し、VRS
  forwardFiltered から非ブロッキングで参照可能 (Phase 5b-2)。
- forwardFiltered の MSM7 に FKP 位相補正を適用 (Phase 5b-3)。
- 実機検証: 配線は動くが FKP magnitude が物理的にあり得ない大きさ
  (10^4..10^6 m/rad) で fine_phase を ±4.7m 値域でクランプ → rover の
  RTK fix 失敗。Phase 6 で magnitude 問題に取り組む発端。

### Phase 6a: FKP magnitude 閾値判定で異常値を棄却

- `engine.DEFAULT_FKP_MAX_MAGNITUDE = 100.0 m/rad` (50km baseline で
  1m 補正 = 127 m/rad の境界より少し下)。
- `ComputeOptions { max_magnitude, stats }` で threshold 制御 + 統計取得。
- 閾値超過 PRN を棄却して FkpParam に含めない (safety net)。
- 実機確認: Paris 三角測量で毎 cycle excess=8..13 PRN が棄却される、
  rover 側 phase_corrected=92/30s が no-op fallback で動作。配線済みの
  Phase 5b-3 を破壊しない暫定保護。

### Phase 6b: rough_range residual 化 — 試行 + 撤去

Phase 6b-1/2/3 で MSM7 rough_range を近似 geometric range として引いた
residual ベースの SD/DD を実装したが、**理論再分析と実機検証で前提が
誤読** であることが判明 → 全コード revert (詳細: docs/phase6-design.md
§ 2.2 訂正 + § 9.1)。

棄却理由: MSM7 spec § 3.5.16 で `rough_int + rough_mod/1024` は衛星-局
geometric range の近似ではなく、carrier phase 観測値を 1/1024 ms 精度に
量子化した値。fine_phase は同じ観測値の細かい桁 (encoding remainder)。
引いても geometric range は分離されず、残るのは rounding noise (±4.7 m
wrap) のみ。真の geometric range removal は ephemeris ベースの衛星 ECEF
計算 (Phase 7) が必須。

### Phase 7-1: GPS Type 1019 broadcast ephemeris parser

- `src/fkp/ephemeris.zig` 新規 (~190 行):
  - `GpsEphemeris` struct: 全 28 field を SI 単位 (秒/メートル/ラジアン)
    に変換済の状態で保持。semi-circles → radians 変換 (× π) も parse 時
    に済ませる。
  - `parseMsg1019(payload) ?GpsEphemeris`: RTCM 10403.3 § 3.5.13 通りの
    bit 順でフィールドを抽出。
  - `EphemerisStore`: PRN → (eph, received_at_ms) の AutoHashMap、同一
    PRN は上書き、スレッド安全性は呼び出し側の Mutex に委ねる。
- `src/fkp/upstream.zig`: handleFrame に 1019 case 追加、Upstream.eph_store
  配管。
- テスト 5 件: parse の SI scale 検証 / 短 payload reject / 非 1019 reject /
  store roundtrip / 統合。

### Phase 7-2: GPS 衛星 ECEF propagator + 光行差 + 衛星時計補正

- `src/fkp/orbit.zig` 新規 (~165 行):
  - `gpsSatEcef(eph, t_sow) → SatPosition`: IS-GPS-200L Table 20-IV の
    16-step アルゴリズム。Kepler 方程式 Newton 反復 (~10 iter で 1e-13 rad
    収束)、2 次調和摂動 (cuc/cus/crs/crc/cic/cis)、Ω 補正 (地球自転)。
    week wrap 自動補正。
  - `satClockBiasGps(eph, t_emit_sow, ecc_anomaly, tgd_apply) → f64`:
    多項式 + 相対論補正 (F·e·sqrtA·sin(E)) + L1 用 tgd。
  - `geometricRangeGps(eph, t_recv_sow, sta_ecef) → GeometricRange`:
    光行差時間補正 τ の反復 (~3-4 iter で 1e-12 s 収束) + Earth rotation
    correction (Ωe·τ で z 軸回転)。
- テスト 9 件: Kepler 残差 / 円軌道で ECEF=(a,0,0) / week wrap / 多項式
  + 相対論 / tgd / GPS τ 67-87 ms / 地球回転補正量 ~150 m。

### Phase 7-3: ephemeris ベース SD/DD residual + ref PRN 選定

- `src/fkp/msm7.zig::PhaseObs` に `lock_time_indicator: u16` (DF407) と
  `cnr_db_hz: f64` (DF408) を追加、extractPhase で取り出す。
  cycle slip 検出 (Phase 7-4) と ref PRN 選定 (本フェーズ) の前提。
- `src/fkp/engine.zig` に Phase 7 新 API (+281 行):
  - `SatObsEx`: L1/L2 phase + 各 band の CNR + lock_time。
  - `StationObsEx`: coord + ECEF + t_recv_sow + obs[]。
  - `groupPhaseObsEx`: PhaseObs[] → SatObsEx[] (band 別に伝搬)。
  - `pickReferencePrn`: 3 局共通可視 + eph 登録済 PRN の平均 CNR 最大。
  - `computeFkpDd`: ref PRN 前計算 → 各 non-ref PRN で SD pair difference
    → DD = SD_j − SD_ref → LIF/LGF/plane fit → FkpParam。閾値判定維持。
- テスト 12 件: lock_time/CNR 抽出 / ref PRN 選定 3 ケース / groupEx
  band 別伝搬 / computeFkpDd synthetic 観測値で SD residual ≈ 0 / DD = 0 /
  FKP ≈ 0 (numeric noise レベル ≤ 1e-3 m/rad)。

既存 `computeFkp` は破壊せず並列で維持 (Phase 7-5 で runtime 切替予定)。

### Phase 7-4 へ向けて: 先行調査フェーズ

LAMBDA / MLAMBDA は ~600 行 + 数値安定性チューニングが要るので、実装前に
4 領域の先行調査を入れる (詳細: `docs/phase7-4-research.md`):
1. LAMBDA / MLAMBDA の参考実装 (RTKLIB / Rust 実装) 確認
2. MSM7 fine_phase scale (現在 2^-29 ms) の RTKLIB 整合性検証
3. FKP の rover 側適用 (Type 59 デコーダ実例) + plane fit の単位確認
4. VRS+FKP の代替として RTCM SSR (4072 シリーズ) も検討

調査結果次第で Phase 7-4 の方針 (フル MLAMBDA / bootstrapping / SSR 移行)
を決める。

---

## [unreleased] — Phase 7-4 research phase (no code changes yet)

Phase 7-4 (DD-N·λ ambiguity fix) 実装前の先行調査フェーズ。詳細は
`docs/phase7-4-research.md`。4 領域 (LAMBDA/MLAMBDA 参考実装、MSM7
fine_phase scale 検証、FKP rover 適用例、RTCM SSR 4072 シリーズ) を
調査してから、新ブランチで実装着手する。

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
