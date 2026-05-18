# MSM7 fine_phase Scale 検証 — Phase 7-4 領域 2 調査結果

## 1. エグゼクティブサマリ

**結論: 現実装 `src/fkp/msm7.zig` には 2 つの独立したバグがある。**

| # | バグ | 影響度 | 修正規模 |
| --- | --- | --- | --- |
| **B1** | MSM7 fine_phase の scale が `2^-29 ms` になっている (正: `2^-31 ms`) | 全 phase_m が **factor 4 で大きく出る** | 2 行 (extract + apply) |
| **B2** | MSM7 signal data block の bit layout が **cell-major** (80 bit × ncell) になっているが、RTCM 10403.3 spec / RTKLIB は **field-major** (20×ncell, 24×ncell, …) | real-world MSM7 ストリームから正しい phase を全く取り出せていない可能性大 | 中〜大 (extract + apply の signal data ループ全体書き換え) |

- 既存の `tests/test_fkp.zig` は writer / reader 両方が同じ間違った layout & scale を採用しているため、**バグを検出できない自己充足テスト**になっている。
- 修正には RTKLIB `decode_msm7` と同じ field-major レイアウトへの全面書き換えが必須。scale だけ直しても上流の real MSM7 frame からの値は依然デタラメ。
- Phase 5b-3 で観測された rover 補正値の clamp ヒットは B1 単独でも factor 4 ずれ、B2 と合わさってさらにランダム化していたと推定。
- ただし scale 単独の修正は **仕様確証あり** (RTKLIB ソースで確認済)、layout 修正にも仕様確証あり (RTKLIB encoder と decoder の両方を確認済)。

> ⚠️ 本調査は **公式 RTCM 10403.3 PDF が手に入らない** 環境下で行った。
> 根拠は RTKLIB 公式ソース (PocketSDR 同梱版 `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3.c`, `rtcm3e.c`) のみ。
> RTKLIB は GNSS 業界で de facto reference 実装なので信頼性は十分高いが、
> 万一に備えて修正コミット前に RTCM 公式 PDF (たとえば NovAtel/Trimble manual の MSM 抜粋) で
> ダブルチェックすることを推奨する。

---

## 2. DF401 仕様抜粋 (RTKLIB 経由)

RTCM 10403.3 § 3.5.16 / Table 3.5-78〜81 (MSM Signal Data) は MSM4/5 (compact)
と MSM6/7 (extended/high-resolution) で fine fields の bit 数と scale が異なる。

### 2.1 MSM4 / MSM5 (compact, 22 bit fine phase)

| Field | bits | scale |  invalid sentinel |
| --- | ---: | --- | --- |
| Fine PseudoRange | 15 (signed) | `2^-24 ms` | `-16384` |
| Fine PhaseRange (DF401) | **22 (signed)** | **`2^-29 ms`** | `-2097152` (= -2^21) |
| Lock time | 4 (unsigned) | — | — |
| Half-cycle ambiguity | 1 | — | — |
| CNR | 6 (unsigned) | `1.0 dB-Hz` | — |

### 2.2 MSM6 / MSM7 (extended, 24 bit fine phase)

| Field | bits | scale | invalid sentinel |
| --- | ---: | --- | --- |
| Fine PseudoRange (extended) | 20 (signed) | `2^-29 ms` | `-524288` (= -2^19) |
| **Fine PhaseRange (extended, DF406)** | **24 (signed)** | **`2^-31 ms`** | **`-8388608` (= -2^23)** |
| Lock time (extended) | 10 (unsigned) | — | — |
| Half-cycle ambiguity | 1 | — | — |
| CNR (extended) | 10 (unsigned) | `0.0625 dB-Hz` | — |
| Fine Phase-Range Rate | 15 (signed, MSM5/7 only) | `0.0001 m/s` | `-16384` |

合計 80 bit / cell (MSM7), 65 bit / cell (MSM6), 63 bit / cell (MSM5).

**現実装は 24 bit signed の MSM7/MSM6 fine_phase に対して、MSM4/5 用の
2^-29 scale を当てている**。これが Bug B1 の本質。

数値感覚: 24 bit signed range は ±8,388,607 → 2^-31 ms 換算で
±3,906 m → fine_phase は ±1171.0 m 相当 (RTKLIB encode_msm_phrng_ex で
`fabs(phrng[j])>1171.0` チェック有り)。これに対して 2^-29 を当てると
±15,624 m 相当 (= 1171 × 4) と勘違いされる。

---

## 3. RTKLIB decode_msm7 と現実装の比較表

参照: `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3.c` lines 2381–2446。

### 3.1 Field/Scale 比較

| Field | bits | RTKLIB | Zig 現実装 (msm7.zig) | 一致? |
| --- | ---: | --- | --- | :---: |
| rough_int (range integer ms) | 8 | `r[j] = rng * RANGE_MS` | `rough_int[i]`, `rough_ms = rough_int + rough_mod/1024` | ✅ |
| extended sat info | 4 | `ex[j] = …` | `br.skip(4)` (捨てる) | ✅ (機能等価) |
| rough_mod (modulo 1ms) | 10 | `r[j] += rng_m * P2_10 * RANGE_MS` | 同上 (1/1024 = `P2_10`) | ✅ |
| rough phaserange rate | 14 | `rr[j] = rate * 1.0` | `br.skip(14)` (捨てる) | ⚠️ (機能等価) |
| Fine PseudoRange | 20 | `pr[j] = prv * P2_29 * RANGE_MS` | `br.readS(20)` で読むが値は捨てる | ⚠️ (decode 対象外) |
| **Fine PhaseRange** | **24** | **`cp[j] = cpv * P2_31 * RANGE_MS`** | **`fine_ms = fine_phase * 2^-29`** | **❌ Bug B1** |
| invalid sentinel | — | `cpv == -8388608` | `fine_phase == -(1 << 23)` (= -8388608) | ✅ |
| Lock time | 10 | `lock[j] = getbitu(10)` | `lock_time_indicator: u16` | ✅ |
| Half-cycle | 1 | `half[j] = getbitu(1)` | `br.skip(1)` | ✅ (機能等価) |
| CNR | 10 | `cnr[j] = getbitu(10) * 0.0625` | `cnr_raw * 0.0625` | ✅ |
| Fine phase-range rate | 15 | `rrf[j] = rrv * 0.0001` | `br.skip(15)` | ✅ (機能等価) |

### 3.2 Bit Layout 比較 (signal data block, ncell cells)

RTKLIB / RTCM 10403.3 § 3.5.16 は **field-major** (transpose). Zig 現実装は
**cell-major** (block per cell)。これが Bug B2。

RTKLIB (rtcm3.c L2419–2440, encoder rtcm3e.c L2513–2519 で対称):
```
[pseudo×ncell (20·ncell bit)]
[phase×ncell  (24·ncell bit)]
[lock×ncell   (10·ncell bit)]
[half×ncell   ( 1·ncell bit)]
[cnr×ncell    (10·ncell bit)]
[rate×ncell   (15·ncell bit)]
                              合計 80·ncell bit
```

Zig 現実装 (msm7.zig L214–253):
```
cell 0: [20][24][10][1][10][15] = 80 bit
cell 1: [20][24][10][1][10][15] = 80 bit
…
cell ncell-1: 同上
                              合計 80·ncell bit
```

両者の総 bit 数は一致するが、**ncell ≥ 2 のときに各 field の位置が完全に
異なる**。同じ問題は satellite data block (L200–205 vs RTKLIB L2398–2418) でも
発生している:
- RTKLIB: `rng[]×nsat` → `info[]×nsat` → `rng_mod[]×nsat` → `rate[]×nsat`
- Zig: `[rng][info][rng_mod][rate]` × nsat (per-sat block)

ncell=1 or nsat=1 のときだけ偶然一致する。

### 3.3 RTKLIB encoder 側 (rtcm3e.c) でも layout 一致を確認

`encode_msm7` (rtcm3e.c L2493–2522) → `encode_msm_int_rrng`,
`encode_msm_info`, `encode_msm_mod_rrng`, `encode_msm_rrate` (各 nsat ループで
全衛星まとめて書く); `encode_msm_psrng_ex`, `encode_msm_phrng_ex` 等 (各
ncell ループで全 cell まとめて書く) — つまり **encoder も field-major**。
Zig 側の writeMsm7TestHeader+8-line cell loop はこの仕様と非互換。

### 3.4 RTKLIB の scale macro 確認

`/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtklib.h` L509–511:
```c
#define P2_29       1.862645149230957E-09 /* 2^-29 */
#define P2_30       9.313225746154785E-10 /* 2^-30 */
#define P2_31       4.656612873077393E-10 /* 2^-31 */
```
- MSM4/5 (22 bit fine_phase): `cp[j] = cpv * P2_29 * RANGE_MS`
- MSM6/7 (24 bit fine_phase): `cp[j] = cpv * P2_31 * RANGE_MS`

`RANGE_MS = CLIGHT * 0.001 = 299792.458` (rtcm3.c L57)。
従って MSM7 では `phase_m = cpv * 2^-31 * c * 1e-3` [m]。

Zig は `phase_m = cpv * 2^-29 * c * 1e-3` を計算しているので **factor 4 大きい**。

---

## 4. 数値検証

### 4.1 同一 payload での比較 (理論)

invalid sentinel `cpv = -8388608` は両者一致 (24 bit signed の最小値)。
それ以外の値で:

| cpv (24 bit signed) | RTKLIB (`cpv·P2_31·RANGE_MS`) [m] | Zig 現実装 (`cpv·2^-29·c·1e-3`) [m] | 比 |
| ---: | ---: | ---: | ---: |
| +1 | 1.397e-4 | 5.588e-4 | 4× |
| +1,000,000 | 139.66 | 558.65 | 4× |
| +8,388,607 (max) | 1171.0 | 4684.0 | 4× |

→ 単純に factor 4 オーバー。fine_phase max が ±1171 m ということは
**搬送波 1 cycle 単位ではなく ms 単位の細粒度補正値であって、波長 λ ≈ 0.19 m
の **6000+ 波長分** の幅** を取れる (= 完全な phase ambiguity を吸収可能)。

### 4.2 実 RTCM3 dump での突き合わせ

`/Users/yasu/Project/ntripcaster/` 配下を find したが `.bin/.raw/.pcap/.ubx`
ファイルは存在せず、conf 以外の binary dump は無い:
```
/Users/yasu/Project/ntripcaster/conf/sourcetable.dat   (NTRIP sourcetable text)
（他: なし）
```

→ **本検証では実機 MSM7 frame を Zig と RTKLIB の両方でデコードする
クロスチェックは未実施**。Phase 5b-3 の logs/ にも該当 dump が保存されて
いない (logs/ は空)。

**推奨**: Phase 7-4 着手前に 1 つ MSM7 frame を centipede-paris / rtk2go から
キャプチャし、RTKLIB CLI (`rtkrcv` or `convbin`) で同 frame の phase_m を
出して値突き合わせを実施。修正後実装と一致 (mm 以下の誤差) すれば
最終確証となる。

### 4.3 phase_m 値域の現実性チェック

GPS L1/L2 の 1 way pseudorange は 20–26 Mm (= 20,000,000–26,000,000 m)。
搬送波位相 (m 単位) も同じスケール (ρ + N·λ で N が整数アンビギュイティ)。

- rough_int 8 bit (0..255 ms) × c·1e-3 = 0..76,447,576 m。OK。
- rough_mod 10 bit (0..1023 / 1024 ms) × c·1e-3 ≈ ±299 km。OK (rough_int との
  和で連続性確保)。
- fine_phase 24 bit signed × **2^-31 ms** × c·1e-3 = ±1171 m。これは
  rough との **接続性誤差** を吸収する範囲で妥当 (≪ 衛星距離)。
- fine_phase 24 bit signed × **2^-29 ms** (Zig 現実装) × c·1e-3 = ±4684 m。
  これは「rough のあとに ±4684 m の調整」になり、隣接 cell との
  整合がとれず **±4 倍の発散** をする → Phase 5b-3 で観測された
  clamp ヒット / RTK fix 失敗の主因と整合。

「73,000,000 m スケールの phase_m が現実値か」については rough_int = 244
あたり (∼243 ms ≈ 73 Mm 相当) でちょうどその値域。L1/L2 ともに
synchronous 観測なら自然な値。Bug B1 修正後も rough 部分は変わらないので
phase_m の桁は ∼20-76 Mm 範囲のままで OK。

---

## 5. MSM7 cell データの構造 (公式 vs 現実装)

### 5.1 公式 (RTCM 10403.3 § 3.5.16, RTKLIB 一致)

```
─ satellite data (each field repeats nsat times) ──
[ rng_int ×nsat ] 8·nsat bit
[ info    ×nsat ] 4·nsat bit
[ rng_mod ×nsat ] 10·nsat bit
[ rrate   ×nsat ] 14·nsat bit
─ signal data (each field repeats ncell times) ────
[ psrng_ex ×ncell ] 20·ncell bit  scale 2^-29 ms
[ phrng_ex ×ncell ] 24·ncell bit  scale 2^-31 ms  ← DF406 in MSM7
[ lock_ex  ×ncell ] 10·ncell bit
[ half     ×ncell ]  1·ncell bit
[ cnr_ex   ×ncell ] 10·ncell bit  scale 0.0625 dB-Hz
[ rate     ×ncell ] 15·ncell bit  scale 0.0001 m/s
─────────────────────────────────────────────────
total: nsat·36 + ncell·80 bit
```

### 5.2 現実装 (Zig msm7.zig)

```
─ satellite data (per-sat 36 bit block × nsat) ────
for i in 0..nsat:
    [ rng_int 8 | info 4 | rng_mod 10 | rrate 14 ] = 36 bit
─ signal data (per-cell 80 bit block × ncell) ─────
for cell in 0..ncell:
    [ psrng_ex 20 | phrng_ex 24 | lock 10 | half 1 | cnr 10 | rate 15 ] = 80 bit
─────────────────────────────────────────────────
total: nsat·36 + ncell·80 bit  (同じ)
```

総 bit 数は一致するため CRC は通過する (frame structure validity 観点では
壊れない)。しかし RTKLIB / NovAtel / u-blox / Trimble など spec 準拠 receiver
の出力する MSM7 とは **interchange できない**。

---

## 6. 修正 patch (proposed)

### 6.1 B1 のみの最小修正 (B2 は別タスク)

> ⚠️ B2 未修正のままだと、real-world MSM7 受信時の挙動は依然デタラメ。
> B1 のみ修正は **テストデータ自作の世界 (test_fkp.zig 内の閉じた roundtrip)** で
> しか効かないので、production fix としては不十分。

`src/fkp/msm7.zig` の 2 箇所:

```zig
// extractPhase (L235–236)
// before:
// fine_phase 解像度: 2^-29 ms
const fine_ms: f64 = @as(f64, @floatFromInt(fine_phase)) * (1.0 / @as(f64, 1 << 29));
// after:
// MSM7 (24 bit signed) fine_phase 解像度: 2^-31 ms (RTKLIB rtcm3.c::decode_msm7)
const fine_ms: f64 = @as(f64, @floatFromInt(fine_phase)) * (1.0 / @as(f64, 1 << 31));
```

```zig
// applyPhaseCorrection (L382–388)
// before:
const fine_ms_cur: f64 = @as(f64, @floatFromInt(fine_phase)) *
    (1.0 / @as(f64, 1 << 29));
// (… delta 加算 …)
var new_fine_bits: i64 = @intFromFloat(@round(fine_ms_new * @as(f64, 1 << 29)));
// after:
const fine_ms_cur: f64 = @as(f64, @floatFromInt(fine_phase)) *
    (1.0 / @as(f64, 1 << 31));
// (… delta 加算 …)
var new_fine_bits: i64 = @intFromFloat(@round(fine_ms_new * @as(f64, 1 << 31)));
```

`tests/test_fkp.zig` L481 の `expectedPhaseM` も同期して 1<<31 に直す必要あり
(これも書き換え対象、~1 行)。

### 6.2 B2 (layout) 修正の概要

extract / apply 両方で:

1. cell ループの外側で `cell_valid[ncell]` を構築 (現状通り)。
2. `valid_cells: [128]usize` (cell_idx の昇順リスト) を構築。
3. signal data 6 つの field それぞれを **field ごとに `ncell` 回ループ** で
   読み書きする (RTKLIB と同じ順序)。
4. apply 側は fine_phase block の bit offset を「field 2 (phrng_ex) の j 番目」
   として計算: `i_phrng_start + (j-th valid cell relative index) × 24`。

`bits.zig::writeBitsAt` はすでにあるので使い回し可。
変更規模は extract 〜30 行、apply 〜50 行の書き換え。

### 6.3 推奨着手順

1. **証拠固め**: real centipede MSM7 frame を 1 つキャプチャ → RTKLIB
   `convbin -r rtcm3` で RINEX を出して L1 carrier phase の絶対値を控える。
2. B1 + B2 を同時修正 (片方だけだと test_fkp.zig が崩れる)。
3. テスト書き換え: test_fkp.zig の MSM7 frame builder を field-major に修正
   し、新 `expectedPhaseM` で 2^-31 を使う。
4. 1 で取った real frame を embed して RTKLIB と phase_m が ≤ 1 mm 一致
   することを assert する acceptance test を追加。
5. Phase 5b-3 のログでクランプヒット消失を確認。

---

## 7. 未解決事項

| # | 事項 | 状態 |
| --- | --- | --- |
| U1 | RTCM 10403.3 公式 PDF を直接参照していない | RTKLIB ソース (Tomoji Takasu, de facto reference) で代替済。NovAtel/Trimble manual で再検証推奨。 |
| U2 | 実 MSM7 dump との binary-level クロスデコード未実施 | logs/ にも dump 無し。Phase 7-4 着手前に取得すべき。 |
| U3 | Bug B2 (cell-major layout) が現状の Phase 5a 動作とどう整合するか | Phase 5a は header (ref_id) しか触らず signal data はそのまま forward しているため動作している。B2 は extract/apply の二者間で完結しており、forward 経路には影響しないことを確認済。 |
| U4 | MSM4/5 (22 bit fine_phase, 2^-29 ms) を将来サポートするか | 現状 1077/1087/1097 (MSM7) のみ。MSM4/5 のスケールは元コメント「fine_phase 解像度: 2^-29 ms」が混入した原因の可能性 (MSM4/5 と MSM7 を混同?)。 |
| U5 | 修正後の clamp ヒット数低減を測定する手段 | Phase 7-3 で `computeFkpDd` のロギングをすでに装備済なら、修正前後の差分で B1+B2 fix の効果を計測可能。 |
| U6 | epheneris.zig の `POW2_M29` は無関係 | `cuc/cus/cic/cis` (harmonic correction) の 16 bit signed × 2^-29 rad で RTKLIB と一致 (rtcm3.c L775,781 等) ので問題なし。 |

---

## 8. 参照ソース

- `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3.c`
  - L57: `RANGE_MS = CLIGHT * 0.001`
  - L2381–2446: `decode_msm7` (本検証の主要根拠)
  - L2328–2378: `decode_msm6` (同じ 24 bit × P2_31 を使用)
  - L2261–2325: `decode_msm5` (22 bit × P2_29、MSM4/5 の compact 版)
  - L2208–2258: `decode_msm4`
- `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3e.c`
  - L2101–2253: `encode_msm_*` 群 (field-major encoder)
  - L2249: `phrng_val = ROUND(phrng[j]/RANGE_MS/P2_31)` (MSM7 phrng encoder)
  - L2493–2522: `encode_msm7`
- `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtklib.h`
  - L509–511: `P2_29`, `P2_30`, `P2_31` macro 定義
- `/Users/yasu/Project/ntripcaster/src/fkp/msm7.zig`
  - L235–236: B1 (extractPhase の scale)
  - L382–388: B1 (applyPhaseCorrection の scale)
  - L207–253: B2 (extractPhase の cell-major layout)
  - L355–401: B2 (applyPhaseCorrection の cell-major layout)
- `/Users/yasu/Project/ntripcaster/tests/test_fkp.zig`
  - L481: 同じ scale バグを共有する self-consistent な `expectedPhaseM`
  - L530–539, L583–593: テストデータ生成側も cell-major で書いている

---

## 9. Phase 7-4 へのインプリケーション

- Phase 7-4 (LAMBDA / 整数アンビギュイティ) は **DD-N·λ** を扱う。N は
  整数, λ ≈ 0.19 m なので 1 cycle = 0.19 m。
- 現実装の factor 4 ずれは N に対して **~4× の偽値** を生む。MLAMBDA で
  search してもまったく fix できない (ratio test が常に 1.0 近辺で fail)。
- → **Bug B1 (+ B2) を Phase 7-4 着手前に必ず修正すること**。
- Phase 5b-3 で観測された rover の RTK fix 失敗、補正値の clamp ヒットは
  factor 4 + layout 混乱で説明できる。
- 修正後は Phase 7-3 の `computeFkpDd` が現実的な mm-scale 残差を返すように
  なり、Phase 7-4 LAMBDA が機能する前提が整う。
