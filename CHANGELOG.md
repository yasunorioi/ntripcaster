# Changelog

All notable changes to this project are documented here.

---

## [Unreleased]

### 追加

- **`default_mount_access` 設定**: config に `/MOUNT` 行が無い mount への
  client GET の既定挙動を `deny` (規格動作: 401 で蹴る) と `open`
  (source が push さえすれば誰でも GET 可) から選べるように。default は
  `deny` で従来動作と互換。`/MOUNT` や `/MOUNT:user:pass` の明示行はこの
  設定に関わらず該当行が優先される。

### 削除

- **Legacy C source (`/legacy/`) を repo から削除**: BKG NtripCaster 0.1.5
  (5.4MB) を working tree から外した。git history (753253f まで) には
  残っているので、必要なら `git show 753253f:legacy/...` で取り出せる。
  Zig rewrite が機能パリティ + 拡張機能を持つようになって参照頻度が落ちた
  ため。

### 変更

- **Sourcetable CAS/NET 自動生成**: 手書き `conf/sourcetable.dat` を廃止。
  CAS 行 (`CAS;host;port;identifier;operator;nmea;country;lat;lon;...`) と
  NET 行は `caster_*` / `network_*` 設定キーから自動組み立てる。
  - 新しい設定キー: `caster_identifier` / `caster_operator` / `caster_nmea` /
    `caster_country` / `caster_latitude` / `caster_longitude` /
    `caster_fallback_host` / `caster_fallback_port` / `caster_misc` /
    `caster_host` (空なら `server_name` を使用)
  - NET 行は `network_identifier` が非空のとき自動付加 (`network_operator` /
    `network_auth` / `network_fee` / `network_web_net` / `network_web_str` /
    `network_web_reg` / `network_misc`)
  - STR 行は従来通り接続中 source から動的生成
  - `sourcetable.zig` に `CasterInfo` / `NetworkInfo` 構造体と
    `buildCasterHeader()` を追加。`readFile()` は削除。

---

## [0.5.0] — 2026-05-18 — NTRIP v2 protocol support

NTRIP v2 (HTTP/1.1 ベース) のプロトコル対応を追加。v1 (ICY 200 OK) 互換は維持。
本リリースはプロトコル層のみの対応で、ユーザ管理 / Digest auth / HTTPS は
意図的にスコープ外。

### 追加機能

- **V2 client GET**: `Ntrip-Version: Ntrip/2.0` ヘッダー検出時、`HTTP/1.1 200 OK`
  + `Content-Type: gnss/data` + `Transfer-Encoding: chunked` で応答。
  RTCM データを chunked encoding でフレーム送信し、接続終了時に終端 chunk
  `0\r\n\r\n` を送出。
- **V2 source POST**: `POST /<mount> HTTP/1.1` + `Authorization: Basic ...`
  形式の source push を受理。認証通過時は `HTTP/1.1 200 OK`、不正パスワードは
  `HTTP/1.1 401 Unauthorized` を返す。
- **Expect: 100-continue** 対応: V2 POST source に Expect ヘッダーがあれば
  `HTTP/1.1 100 Continue` を先送りしてから body 受信を開始。
- **V2 sourcetable**: V2 クライアントからの `GET /` には `HTTP/1.1 200 OK`
  + `Content-Type: gnss/sourcetable; charset=UTF-8` + `Ntrip-Version: Ntrip/2.0`
  で応答。
- **Client-side keep-alive**: V2 sourcetable に対する `Connection: keep-alive`
  を受理。同一 TCP コネクションで最大 20 リクエスト、idle 30 秒の上限。
  データストリーム (long-running) と source push は keep-alive 非対応（仕様上意味薄）。
- **V2 エラー応答**: 404/401/503/400/409 など、すべての V2 エラー応答を
  `HTTP/1.1 <status>` + `Server` + `Ntrip-Version` ヘッダー付きで統一。

### 変更点 (互換)

- `protocol.zig`: `NtripRequest.sourcetable_get` が `void` から構造体に変更
  （`is_v2`, `keep_alive` フィールド付加）。`SourceLogin` / `ClientGet` にも
  `is_v2`、`expects_100`, `keep_alive`, `auth_header` を追加。
- `sourcetable.zig`: V2 用に `buildResponseV2()` を新設。`buildResponse()`
  (V1) のシグネチャは不変。
- V1 経路 (`ICY 200 OK`, `SOURCETABLE 200 OK`, `SOURCE`, source `OK\r\n`)
  は完全に従来通り動作。

### スコープ外 (明示)

- **HTTPS / TLS** — 将来検討、今回は対応しない
- **Digest authentication** — Basic のみ
- **RTSP/RTP モード** — 主要ベンダーは HTTP モードのみ実装、追従しない
- **ユーザ管理システム** — flat-file Basic auth のまま (個人運用前提)
- **厳密 chunked decode** — V2 source POST の body は chunked headers を
  「未知バイト列」として読み流す。RTCM3 フレーム検出が先頭から同期するので
  実用上問題なし。str2str など主要 V2 pusher も raw stream で送る実装が多い。

### バージョン整合性

- `build.zig.zon` の version: `0.2.1` (停滞) → `0.5.0` に更新
- `sourcetable.zig` の `CASTER_VERSION`: `0.2.0` (停滞) → `0.5.0` に更新

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

## [unreleased] — Phase 7-3.5 / 7-4 / 7-5 計画確定 (調査完了、実装まだ)

Phase 7-4 (DD-N·λ ambiguity fix) 実装前の先行調査が完了し、当初想定と
**大きく異なる発見**が出た。詳細: `docs/{lambda-research,msm7-scale-validation,type59-rover-side,ssr-feasibility}.md`
+ `docs/phase7-4-research.md` の「統合判断 (2026-05-18 確定)」セクション。

### 主要発見

- **領域 2 (MSM7 parser)**: 既存 `src/fkp/msm7.zig::extractPhase` に **2 つの
  構造的バグ**:
  - fine_phase scale が `2^-29 ms` (誤、MSM4/5 用) で実装、MSM7 (24-bit)
    の正しいスケールは `2^-31 ms`。**factor 4 誤り**。
  - signal / satellite data block の bit layout が **cell-major** で実装
    されているが、RTCM 10403.3 / RTKLIB は **field-major**
    (`[pseudo×ncell][phase×ncell][lock×ncell][half×ncell][cnr×ncell][rate×ncell]`)。
    ncell=1 or nsat=1 のときだけ偶然一致するので一部テストでは見えなかった。
  - 既存テスト (`expectedPhaseM` + frame builder) も同じ誤りで self-consistent
    化していた。
  - = Phase 5b-3 で rover 補正値が ±1171 m clamp ヒットしていた**真因**。
    LAMBDA 以前の問題。
- **領域 3 (Type 59 rover side)**: RTKLIB は Type 59 を **silent ignore**
  (switch 文に case なし)、標準 FKP (Type 1034/1035) も RTKLIB は空スタブ。
  業界全体で FKP は事実上廃止 (Geo++ GNSMART のみ生きた採用)。
  → Type 59 を **caster 内部 IPC** と再定義、rover には MSM7 補正済みのみ
    届ける (Phase 5b の applyPhaseCorrection 路線で既に実現済み)。
- **領域 4 (RTCM SSR 検討)**: RTKLIB SSR support は orbit/clock/code-bias/URA/
  phase-bias の SSR 1-7 のみ。**atmospheric SSR (STEC / tropo) は decoder
  すら未実装で spec も非公開**。NRTK 業界の主流は VRS+FKP。
  → **FKP 継続が最適**、SSR 移行は不要。Phase 8 で補助 SSR は検討余地。
- **領域 1 (LAMBDA)**: RTKLIB `lambda.c` は実は **188 行** (見積もり 600 行
  は過大)、Rust 実装は GitHub/crates.io ともに 0 件 (FFI 案は破棄)。
  Zig フル port は 250-350 LoC、3-4 日工数。
  → **Bootstrapping (~50 LoC) を Day 1 先行 → 実機 success rate 測定 →
    必要なら MLAMBDA** の二段階リリース推奨。

### 確定したフェーズ計画

| Phase | 内容 | 工数 | 必要性 |
|-------|------|------|--------|
| **7-3.5** | MSM7 parser バグ修正 (scale 2 行 + layout 中規模書き直し + test 同期 + 実機検証) | 半日-1 日 | **必須、最優先** |
| **7-4a** | Bootstrapping ambiguity + cycle slip 検出 (lock_time monitoring) | 1 日 | 7-3.5 後の magnitude が > 10 m/rad なら必要 |
| **7-4b** | MLAMBDA フル実装 (rtklib-py/mlambda.py からポート) | 3-4 日 | 7-4a の fix 率 < 80% なら必要 |
| **7-5** | runtime 配線切替 (computeFkp → computeFkpDd) + L2 周波数スケール η^i 追加 + 実機検証 | 半日-1 日 | 必須 |
| **8** | SSR 1/2/4 (orbit + clock) 補助配信 | 1-2 日 | オプション |

### 次セッション最初の作業

`phase7-3.5-msm7-fix` ブランチを master から派生し、MSM7 parser バグ修正
+ test 同期 + 実機 RTKLIB との binary cross-decode + Phase 5b-3 再実行で
magnitude 再計測。詳細は `docs/phase7-4-research.md` § 「次セッション最初
の作業」。

### 副次決定 (記録のみ)

- Type 59 は caster **内部 IPC** であり、rover には届けない (RTKLIB が
  silent ignore するため)。Phase 5b の `forwardFiltered` が既に Type 59
  を drop しているので機能変更なし。コメントレベル更新のみ予定。
- 領域 3 の指摘で **L2 周波数スケール η^i (= (F_L1/F_L2)^2 ≈ 1.6469)** が
  `computePhaseDelta` に未実装と判明。Phase 7-5 で追加。Phase 7-3 までの
  L1 のみ補正では無害。

### Phase 7-3.5 完了 + RTKLIB 実機検証 (2026-05-18)

`phase7-3.5-msm7-fix` ブランチで MSM7 parser 2 バグ (factor 4 scale + cell-major
layout) を修正、master へマージ (`fd28d5d`)。詳細: `99c0ceb` commit body と
`docs/msm7-scale-validation.md`。

実機検証 (`docs/phase7-3.5-verification.md`):

- **段階 1 (convbin で binary cross-decode、成功)**: ntripcaster `/VRS_PARIS`
  出力を RTKLIB convbin で RINEX に変換、`R04 pseudo=22,860,052 m /
  phase=122,414,485 cycles` (cycle×λ ≈ pseudo) で物理整合確認。CRC 通過、
  59 epoch × 30 衛星すべて出力。修正前の cell-major / 2^-29 ms 実装では
  convbin が obs body を出せなかったはずで、**Phase 7-3.5 が RTKLIB 互換
  であることの確証**。

- **段階 2 (rtkrcv で RTK fix 試行、不成立 → 別問題の確証)**: rover=centipede
  CDFX (~22km baseline)、base=ntripcaster `/VRS_PARIS` で `rtkrcv -s` 起動、
  14 分間観測。**858 epoch 全 Q=5 (single point), ratio=0.0** で LAMBDA 試行
  すらなし。

  これは Phase 7-3.5 修正の問題ではなく、**Phase 5b/6a の VRS+FKP 設計の
  根本問題が露呈**:
  - VRS の inject 1005 は rover 近傍 (48.72, 2.28) を申告
  - MSM7 観測値は元 CROI 物理基準局のもの、ref_id だけ書き換え
  - `applyPhaseCorrection` は empty deltas で no-op (Phase 6a 全 PRN 棄却)
  - → rtkrcv が DD 計算するときに「VRS_center で取れた MSM7」と解釈するが
    実は CROI 位置の観測 → DD 残差に km scale baseline 差が乗る → ratio
    test 通らず → fix 立たず

  この結果は **Phase 7-4 (LAMBDA) + Phase 7-5 (runtime 配線) の論理的必然性
  を改めて確認**するもの。Phase 7-5 で computeFkpDd 出力を applyPhaseCorrection
  delta に流せば、rover には「VRS_center 位置で取れた仮想観測値」が届き、
  DD 残差が cm scale になって LAMBDA fix 可能になる見込み。

新規 build: macOS arm64 で RTKLIB の app/{rtkrcv,str2str,convbin}/gcc/makefile を
`-std=gnu99 -D_DARWIN_C_SOURCE` で patch + `LDLIBS=-lm -lpthread` で build 成功
(/tmp/rtklib-build/ に配置、commit 対象外)。

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
(Original C source kept at this point under `/legacy/`; later removed
from the working tree — see git history through commit 753253f.)

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

Original source was archived under `/legacy/` until commit 753253f;
fetch from git history if needed.
