# Phase 6 設計メモ — FKP 補正値の物理妥当性確保 (geometric range removal)

Phase 5b の実機検証 (CHANGELOG `Phase 5b-3 実機検証` 節) で判明した課題:
**`engine.computeFkp` の出力 FkpParam が 4-5 桁過大** で、rover の RTK fix
品質を向上させるどころか fine_phase を ±4.7 m 値域でクランプさせている。

本フェーズの目的は **FKP 補正値を物理妥当範囲 (mm-cm scale) に収める**。
位置精度を実際に改善する本命作業 (Phase 5b は配線、Phase 6 は中身)。

---

## 1. 課題の再整理

### 1.1 現状の `computeFkp` (`src/fkp/engine.zig`)

入力: 3 局の `StationObs { coord, []SatObs }`、`SatObs = { prn, l1_m, l2_m }`。
ここで `l1_m, l2_m` は MSM7 から `extractPhase` で取り出した **生の搬送波
位相観測値 [m]** (`rough_range + fine_phase` を `c × 1e-3 ms→m` 換算)。

数式 (田中 2003 §4.3.4 そのまま):
```
LIF_b = α·(l1_b − l1_a) − β·(l2_b − l2_a)   # ionosphere-free single-difference
LGF_b = (l1_b − l1_a) − (l2_b − l2_a)        # geometry-free single-difference
n_0 = inv_a[0][0]·LIF_b + inv_a[0][1]·LIF_c  # m / rad
e_0 = inv_a[1][0]·LIF_b + inv_a[1][1]·LIF_c
n_i = inv_a[0][0]·LGF_b + inv_a[0][1]·LGF_c
e_i = inv_a[1][0]·LGF_b + inv_a[1][1]·LGF_c
```

### 1.2 何が誤りか

`L = ρ + I + T + (clock) + N·λ + ε` (ρ = geometric range、I = iono、T = tropo、
N·λ = 整数アンビギュイティ・波長倍、ε = noise/multipath)。

`LIF` の "ionosphere-free" は **I の周波数依存差** を α/β 係数で消すだけで、
**ρ, T, clock, N·λ はそのまま残る**。

3 局間で SD を取った `l_b − l_a` は station clock が消えるが ρ の差 (km scale、
衛星-局幾何) と (N_b − N_a)·λ (整数バイアス) は残ったまま。これが `inv_a`
(≈ 11600 1/rad、Paris 三角測量) で割られて n_0/e_0 が数千〜数万 m/rad に
膨らみ、rover offset 0.013 rad で 100m-km scale の補正値を生む。

### 1.3 Tanaka 2003 が暗黙に前提としている処理

論文 §4.3.2 のフローでは **FKP 計算前に以下が完了済み** を前提:

1. 衛星 ephemeris から各局-衛星の **geometric range** `ρ_j_a` を計算
2. 観測値から geometric range を引いた **residual** `L̃_j_a = L_j_a − ρ_j_a`
   を生成 (これで ρ は除去、残るは I + T + clock + N·λ)
3. **double-difference (DD)** で衛星間 SD を取り station clock + sat clock
   + 共通 troposphere を除去 (残るは I 差 + DD-N·λ)
4. **DD 整数アンビギュイティ解決 (LAMBDA 等)** で N·λ を整数値に fix
5. fix 後の residual (= 主に iono 残差 + multipath ~cm scale) に対して
   平面 fit (n_0, e_0, n_i, e_i) を行う

現実装は **1〜4 をすべて省略** して 0 (= 生の観測値) を入力にしているため
過大値を出している。

---

## 2. 修正アプローチの選択肢

### 2.1 案 A: フル ephemeris + 衛星 ECEF + DD + LAMBDA (本格 FKP)

| 工程 | 内容 | 規模 |
| --- | --- | --- |
| Eph parser | 1019/1020/1042/1045/1046 を bit-level 解析 | ~500 行 |
| Sat propagator | Keplerian 6 要素 + 摂動 → ECEF (GPS/Gal/BDS) | ~300 行 |
| GLO propagator | PZ-90 ECEF 数値積分 (4 次 Runge-Kutta) | ~200 行 |
| Geometric range | `ρ = ‖sat_ecef − sta_ecef‖` + light-time iteration | ~100 行 |
| DD 形成 | reference sat 選定 + SD/DD 計算 | ~200 行 |
| LAMBDA 解 | DD 整数アンビギュイティ resolver | ~600 行 |
| computeFkp 改修 | DD residual ベースに置換 | ~150 行 |
| **合計** | | **~2000 行** |

これは **正しい FKP**。位置精度は cm 級まで上がる可能性がある。だが工数大、
LAMBDA は数値的にデリケート、cycle slip 検出も必要。

### 2.2 案 B: rough_range を使った近似 geometric range subtraction

MSM7 の各観測値には `rough_range_ms = rough_int + rough_mod/1024` という
**衛星-局の見かけ距離 [ms]** が同梱されている。これを `ρ_approx` として
使い、`L̃ = L − ρ_approx ≈ I + T + N·λ` (ms 級スケール) を作る。

```zig
L_residual_a = phase_obs_a - rough_range_m_a   // ~m scale (with N·λ ambiguity)
```

このまま SD/DD すれば clock と T は消える。N·λ は cycle slip がない限り
**1 epoch 内で stable**。連続 epoch の **差分** (= epoch-to-epoch DD)
を取れば N も消えて純粋な iono 変化 (cm/sec) になる。

| 工程 | 内容 | 規模 |
| --- | --- | --- |
| extractPhase 拡張 | rough_range_m も返すよう改修 | ~30 行 |
| Eph parse 不要 | rough_range で代用 | 0 行 |
| Residual 計算 | L - rough を SatObs に保存 | ~50 行 |
| Single-epoch DD | reference PRN 選定 + SD/DD | ~200 行 |
| computeFkp 改修 | DD residual ベースに置換 | ~100 行 |
| **合計** | | **~400 行** |

位置精度は本格版より落ちる (rough_range の量子化は 1/1024 ms ≈ 293 m、
fine_phase で詰めても N·λ が DD で残る) が、補正値の magnitude は **physical
plausible range (cm scale)** に収まることを期待できる。

### 2.3 案 C: 数 epoch を見て補正値を統計的に間引く (heuristic)

`computeFkp` の前段に検閲ロジックを入れる:
- n_0/e_0/n_i/e_i の絶対値が物理閾値 (例: 100 m/rad) を超えたら **棄却**
  → その PRN は補正対象から外す (Phase 5b-3 の forwardFiltered は該当 PRN
  の PhaseDelta entry がなければ no-op するのでそのまま動く)
- 連続 epoch で値が大きく変動した PRN も棄却 (LOS が遮蔽されたサインの
  可能性大)

この案は **誤った FKP が rover に届かないようにする防御策** だけで、位置
精度は上がらない。配線として既に動く Phase 5b の "下振れリスク" を抑える
だけの保険。本格的な改修は別途必要。

| 工程 | 規模 |
| --- | --- |
| 閾値判定 + warn log | ~30 行 |
| **合計** | **~30 行** |

### 2.4 推奨

**案 C を Phase 6a として即着手 (rover 側を壊さない保険)** → **案 B を
Phase 6b として中期で着手 (実用 cm 級精度)** → **案 A を Phase 7 として
長期で着手 (本格 cm 級)** の段階構成を推奨。

| Phase | 案 | 目的 | 工数 |
| --- | --- | --- | --- |
| **6a** | C | 補正値の magnitude を閾値で抑える (safety) | 2-3h |
| **6b** | B | rough_range で近似 geometric residual + DD | 2-3 日 |
| **7** | A | フル ephemeris + LAMBDA で cm 級 | 1-2 週間 |

---

## 3. RTCM3 ephemeris メッセージ bit レイアウト (案 A/B 用参考)

案 B では rough_range で代用するので必須ではないが、Phase 7 で必要になる
ので memo として残す。

### 3.1 GPS Type 1019 (488 bit)

| field | bits | 単位 |
| --- | --- | --- |
| msg_num | 12 | = 1019 |
| sat_id | 6 | PRN 1..32 |
| week | 10 | mod-1024 |
| sv_acc | 4 | meters |
| code_on_L2 | 2 | |
| idot | 14 | semi-circles/s, 2^-43 |
| iode | 8 | |
| toc | 16 | 2^4 s |
| af2 | 8 | 2^-55 s/s² |
| af1 | 16 | 2^-43 s/s |
| af0 | 22 | 2^-31 s |
| iodc | 10 | |
| crs | 16 | 2^-5 m |
| dn | 16 | semi-circles/s, 2^-43 |
| m0 | 32 | semi-circles, 2^-31 |
| cuc | 16 | rad, 2^-29 |
| ecc | 32 | 2^-33 |
| cus | 16 | rad, 2^-29 |
| sqrtA | 32 | √m, 2^-19 |
| toe | 16 | 2^4 s |
| cic | 16 | rad, 2^-29 |
| omega0 | 32 | semi-circles, 2^-31 |
| cis | 16 | rad, 2^-29 |
| i0 | 32 | semi-circles, 2^-31 |
| crc | 16 | 2^-5 m |
| argp | 32 | semi-circles, 2^-31 |
| omdot | 24 | semi-circles/s, 2^-43 |
| tgd | 8 | 2^-31 s |
| sv_health | 6 | |
| L2P_flag | 1 | |
| fit_interval | 1 | |

合計 488 bit = 61 byte payload。

### 3.2 GLONASS Type 1020 (360 bit) — FDMA で channel 情報含む
### 3.3 Galileo Type 1045 (484 bit) F/NAV / Type 1046 (492 bit) I/NAV
### 3.4 BDS Type 1042 (499 bit)

詳細は RTCM 10403.3 § 3.5.13 (GPS) / § 3.5.14 (GLO) / § 3.5.25 (BDS) /
§ 3.5.32-33 (Gal) 参照。

---

## 4. Phase 6a (案 C) 実装計画

### 4.1 閾値判定の挿入箇所

`src/fkp/engine.zig::computeFkp` の最終 append 直前:

```zig
const ABS_MAX_FKP: f64 = 100.0; // m/rad、物理的に妥当な上限の経験値
const max_abs = @max(@max(@abs(n_i), @abs(e_i)), @max(@abs(n_0), @abs(e_0)));
if (max_abs > ABS_MAX_FKP) {
    // 異常値: この PRN の FKP は破棄
    continue;
}

try fkp_list.append(allocator, .{
    .prn = prn, .n_i = n_i, .e_i = e_i, .n_0 = n_0, .e_0 = e_0,
});
```

### 4.2 副作用とその対応

- **棄却された PRN は forwardFiltered の applyVrsPhaseCorrection で
  PhaseDelta 不在 → no-op (補正なし frame 通過)**。Phase 5a 動作と同じ。
- `frames_correction_failed` カウンタは増えない (適用は試行されたが個別
  cell で delta 該当なし、というケース)。新カウンタ `prn_dropped_excess`
  を fkp.runtime 側に置いて統計を取る案あり。
- 閾値 100 m/rad の根拠: 50km baseline で 1m 補正 → 1m / (50km/6378km)
  = 1m / 7.84e-3 rad = 127 m/rad。境界より少し下に置く。

### 4.3 警告ログ

```zig
rt.state.logger.warn(
    "[fkp] PRN={d} dropped (excess FKP magnitude n0={d:.0} e0={d:.0} ni={d:.0} ei={d:.0})",
    .{ prn, n_0, e_0, n_i, e_i },
);
```

毎 epoch で全 PRN 出すと log が氾濫するので、`logger.debug` か frequency
limited (毎 N 秒 / 局ごと最初の 3 回など) にする。

### 4.4 テスト

`tests/test_fkp.zig` に追加:
- 異常 lif/lgf (geometric residual が km scale) を合成 → computeFkp が
  該当 PRN を返さないこと
- 妥当 lif/lgf (mm-cm scale) を合成 → computeFkp が正常に返すこと

### 4.5 工数

- 閾値判定挿入: 30 分
- 警告ログ調整: 30 分
- ユニットテスト 2 件: 1 時間
- CHANGELOG + commit: 30 分
- **合計 2-3 時間**

---

## 5. Phase 6b (案 B) 実装計画

### 5.1 必要な拡張

#### 5.1.1 `extractPhase` 拡張: rough_range_m を返す

現状 `PhaseObs = { prn, phase_m, freq_hz, band }`。追加:
```zig
pub const PhaseObs = struct {
    prn: u8,
    phase_m: f64,
    rough_range_m: f64,   // ← NEW: rough_range × c×1e-3、近似 geometric range
    freq_hz: f64,
    band: Band,
};
```

#### 5.1.2 `SatObs` 拡張: residual 保持

```zig
pub const SatObs = struct {
    prn: u8,
    l1_m: ?f64,
    l2_m: ?f64,
    rough_l1_m: ?f64,     // ← NEW
    rough_l2_m: ?f64,     // ← NEW
    // 派生
    pub fn l1_residual(self: SatObs) ?f64 {
        return if (self.l1_m != null and self.rough_l1_m != null)
            self.l1_m.? - self.rough_l1_m.?
        else null;
    }
};
```

#### 5.1.3 `computeFkp` を residual ベースに置換

```zig
// 旧: 生 phase 観測値
const dl1_b = l1b - l1a;
// 新: residual = phase - rough_range
const r1a = obs_a.l1_residual() orelse continue;
const r1b = obs_b.l1_residual() orelse continue;
const r1c = obs_c.l1_residual() orelse continue;
const dl1_b = r1b - r1a;
const dl1_c = r1c - r1a;
// 以下同様
```

これで `dl1` は (iono + tropo + N·λ + clock) の SD 差分、ρ の km scale が
消える。clock も SD で station clock は消える (sat clock は残る、これは
DD で消す)。

#### 5.1.4 Double-difference (DD) で sat clock + tropo を消す

reference PRN (最高仰角 or 単純に最小 PRN) を選び、その他の PRN との差を
取る:
```zig
const ref_prn = pickReferencePrn(stations);
// DD_jb_a = (L̃_jb − L̃_ja) − (L̃_kb − L̃_ka)  for j ≠ k = ref
```

DD は station clock + sat clock + tropo + 大部分の iono を消去。残るは
(integer ambiguity DD + cm-scale iono 残差 + noise)。

#### 5.1.5 ambiguity の扱い (簡易版)

LAMBDA は実装しないので、**最初の epoch の DD 値を ambiguity と見なして
基準化**。以後の epoch では DD - DD_init を residual とする。

```zig
// 初回 epoch
if (rt.dd_init == null) {
    rt.dd_init = dd_values;
    // この epoch は FKP 出さない
    return;
}
// 2 epoch 目以降
for (dd, dd_init) |d, d0| {
    residual = d - d0; // ~cm scale, ambiguity-free
}
// この residual を平面 fit (n_0, e_0, n_i, e_i)
```

cycle slip が起きると ambiguity がジャンプして補正値が暴れるので、
**lock-time indicator** (MSM7 ヘッダ DF407) を参照して slip 検出 → dd_init
リセット の機構が必要。

### 5.2 工数

| 工程 | 工数 |
| --- | --- |
| extractPhase 拡張 + tests | 1 時間 |
| SatObs 拡張 + groupPhaseObs 改修 | 1 時間 |
| computeFkp residual 化 + tests | 2 時間 |
| DD 形成 + reference PRN 選定 | 3 時間 |
| ambiguity 簡易処理 + lock-time slip 検出 | 4 時間 |
| 実機検証 (docker 上 caster + python rover) | 2 時間 |
| **合計** | **~13 時間 = 2-3 セッション** |

### 5.3 期待精度

- baseline 50 km 程度: 補正値は cm scale に収まる見込み
- rover の RTK fix 時間: 数分以内 (現状 ∞ = fix 不可)
- 位置精度: 10cm 級 (本格 FKP は cm 級)

---

## 6. Phase 7 (案 A) スコープのみ整理

詳細は Phase 6b の完了後に別ドキュメントで。要点:

- Ephemeris parser (1019/1020/1042/1045/1046) を `src/fkp/ephemeris.zig`
  として新設
- 各 GNSS の衛星 ECEF 計算 (Keplerian + 摂動補正):
  - GPS: ICD-200 §20.3.3.4.3 アルゴリズム
  - Gal: ICD-Galileo §5.1.1
  - BDS: ICD-Compass §5.2
  - GLO: PZ-90 数値積分 (Runge-Kutta 4)
- 光行差時間補正 (signal travel time iteration)
- LAMBDA (Teunissen 1995) もしくは MLAMBDA (Chang 2005) を Zig 実装
- 連続性 (continuous tracking) の管理: cycle slip 検出強化、ephemeris 切替
  追従

### 6.1 工数 (見積もり、誤差大)

- ephemeris parser: 1-2 日
- 衛星 propagator (4 GNSS): 3-5 日
- DD + LAMBDA: 1 週間
- 統合・実機検証: 1 週間
- **合計 ~3 週間**

これは ntripcaster の主目的 (NTRIP caster as a service) からは少しスコープ
逸脱気味なので、Phase 6b で実用精度 (10cm 級) が出るなら Phase 7 はオプション
扱いでもよい。

---

## 7. 判断事項 / Open Questions

| # | 課題 | 案 / メモ |
| --- | --- | --- |
| 1 | Phase 6a (閾値) だけで終わるか、Phase 6b まで進むか | 6a は数時間。6b は数日。6a で実用配信は維持できるので、`phase4-vrs` をマージしてから 6b に着手する流れが妥当 |
| 2 | DD の reference PRN 選定方法 | 単純な最小 PRN / 最高仰角 (要 ephemeris) / 最大 CNR (MSM7 内蔵)。MSM7 から取れる CNR が一番簡単 |
| 3 | cycle slip 検出ロジック | MSM7 DF407 lock_time_indicator が前 epoch から減少 → slip。MSM7 各 cell に lock_time あるので per-PRN 追跡可能 |
| 4 | ambiguity 簡易処理の初期化タイミング | 起動直後 1 epoch を捨てる / 各 PRN の最初の lock も同様 |
| 5 | rough_range の精度 (1/1024 ms = 293 m) は十分か | DD で SD 取ると 293m は消える (相対値ではなく差分が問題)。実用上問題ないはず |
| 6 | Phase 6 は phase4-vrs に積むか、別ブランチか | 別ブランチ (phase6-fkp-residual) 推奨。phase4-vrs はマージしてからの方が衝突しない |
| 7 | engine.zig の田中 2003 参考文献コメントの扱い | 田中 2003 §4.3.4 式は正しい (前提が満たされていれば)。前提 (DD 残差入力) を明記する形でコメント追加が必要 |

---

## 8. 次セッションでまず確認すること

1. **Phase 6a だけで rover が「壊れない」ことを確認** — Paris 設定で
   閾値 100 m/rad を入れた caster を起動、phase_corrected が 0 に張り付く
   (= 全 PRN 棄却される) ことを期待値として確認する。閾値が低すぎないか
   調整する。
2. rough_range の挙動を生キャプチャから確認 — `python /tmp/vrs_check.py`
   の延長で、`rough_range_m` を 30 秒ぶん集計して PRN ごとの分散・連続性
   を見る。cycle slip / loss-of-lock の頻度を把握。
3. MSM7 の lock_time_indicator (DF407) を `extractPhase` で取り出すか
   検討。Phase 6b で必要になるので、Phase 6a と同時に拾ってもよい。

---

## 9. 作業見積もり総括

| Phase | 内容 | 工数 | 効果 |
| --- | --- | --- | --- |
| **6a** | computeFkp 閾値判定 + 棄却 | 2-3h | 補正値暴走防止 |
| **6b** | rough_range residual + DD + 簡易 ambiguity | 13h ≈ 2-3 セッション | 10cm 級精度 |
| **7** | フル ephemeris + LAMBDA | ~3 週間 | cm 級精度 |

Phase 6a は即着手して `phase4-vrs` ブランチに足してマージ可能な状態にする。
Phase 6b は別ブランチ (`phase6-fkp-residual` 等) で着手し、phase4-vrs
マージ後の master から派生させる。Phase 7 は将来オプション。
