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

**Phase 5a: MSM7 / legacy obs / 1033 / 1230 の ref_id 書き換え (実装済)**:
- VRS 注入 1005 と upstream の MSM7 等が rover 側で同一 station として
  correlate するよう、station_id を持つメッセージ (1001..1012 / 1033 /
  1071..1077 / 1081..1087 / 1091..1097 / 1101..1107 / 1111..1117 /
  1121..1127 / 1131..1137 / 1230) の payload bits 12-23 を rover.vrs_ref_id
  に書き換え + CRC-24Q 再計算して forwardFiltered で送信。
- VrsRover に `vrs_ref_id` フィールド (12-bit, 0x800..0xFFF) を持たせ、
  inject1005 / inject1008 / MSM7 書き換えで共通使用 → rover は全メッセージ
  を単一基準局として認識。
- `frames_ref_id_rewritten` カウンタ + 切断時サマリに記録。
- 実機検証 (centipede.fr, 25 秒): rover 側で全 station_id 持ちフレーム
  (1004/1012/1033/1077/1087/1097/1107/1127) が ref_id=0x801 に揃った
  ことを python decoder で確認。ephemeris (1019/1020/1042/1045/1046) は
  station_id 持たないので透過。

**Phase 5b 設計メモ作成 (`docs/phase5b-design.md`)**:
- RTCM3 MSM7 ペイロード bit レイアウト (header / sat data / signal data)
  を整理 + extractPhase が捨てている情報の特定。
- `applyPhaseCorrection(frame, phase_delta)` の in-place 書き換え API 案
  を提示 (struct 経由案も比較)。完全 parse → 補正 → 完全 encode より
  軽量で、メモリコピー 1 回 + CRC 再計算で済む。
- 補正数式 (Phase 4c 設計から再掲): `ΔΦ_rover = ΔΦ_master + N_I·dN + E_I·dE`、
  L2/L5 周波数依存補正の扱い、GLONASS FDMA の channel 計算メモ。
- roundtrip テスト設計 + forwardFiltered への組み込み点。
- 残課題 8 件 (cell_mask=false の signal data 有無 / FkpParam スナップ
  ショット保持 / 補正失敗時のフォールバック等) を表で列挙。
- 作業見積もり: 5b-1 (encoder+test) 2-3h、5b-2 (FKP snapshot) 30m、5b-3
  (実機検証) 1-2h → 合計 ~5h で次セッション 1 本で完結見込み。

**Phase 5b-0: extractPhase の cell_mask=false bit offset bug 修正 (実装済)**:
- 設計メモ § 6 課題#1 で疑念を残していた cell_mask=false の cell の挙動を
  RTCM 10403.3 § 3.5.16 で確定: signal data block は cell_mask=1 の cell
  分のみ存在 (= ncell_valid 個)。MSM のサイズ削減仕様の中核。
- `src/fkp/msm7.zig::extractPhase` は `nsat × nsig` 個 (= ncell) の 80-bit
  signal data block を読んでいたため、部分 cell_mask (ある衛星だけ L1 のみ等)
  では invalid cell の 80 bit を読み飛ばして後続 valid cell の phase 値が
  前後ズレ → FKP 計算入力も汚染。cell_mask 全 1 (rtk2go / centipede の
  典型局) では実害なかったため Phase 4 まで気付かれず。
- 修正は `if (!cell_valid[cell_idx]) continue;` を readS の前へ移動する
  1 行差分 (`valid` ローカルは削除)。Phase 5b-1 の `applyPhaseCorrection`
  が正確な bit offset 計算を要するための前提整備。
- `tests/test_fkp.zig`: 合成 MSM7 frame で 2 件のテスト追加 — 全 valid (6
  cell, regression) と部分 valid (4 cell, 修正の核心)。distinct な
  fine_phase 値で bit offset 整合性を 0.1 mm 精度で検出。

**Phase 5b-1: applyPhaseCorrection (MSM7 in-place 補正) 実装 (実装済)**:
- `src/fkp/bits.zig`: `writeBitsAt(data, bit_offset, n, value)` ヘルパー追加。
  BitWriter とは別に、任意の bit offset 位置へ「クリア + 上書き」する
  ランダムアクセス書き込み (~20 行)。既存ビット保持と signed two's
  complement 書き込みの roundtrip テスト 3 件追加。
- `src/fkp/msm7.zig`: `applyPhaseCorrection(frame, deltas)` 追加。
  - 入力: 完全な RTCM3 frame (preamble..CRC) と `[]const PhaseDelta`
    (`{prn, band, delta_m}` の配列)。
  - 動作: MSM7 header / cell_mask / sat data を sequential 読み出し
    → 各 valid cell の signal data 開始 bit offset を `br.bitPos()` で
    記録 → fine_phase を読み、(PRN, band) が deltas にあれば
    `new_fine_phase = current + delta_m / (c*1e-3) * 2^29` を
    [-2^23+1, 2^23-1] にクランプして `writeBitsAt` で 24 bit 上書き
    → 全 cell 処理後 CRC-24Q を再計算して末尾 3 byte に書き戻し。
  - エラー: `InvalidFrame` (preamble/length/payload 不正) と `NotMsm7`
    (msg_type が 1077/1087/1097 以外)。
  - 設計判断: 完全 parse → 補正 → 再 encode の struct 経由案 (~200 行
    追加) ではなく、設計メモ § 2.2 推奨の **in-place 書き換え**。
    メモリコピー 1 回 + CRC 再計算で済む。
  - GPS L1/L2/L5 のみ対応 (`gpsBandFromSigId` が GPS table のため)。
    GLONASS/Galileo は band=unknown で no-op 透過 (Phase 5b 初版前提)。
  - rough_int==255 / fine_phase==-2^23 (invalid sentinel) の cell は
    補正対象から除外 (保守的)。
- `tests/test_fkp.zig`: 5 件追加 — empty deltas で frame byte-identical /
  PRN1/L1 に +0.01m delta で該当 cell のみ phase が増加 (他 5 cell は
  不変、1e-9 m 精度) / parseFrame で CRC 通る (post-write 整合) /
  truncated frame は `InvalidFrame` を返す / msg_type=1005 は `NotMsm7`。

**Phase 5b-2: FkpSnapshotStore (最新 FKP パラメータ保持) 実装 (実装済)**:
- `src/fkp/runtime.zig`: 新規 struct `FkpSnapshotStore` を追加。Mutex 保護の
  下で最新 FKP パラメータ (`[]engine.FkpParam`) と主上流座標
  (`msm7.StationCoord`) を heap 上に保持。
  - `update(fkp_params, ref_coord)`: allocator で copy 確保 → ロック取得 →
    既存があれば free → 新規をセット (writer はロック保持時間最小化)。
  - `snapshot(alloc)`: ロック下で caller 提供 allocator にコピーを返す。
    `?FkpSnapshot` (`{params, ref_coord}` + `deinit`)。未保存時 null。
- `Runtime` に `latest_fkp: FkpSnapshotStore` フィールドを追加。
  `runOneFkpCycle` で `computeFkp` 成功後 (Type 59 エンコード前) に
  `latest_fkp.update(fkp_params, stations.items[0].coord)` で更新。
  `destroy()` で `latest_fkp.deinit()`。convenience method
  `Runtime.snapshotFkp(alloc)` を追加。
- 設計: writer (FKP cycle スレッド) は 30 秒に 1 回程度の頻度、reader (VRS
  forward path) は MSM7 フレーム毎 (~1 Hz × N rovers)。allocator copy で
  独立性確保、Mutex 保持時間はメモリ確保中のみ。
- `tests/test_fkp.zig`: 3 件追加 — init 直後 null / update 後 snapshot で
  params + ref_coord 復元 (2 回連続 snapshot で独立 copy 確認) /
  2 回 update で前者 leak なし (testing.allocator が leak 検出に使用)。

**Phase 5b-3 配線部 (VrsRuntime ↔ FkpRuntime + forwardFiltered 組み込み) 実装済**:
- `src/fkp/vrs.zig`:
  - `Runtime` に `fkp_rt: ?*fkp_runtime.Runtime` フィールド追加。`Runtime.create`
    のシグネチャに `fkp_rt: ?*fkp_runtime.Runtime` 引数を追加。null のときは
    Phase 4 相当 (補正なし、ref_id 書き換えのみで素通し)。
  - `VrsRover` に `frames_phase_corrected` / `frames_correction_failed`
    カウンタ追加。rover 切断時のサマリログにも反映。
  - `computePhaseDelta(out, alloc, snap, rover_lat_rad, rover_lon_rad)`
    (pub): FKP snapshot + rover 位置から L1 phase delta を生成。
    `delta_m = (n_i + n_0)·dN + (e_i + e_0)·dE`。
  - `applyVrsPhaseCorrection(frame, rover, rt)`: arena alloc で snapshot
    取得 → rover lock 下で位置取得 → computePhaseDelta → applyPhaseCorrection。
    snapshot 未保存 / rover 位置未取得 / 補正エラーは
    `frames_correction_failed` を増やしてそのまま (Phase 5a 動作 fallback)。
  - `forwardFiltered` のシグネチャに `rt: ?*Runtime` を追加。
    `rtcmHasStationId` 分岐内で MSM7 (1077/1087/1097) のみ
    `applyVrsPhaseCorrection` を呼び出す。
- `src/main.zig`: `fkp_vrs.Runtime.create(allocator, &state, fkp_rt)` で
  fkp_rt を渡すように更新 (`fkp_rt` は同スコープで既に作成済み)。
- `tests/test_fkp.zig`: 3 件追加 — computePhaseDelta 1 PRN (期待値 0.002m
  に 1e-12 一致) / 多 PRN (2 entry, 各々の期待値検証) / end-to-end MSM7
  frame の補正 (PRN1 にのみ +0.0095 m delta、CRC parseFrame で通る、
  他 cell 不変)。
- 既存 vrs.zig 内 test 3 件のシグネチャを `forwardFiltered(..., null)` に更新。

**Phase 5b-3 実機検証 (docker 上 caster + python rover で完了)**:

ローカル macOS 26 で host Zig が link 通らないので、`ntripcaster-zig:0.15.2`
(linux/arm64) docker コンテナで `zig build -Doptimize=ReleaseSafe` してから
`conf/centipede-paris.conf` (CROI/IPGP/SGC + VRS_PARIS) で起動、Python rover
スクリプトで /VRS_PARIS に GGA 付き接続して 30 秒キャプチャ。`zig build test`
も docker 内で全通過 (exit=0、Phase 5b 追加 16 件含む)。

✅ **配線・整合性は完全動作**:
- caster 切断サマリ: `phase_corrected=67 corr_failed=0 ref_id_rewritten=196
  inject_1005=6` — applyPhaseCorrection が MSM7 67 frames に対して 0 失敗で
  適用、CRC 再計算も正常 (python decoder が全 frame parse 成功)。
- Phase 5a (ref_id 書き換え) は station_id 持ち全 198 frames が
  ref_id=0x801 (= 0x800 | rover_id) に揃って完璧。
- SBAS (1107) / BDS (1127) は band=.unknown で no-op 透過、設計通り
  (gpsBandFromSigId が GPS table のため)。

⚠️ **発見: 補正値の magnitude が物理的に大きすぎる (Phase 6 案件)**:

`/FKP_PARIS` (raw) と `/VRS_PARIS` (補正済) の同一 epoch diff を計測した結果、
fine_phase の差分が GPS で平均 730 mm、GLO で 1.6 m、Galileo で 320 mm。
fine_phase の値域 ±4.7 m を完全に超えて `[-2^23+1, 2^23-1]` クランプにヒット。
本来 50 km baseline での FKP 補正は mm-cm scale が物理的妥当範囲。

真因: `engine.zig::computeFkp` が田中 2003 § 4.3.4 そのままの実装で、
`lif = α·L1 − β·L2` は ionosphere-free だが geometry (衛星〜局の幾何距離、
km scale) が残ったまま。これを 3 局の lat/lon 差 (~0.001 rad) の inv で
割ると n_0/e_0 が数千〜数万 m/rad に膨らみ、rover offset ~0.013 rad を
掛けて数 100 m〜数 km の補正値になる。
本来は衛星 ephemeris から各局-衛星距離を引いた double-difference 残差を
入力にする必要があり (Tanaka § 4.3.2 の前提)、現実装はそのステップを
省いていた。

**結論**: Phase 5b の責務 (MSM7 補正適用の仕組み実装) は完了。位置精度
改善のためには別途 `engine.zig::computeFkp` の改修 (Phase 6 候補) で
geometric range removal を入れる必要あり。

**Phase 6 設計メモ作成 (`docs/phase6-design.md`)**:
- 課題の真因解析 (LIF が geometry を残したまま computeFkp に流れている
  Tanaka 2003 §4.3.2 の前提抜け) を整理。
- 修正アプローチを 3 案比較 + 段階導入 (6a/6b/Phase 7) を提案:
  - **6a (案 C)**: 閾値判定 (≈100 m/rad) で異常 FKP を棄却。2-3h で
    補正値暴走防止できる safety net。即着手推奨。
  - **6b (案 B)**: MSM7 内蔵 rough_range を近似 geometric range として
    引いた residual + double-difference + 簡易 ambiguity (初回 epoch
    fix)。~13h、10cm 級精度。本筋の改修。
  - **Phase 7 (案 A)**: フル ephemeris (1019/1020/1042/1045/1046) 解析 +
    衛星 ECEF + DD + LAMBDA で cm 級。~3 週間、将来オプション。
- 1019 (GPS Eph) の bit レイアウト表を参考に同梱。1020/1042/1045/1046 は
  RTCM 10403.3 参照ポインタのみ。
- 6b の SatObs 拡張 / DD 形成 / cycle slip 検出 (DF407 lock_time) の
  設計を具体化。次セッションで確認する事項 (閾値妥当性、rough_range の
  連続性、lock_time の取り出し) を 3 点リストで明記。

**Phase 6a: computeFkp 閾値判定で異常 FKP 棄却 (実装済)**:
- `src/fkp/engine.zig`:
  - `pub const DEFAULT_FKP_MAX_MAGNITUDE: f64 = 100.0;` — 50km baseline で
    1m 補正 (= 127 m/rad) の境界より下の経験値。
  - `ComputeOptions { max_magnitude, stats }` 構造体追加。`computeFkp` の
    シグネチャを `(alloc, stations, options)` に変更。`.{}` で標準動作、
    `.{ .max_magnitude = inf }` で旧動作 (=無制限) 互換。
  - `ComputeStats { dropped_excess }` 構造体追加。閾値超過で棄却した PRN
    数をオプショナル出力。
  - computeFkp ループ末尾で `max_abs(n_i, e_i, n_0, e_0) > max_magnitude`
    なら棄却 + stats.dropped_excess++、append しない。
- `src/fkp/runtime.zig`:
  - `Runtime` に `fkp_dropped_excess_total: u64` フィールド追加。
  - `runOneFkpCycle` で `var fkp_stats: ComputeStats = .{};` を確保して
    computeFkp に渡し、cycle ok log に `dropped_excess` と累計値を追加。
  - 全 PRN 棄却で `fkp_params.len == 0` のとき warn ログに excess 数を
    含める (singular matrix と区別できる)。
- `tools/fkp_demo.zig`: `computeFkp(allocator, &stations, .{})` に追従。
- `tests/test_fkp.zig`:
  - 既存 3 件の computeFkp 呼び出しを `.{}` または
    `.{ .max_magnitude = inf }` に更新 (古い regression test は閾値
    無効化で意図を保つ)。
  - 新規 3 件追加 — 過大入力で PRN 棄却 + stats.dropped_excess=1 /
    物理妥当入力で PRN 通過 + DEFAULT 閾値 100 以下 / 同入力でも
    `max_magnitude=0.1` の厳格閾値で棄却される。
- Phase 6a-4 微調整: `runtime.runOneFkpCycle` で computeFkp が 0 params を
  返した場合でも `latest_fkp.update(empty, ref_coord)` を呼ぶように変更。
  VRS 側で empty deltas → applyPhaseCorrection no-op success (CRC 再計算)
  → `frames_phase_corrected++` となり、設計メモ § 4.2 が意図した「設計通り
  no-op fallback」が `frames_correction_failed` に誤計上されない。
  `tests/test_fkp.zig` に "FkpSnapshotStore accepts empty params" 1 件追加。
- 動作: docker 内 `zig build test` 全通過 (exit=0)。
- 実機確認 (docker + centipede-paris.conf):
  - 起動後 FKP は毎 cycle `dropped_excess=8〜13` (= Paris triangle で
    生 LIF が全 PRN ともに閾値超過、設計メモ § 8-1 の予測値そのまま)
  - rover (python str2str 相当) 30s 接続切断サマリ:
    `frames_fwd=438 ref_id_rewritten=221 phase_corrected=92 corr_failed=0`
    — Phase 5a (ref_id 書き換え) は維持、補正は no-op fallback、失敗
    カウンタはゼロ。配線済みの Phase 5b-3 を破壊しない safety net として
    意図通り動作。

**Phase 6b-1/2/3: rough_range 配管 + residual 化 (中間実装)**:

phase6-fkp-residual ブランチ (master ← phase4-vrs マージ後に派生) で着手。
設計メモ § 5.1.1〜5.1.3 まで完了。

- `src/fkp/msm7.zig::PhaseObs` に `rough_range_m: f64` 追加。
  `extractPhase` 内で `(rough_int + rough_mod/1024) × c × 1e-3` から計算
  して各 PRN×band cell に格納。
- `src/fkp/engine.zig::SatObs` に `rough_l1_m: ?f64` / `rough_l2_m: ?f64`
  追加。`groupPhaseObs` で PhaseObs から伝搬。
- `SatObs.l1_residual()` / `l2_residual()` helper 追加 (`phase − rough`、
  片方 null なら null)。
- `computeFkp` の SD 計算を `obs_x.l1_residual() orelse continue` に置換。
  rough が未設定の SatObs (旧テスト / GLONASS 等で band 違い) は skip。
- 既存テストの SatObs 引数 12 個に `.rough_l1_m = 0, .rough_l2_m = 0` を
  追加 (residual = phase で旧挙動を保つ)。
- 新規テスト 4 件: extractPhase で rough_range_m が露出 / groupPhaseObs
  で SatObs に伝搬 / residual helper の null 安全 / residual mode で
  rough なし SatObs が skip される。

⚠️ **実機検証で発見**: 設計メモ § 2.2 の前提に重要な誤りあり。

MSM7 の `rough_int + rough_mod/1024` は **衛星-局の geometric range の
近似ではなく**、carrier phase 観測値そのものを 1/1024 ms 精度に量子化した
値。fine_phase は同じ観測値の細かい桁 (2^-29 ms) を表す encoding remainder
で、`phase_m = rough_range_m + fine_correction` は同一観測値の coarse +
fine 2 段表現に過ぎない。引いても geometric range は分離されず、残るのは
fine_phase × 2^-29 × c × 1e-3 ≈ ±4.7 m の **rounding noise** のみ。

実機確認 (docker centipede-paris, 30s rover): Phase 6a と同じく
`excess=13` 毎 cycle / rover summary `phase_corrected=90 corr_failed=0`。
Phase 6b-3 だけでは magnitude 問題は **改善しない**。

**真の解決には DD + ambiguity baseline が必須**: 設計メモ § 5.1.4 (DD で
station/sat clock 消去) + § 5.1.5 (初回 epoch DD = ambiguity baseline、
以降 `DD(t) − DD(t_0)` を residual に) で時間的 DD-差分 (cm-scale iono
変化) のみが残り、FKP が物理妥当に収まる仕組みになる。

設計メモ § 2.2 を訂正済み (`docs/phase6-design.md`)。

**Phase 6b 全体撤去 (2026-05-18 決定)**:

Phase 6b-3 の理論再分析と実機検証結果を踏まえ、案 B 全体を撤去し Phase 7
(ephemeris + DD + LAMBDA) に直行する判断を下した (詳細: `docs/phase6-design.md` § 9.1)。

撤去の根拠:
- residual = phase − rough_range は **rounding noise** (±4.7 m wrap、物理
  情報なし)。設計メモ § 2.2 の前提が誤読 (MSM7 spec § 3.5.16 解釈ミス)。
- 設計メモ § 5.1.4-5 の「DD + 時間差 baseline」は raw `phase_m` + 真の
  geometric range removal を前提とした構成。残差 noise に対して同じ構造を
  組んでも、入力が物理情報を持たないので出力も noise のまま。
- 真の geometric range removal は ephemeris ベースの衛星 ECEF 計算が必須で、
  これは Phase 7 (案 A) のスコープ。

撤去内容 (本 commit):
- `src/fkp/msm7.zig`: `PhaseObs.rough_range_m` フィールド削除 +
  extractPhase の rough_range_m 計算行を削除。
- `src/fkp/engine.zig`: `SatObs.rough_l1_m/rough_l2_m` + `l1_residual()` /
  `l2_residual()` helper 削除。`computeFkp` を raw `l1_m/l2_m` 直接参照に
  revert (Phase 5b/6a と同じ挙動)。閾値判定 (Phase 6a) は維持。
- `tests/test_fkp.zig`: Phase 6b 関連 test 4 件を削除 + 既存 SatObs literal
  12 個から `.rough_l1_m = 0, .rough_l2_m = 0` を除去。テスト件数は Phase
  6b-3 時点から -4 件で Phase 6a 完了時に戻る。
- `docs/phase6-design.md`: § 2.2 を「案 B 棄却」に書き換え、§ 5 全体に
  「撤去」マーカー追加、§ 9 に経緯と Phase 6a 暫定運用の説明を追加。

build/test 通過 (docker linux/arm64 ntripcaster-zig:0.15.2)。
Phase 6a 状態 (master/300bf5a 相当) に戻り、次は Phase 7 設計から着手。

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
