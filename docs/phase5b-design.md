# Phase 5b 設計メモ — MSM7 encoder + FKP 補正適用

Phase 5a (`ref_id` 書き換え) 完了時点の続き。本フェーズの目的は **upstream
の MSM7 phase observation を rover 位置に補正して再エンコード**し、本物の
VRS として位置精度を改善すること。

Phase 4c で MSM7 エンコーダ未実装のため Phase 5 に持ち越したやつ。

---

## 1. RTCM3 MSM7 ペイロード bit レイアウト (再掲)

RTCM 10403.3 / Table 3.5-78 (Header) + Table 3.5-83 (MSM7 = MSM type 7
= satellite + signal + lock time + half-cycle + CNR + Doppler、最大精度)。

### 1.1 ヘッダー (固定長 169 bit = 21 byte ちょい、ただし境界跨ぎ)

| field                      | bits  | 備考                                     |
| -------------------------- | ----- | ---------------------------------------- |
| DF002 Message Number       | 12    | 1077 (GPS) / 1087 (GLO) / 1097 (Gal) ... |
| DF003 Reference Station ID | 12    | **Phase 5a で 0x800+rover.id に書換済** |
| GNSS Epoch Time            | 30    | GPS: TOW [ms], GLO: tk, Gal: TOW         |
| DF393 Multiple Message Bit | 1     | 1=後続あり、0=このエポック最後           |
| DF409 IODS                 | 3     | issue of data station                    |
| Reserved                   | 7     | 全 0                                     |
| DF411 Clock Steering Ind   | 2     |                                          |
| DF412 External Clock Ind   | 2     |                                          |
| DF417 GNSS Smoothing Ind   | 1     | 0=未平滑、1=平滑                         |
| DF418 GNSS Smoothing Intvl | 3     |                                          |
| **DF394 Satellite mask**   | **64**| bit63=PRN1, bit62=PRN2, ..., bit0=PRN64  |
| **DF395 Signal mask**      | **32**| bit31=SigID1, ..., bit0=SigID32          |
| DF396 Cell mask            | Nsat*Nsig | 各 (sat,sig) 組み合わせの有効性。      |
|                            |       | bit ordering: sat0×sig0, sat0×sig1, ...  |

合計: 12+12+30+1+3+7+2+2+1+3 + 64+32 + Ncell = **169 + Ncell** bits

### 1.2 衛星データブロック (Nsat × 36 bit, MSM7)

| field                | bits | 備考                                     |
| -------------------- | ---- | ---------------------------------------- |
| DF397 Rough Range ms (整数部) | 8    | 0..254、255=invalid               |
| DF419 Extended Sat Info | 4    | GLO で channel number、他は 0          |
| DF398 Rough Range ms (小数部) | 10   | 単位 2^-10 ms                       |
| DF399 Rough Range Rate | 14   | signed、単位 1 m/s、-8191=invalid    |

= 36 bit/sat。**MSM4/5 は 18 bit/sat (no rate, smaller fields)**、MSM7 はフル。

### 1.3 シグナルデータブロック (Ncell × 80 bit, MSM7)

| field                          | bits | 単位/解像度                   |
| ------------------------------ | ---- | ----------------------------- |
| DF405 Fine Pseudorange (ext)   | 20   | signed, 2^-29 ms              |
| **DF406 Fine PhaseRange (ext)**| **24** | signed, 2^-31 ms (= 約 0.0001 mm) |
|                                |      | -2^23 = invalid (extractPhase 確認済) |
| DF407 Lock Time Indicator (ext)| 10   | 0..1023                       |
| DF420 Half-Cycle Ambig         | 1    | 1=ambiguous, 0=resolved       |
| DF408 CNR (ext)                | 10   | 0..1023 dB-Hz × 1/16          |
| DF404 Fine PhaseRange Rate     | 15   | signed, 0.0001 m/s            |

= 80 bit/cell (cell_valid=true のセルのみ存在? 全 cell 分書く? **要確認**)。

**注**: MSM 仕様の cell_mask は「該当 cell の signal data が存在するか」を
示す。`cell_valid[i] == false` の cell は signal data block を **持たない**。
extractPhase は全 cell 分 br.readS/skip しているが、これは **バグの可能性**
あり (cell_valid=false の cell を skip してしまっている)。Phase 5b で
roundtrip テストするときに発覚するはず。

→ 要検証: RTCM 10403.3 Section 3.5.16.3.5 を確認。「Signal Data Block
size depends on number of valid signals」とある場合、cell_valid のみ存在。

### 1.4 ペイロード総 bit 数

```
total_bits = 169 + Ncell + Nsat*36 + Ncell_valid*80
```

例 (GPS MSM7, Nsat=10, Nsig=2 = 全部 valid):
- Ncell = 20, Ncell_valid = 20
- total = 169 + 20 + 360 + 1600 = 2149 bit = **268.625 byte → 269 byte**
- frame_len = 3 + 269 + 3 = 275 byte

最大 (Nsat=20, Nsig=4 = 80 cell):
- total = 169 + 80 + 720 + 6400 = 7369 bit = 921 byte (RTCM3 length max 1023 を超えない)

---

## 2. extractPhase の挙動 vs encodeMsm7 の責務

### 2.1 extractPhase が捨てている情報

`src/fkp/msm7.zig::extractPhase` は **phase 観測値のみ抽出** で、以下を捨てる:

- `epoch_time` (30 bit): 補正後の MSM7 は元のエポック値を保持する必要あり
- `multi_msg / IODS / reserved / clock_steering / smoothing` 等のヘッダー
  フラグ群 (合計 21 bit)
- `extended_sat_info` (Nsat × 4 bit): GLO の channel 番号など
- `rough_phase_range_rate` (Nsat × 14 bit): Doppler 計算用
- `fine_pseudorange` (Ncell × 20 bit): 擬似距離 (こいつも本来補正必要)
- `lock_time / half_cycle / CNR / fine_phase_rate` (Ncell × 36 bit)

→ encoder 側は **元のペイロードを保持しつつ phase だけ書き換える** 方針
が現実的。すなわち extractPhase を「parse 全部 → 構造体に保存」に拡張する
よりも、**in-place 書き換え** で済ませる。

### 2.2 encoder の API デザイン (案)

```zig
/// MSM7 ペイロードの phase 観測値だけ補正値で in-place 書き換えて
/// CRC を再計算する。frame は RTCM3 1 フレーム全体 (preamble..CRC)。
/// `phase_delta` は (PRN, band) → 補正値 [m] のマップ。
/// 該当 cell が見つからない/無効な PRN は触らない。
pub fn applyPhaseCorrection(
    frame: []u8,
    phase_delta: PhaseDeltaMap,
) !void {
    // 1. parseMsm7Header で sat_mask, sig_mask, ncell を取得
    // 2. PRN リスト / sigID リスト構築
    // 3. cell_mask を読みつつ位置を進める
    // 4. 各 cell について:
    //    - rough_int, rough_mod を sat[si] から読む
    //    - fine_phase を読む
    //    - PhaseDeltaMap[prn, band] が存在すれば:
    //        new_phase_m = current + delta
    //        new_fine_phase_bits = encodeFineFromMeters(new_phase_m, rough)
    //        writeBitsAtOffset(payload, fine_phase_offset, 24, new_fine_phase_bits)
    // 5. CRC-24Q 再計算
}
```

**ポイント**: BitReader/BitWriter ではなく **bit offset を覚えて payload を
直接書き換える** ヘルパーが必要。現状の bits.zig には writeBitsAt が無いので
追加する (~30 行)。

### 2.3 alternative API: 完全な struct 経由

もう一つの設計案: MSM7 を struct に parse → 補正 → struct から encode。

```zig
pub const Msm7Frame = struct {
    header: Msm7Header,
    sat_data: [64]Msm7SatData,    // rough_int, rough_mod, ...
    sig_data: [128]Msm7SigData,   // fine_pseudo, fine_phase, ...
    cell_valid: [128]bool,
};

pub fn parseMsm7Frame(payload) ?Msm7Frame;
pub fn encodeMsm7Frame(allocator, frame: Msm7Frame) ![]u8;
```

メリット: テストしやすい、補正以外の改変も柔軟。
デメリット: ~200 行追加、struct サイズ大きい (~5 KB)、stack 注意。

→ **推奨は in-place 書き換え** (案 2.2)。シンプル + 1 メモリコピーで済む。

---

## 3. FKP 補正の数式

`docs/vrs-design.md` § Phase 4c より:

```
ΔΦ_rover = ΔΦ_master + N_I·dN + E_I·dE + (vertical_term)
```

`engine.computeFkp` の出力 `FkpParam` は (prn, n_i, e_i, n_0, e_0) を持つ。

- `n_i, e_i` [m/rad]: 電離層 FKP coefficient
- `n_0, e_0` [m/rad]: geometric FKP coefficient
- `dN, dE` [rad]: 主上流から rover までの北・東距離 (緯度経度差を弧度に変換)

簡易版補正:
```
delta_phase_m = (n_i + n_0) · dN + (e_i + e_0) · dE
new_phase = old_phase + delta_phase_m
```

主上流位置は `Upstream.coord` (1005 から parse 済) を使う。rover 位置は
`VrsRover.lat_deg/lon_deg/alt_m` から計算。

**衛星別の電離層補正は周波数依存** (L1 vs L2): `delta_L2 = (f_L1/f_L2)^2 · delta_L1`
ただし FKP の N_I/E_I は L1 基準なので、L2/L5 シグナルに適用する場合は係数
を掛ける必要あり。これは extractPhase の `freq_hz / band` 情報で判定可能。

---

## 4. roundtrip テスト設計

Phase 5b-1 の最低限の検証:

```zig
test "msm7: in-place phase correction roundtrip" {
    // 1. 既知の MSM7 frame (rtkbase 等からキャプチャ or 合成) を用意
    const orig_frame = ...;
    var frame_copy = orig_frame.dup();

    // 2. delta=0 の補正を適用 (= no-op だが CRC は再計算される)
    var deltas = PhaseDeltaMap{};  // empty
    try applyPhaseCorrection(frame_copy, deltas);

    // 3. parseFrame で CRC 通ること
    const fr = rtcm3.parseFrame(frame_copy) orelse return error.CrcFail;
    try testing.expectEqual(orig_frame.len, fr.consumed);

    // 4. extractPhase の出力が元と一致すること
    const orig_obs = try extractPhase(alloc, orig_frame[3..3+payload_len]);
    const new_obs  = try extractPhase(alloc, frame_copy[3..3+payload_len]);
    try testing.expectEqualSlices(PhaseObs, orig_obs, new_obs);
}

test "msm7: phase correction applies delta correctly" {
    // 1. PRN=1 / L1 に delta=+0.01m を指定
    // 2. applyPhaseCorrection
    // 3. extractPhase で PRN=1 / L1 の phase が +0.01m 増えていること
    // 4. PRN=1 / L2 や他の PRN は変わらないこと
}
```

サンプル MSM7 frame は `test_fkp.zig` 内で BitWriter で合成すれば充分。
リアルキャプチャは `tests/data/` 配下に置く案もあるが、まずは合成で。

---

## 5. forwardFiltered への組み込み (Phase 5b-3)

```zig
// 現状 (Phase 5a):
} else if (rtcmHasStationId(fr.msg_type)) {
    @memcpy(scratch[0..fr.consumed], buf[pos..pos+fr.consumed]);
    rewriteRefIdInFrame(scratch[0..fr.consumed], rover.vrs_ref_id);
    writer.writeAll(scratch[0..fr.consumed]) catch return error.WriteFailed;
    ...
}

// Phase 5b 後:
} else if (rtcmHasStationId(fr.msg_type)) {
    @memcpy(scratch[0..fr.consumed], buf[pos..pos+fr.consumed]);
    rewriteRefIdInFrame(scratch[0..fr.consumed], rover.vrs_ref_id);
    // MSM7 のみ phase 補正適用 (1077/1087/1097)
    if (isMsm7(fr.msg_type)) {
        // FKP runtime から最新の FkpParam スナップショットを取得
        const deltas = computePhaseDelta(rt, rover);
        applyPhaseCorrection(scratch[0..fr.consumed], deltas) catch {};
    }
    writer.writeAll(scratch[0..fr.consumed]) catch return error.WriteFailed;
    ...
}
```

**FKP スナップショット取得**: `runtime.zig::runOneFkpCycle` は arena に
FkpParam を生成して Type 59 をエンコードしてすぐ捨てる。Phase 5b-3 では
**最新の FkpParam を rt が保持**するように変更する必要あり (heap allocation
+ mutex 保護)。

---

## 6. 判断必要事項 / 課題

| # | 課題                                | 判断案 / メモ                         |
| - | ----------------------------------- | ------------------------------------- |
| 1 | cell_mask=false の cell に signal data はあるか? | 仕様再確認 (RTCM 10403.3 § 3.5.16.3.5)。extractPhase の skip 量がバグの可能性。 |
| 2 | L1 以外 (L2/L5) への FKP 補正係数の周波数換算 | `delta_L2 = (f_L1/f_L2)^2 · delta_L1` を適用。msm7.gpsFreqFromSigId() を使う。 |
| 3 | GLONASS の周波数 (FDMA, channel 依存) | extended_sat_info から channel 取り、`freq = 1602.0 + ch*0.5625 MHz` で計算。Phase 5b 初版は **GLONASS スキップ** で良いかも。 |
| 4 | fine_pseudorange の補正は必要か? | 第一歩は phase のみで OK (geometric な擬似距離変化は本来必要だが、RTK fix では phase が支配的)。 |
| 5 | rover が cell radius 外に出た場合 | Phase 4d で既に切断する実装あり。Phase 5b では追加の判定不要。 |
| 6 | epoch sync | 「主上流の MSM7 が到着した瞬間に補正適用」で良い (extractPhase の Msm7 が最新かはあまり気にしない、ms 単位は許容)。 |
| 7 | 補正適用エラー時のフォールバック | `applyPhaseCorrection` 失敗 → 補正なしの MSM7 を送る (= rover は upstream-equivalent の精度)。`frames_correction_failed` カウンタ追加。 |
| 8 | パフォーマンス | 1 フレーム/秒程度、PRN 数 ~20、サイズ ~300 byte。in-place 書き換え + CRC 再計算は < 100 µs オーダー。 |

---

## 7. 作業見積もり (次セッション)

- **5b-1: MSM7 encoder + roundtrip test** (`writeBitsAt` 追加 + `applyPhaseCorrection` 実装 + 4-6 件のテスト): **2-3 時間**
- **5b-2: FkpParam スナップショット保持** (`runtime.zig` に latest_fkp_params 追加 + thread-safe アクセス): **30 分**
- **5b-3: forwardFiltered 組み込み + 実機検証** (centipede.fr で位置精度測定): **1-2 時間**

合計 ~5 時間、本気で詰めれば 1 セッションで終わる規模。仕様確認 (課題 #1)
で詰まると数時間追加。

---

## 8. 次セッションでまず確認すること

1. RTCM 10403.3 § 3.5.16.3.5 (signal data block size) — extractPhase の
   `skip` パターンが正しいか
2. centipede 上流から実 MSM7 frame をキャプチャ → bit ごとに python で
   parse して構造確認 (`/tmp/vrs_5a.bin` あたりから取れる)
3. `engine.zig::computeFkp` の出力単位 (m/rad? m/m?) と LightSpeed/Lambda
   の使い方
