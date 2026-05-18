# Phase 7 設計メモ — Ephemeris ベース本格 FKP (DD + LAMBDA)

Phase 6b 撤去 (2026-05-18) を受けて、FKP 補正値を物理妥当な cm 級に
収めるための **本格実装** の設計を整理する。Phase 6 までで作った
配管 (VRS / FKP runtime / passthrough / Type 59 encoder) はそのまま
使い、`computeFkp` への入力データ (= phase 観測値の前処理) を Tanaka
2003 §4.3.2 が暗黙に前提していた完全な状態に揃える。

参考: `docs/phase5b-design.md` (MSM7), `docs/phase6-design.md` (Phase 6
の試行と撤去経緯)、Tanaka 慎治 (2003) §4.3。

---

## 1. ゴールと非ゴール

### 1.1 ゴール

1. **衛星 ECEF 計算**: ephemeris message (1019/1020/1042/1045/1046) を
   解析し、各 GNSS の衛星位置を ECEF [m] で計算可能にする。
2. **Geometric range 計算**: 各 (station, sat) ペアで光行差時間補正付き
   `ρ = ‖sat_ecef(t-τ) − sta_ecef‖` を計算。
3. **DD 形成**: SD residual `L − ρ − clock` から DD (sat 間) で sat clock
   + 共通 tropo を除去。
4. **整数アンビギュイティ解決**: LAMBDA (Teunissen 1995) もしくは MLAMBDA
   (Chang 2005) で DD-N·λ を fix。
5. **本格 FKP**: ambiguity-fixed DD residual (~cm scale) を平面 fit で
   FkpParam に変換。`computeFkp` を新インターフェースに差し替え。
6. **CI/実機検証**: docker centipede-paris で FKP magnitude が物理妥当
   範囲 (~10 m/rad 以下) に収まること、rover (RTKLIB str2str → rtkrcv)
   で RTK fix が短時間で立つことを確認。

### 1.2 非ゴール

- 全 GNSS 全 signal 対応 (まず GPS L1/L2 のみ。GLO/Gal/BDS は段階追加)。
- マルチパス検出 / weighting 高度化。
- 衛星 health / URA に基づくマスキング (基本的な health bit のみ尊重)。
- Real-time SSR (RTCM 4072 等) のような precise products 対応。

---

## 2. アーキテクチャ概要

```
                                ┌───────────────────────┐
   upstream MSM7 ─────────────▶ │  Phase observation    │
   upstream 1019/1020/1042  ──▶ │     extractor         │  (既存: msm7.zig)
   upstream 1042/1045/1046  ──▶ │  + ephemeris decoder  │  (新規: ephemeris.zig)
                                └──────────┬────────────┘
                                           │
                                ┌──────────▼────────────┐
                                │  Satellite ECEF       │  (新規: orbit.zig)
                                │  propagator (per GNSS)│
                                └──────────┬────────────┘
                                           │
                                ┌──────────▼────────────┐
                                │  Geometric range +    │  (新規: geometry.zig)
                                │  light-time iteration │
                                └──────────┬────────────┘
                                           │
                                ┌──────────▼────────────┐
                                │  Residual = L − ρ     │  (engine.zig 改修)
                                │  SD → DD per pair     │
                                └──────────┬────────────┘
                                           │
                                ┌──────────▼────────────┐
                                │  LAMBDA ambiguity     │  (新規: lambda.zig)
                                │  fix (DD-N·λ)         │
                                └──────────┬────────────┘
                                           │
                                ┌──────────▼────────────┐
                                │  Plane fit            │  (engine.zig 改修)
                                │  → FkpParam           │
                                └───────────────────────┘
```

新規モジュール: `src/fkp/ephemeris.zig` / `src/fkp/orbit.zig` /
`src/fkp/geometry.zig` / `src/fkp/lambda.zig`。

---

## 3. Ephemeris メッセージ仕様

### 3.1 GPS Type 1019 (488 bit)

| field | bits | scale / unit |
| --- | --- | --- |
| msg_num | 12 | = 1019 |
| sat_id | 6 | PRN 1..32 |
| week | 10 | mod-1024 |
| sv_acc | 4 | URA index |
| code_on_L2 | 2 | |
| idot | 14 | 2^-43 semi-circles/s |
| iode | 8 | |
| toc | 16 | 2^4 s |
| af2 | 8 | 2^-55 s/s² |
| af1 | 16 | 2^-43 s/s |
| af0 | 22 | 2^-31 s |
| iodc | 10 | |
| crs | 16 | 2^-5 m |
| dn | 16 | 2^-43 semi-circles/s |
| m0 | 32 | 2^-31 semi-circles |
| cuc | 16 | 2^-29 rad |
| ecc | 32 | 2^-33 |
| cus | 16 | 2^-29 rad |
| sqrtA | 32 | 2^-19 √m |
| toe | 16 | 2^4 s |
| cic | 16 | 2^-29 rad |
| omega0 | 32 | 2^-31 semi-circles |
| cis | 16 | 2^-29 rad |
| i0 | 32 | 2^-31 semi-circles |
| crc | 16 | 2^-5 m |
| argp | 32 | 2^-31 semi-circles |
| omdot | 24 | 2^-43 semi-circles/s |
| tgd | 8 | 2^-31 s |
| sv_health | 6 | |
| L2P_flag | 1 | |
| fit_interval | 1 | |

合計 488 bit = 61 byte payload。

### 3.2 GLONASS Type 1020 (360 bit) — FDMA、channel info 含む

PZ-90 座標系で位置 / 速度 / 加速度を直接エンコード (Keplerian ではない)。
4 次 Runge-Kutta で TOE → 観測時刻まで積分。frequency channel number は
sig_mask とは別に必要。RTCM 10403.3 § 3.5.14。

### 3.3 Galileo Type 1045 (484 bit, F/NAV) / Type 1046 (492 bit, I/NAV)

GPS と類似の Keplerian だが、Galileo 固有の補正項あり。RTCM 10403.3
§ 3.5.32-33。

### 3.4 BDS Type 1042 (499 bit)

GPS と類似だが BDT 時刻系で運用。RTCM 10403.3 § 3.5.25。

### 3.5 実装スケルトン

```zig
// src/fkp/ephemeris.zig
pub const GpsEphemeris = struct {
    prn: u8,
    week: u16,    // GPS week (mod 1024 を展開)
    toc: f64,     // clock reference time [s]
    toe: f64,     // ephemeris reference time [s]
    iode: u8, iodc: u16,
    af0: f64, af1: f64, af2: f64,            // [s, s/s, s/s²]
    crs: f64, crc: f64, cuc: f64, cus: f64, cic: f64, cis: f64,  // 摂動 [m, rad]
    dn: f64, m0: f64, ecc: f64, sqrtA: f64,  // 軌道要素
    omega0: f64, omdot: f64, i0: f64, idot: f64, argp: f64,
    tgd: f64, sv_health: u8,
};

pub fn parseMsg1019(payload: []const u8) ?GpsEphemeris { ... }

// runtime のキャッシュ
pub const EphemerisStore = struct {
    gps: std.AutoHashMapUnmanaged(u8, GpsEphemeris) = .{},
    glo: ..., gal: ..., bds: ...,
    pub fn upsert(...): 同一 PRN の新 IODE/IODC を保持
    pub fn lookup(prn, gnss, t): valid な eph を返す (fit interval 内)
};
```

---

## 4. 衛星 ECEF 計算

### 4.1 GPS (Keplerian + 摂動補正)

IS-GPS-200L Table 20-IV のアルゴリズム:

```
1. n0 = sqrt(μ / sqrtA^6)              # mean motion
2. tk = t - toe                         # time from ephemeris reference
3. n  = n0 + dn                         # corrected mean motion
4. mk = m0 + n*tk                       # mean anomaly
5. ek = Kepler iteration: ek = mk + ecc*sin(ek)  (~ 10 回)
6. vk = atan2(sqrt(1-e²)*sin(ek), cos(ek)-ecc)   # true anomaly
7. phi_k = vk + argp                    # argument of latitude
8. du = cus*sin(2*phi) + cuc*cos(2*phi) # second harmonic perturbations
9. dr = crs*sin(2*phi) + crc*cos(2*phi)
10. di = cis*sin(2*phi) + cic*cos(2*phi)
11. u = phi + du; r = A*(1 - ecc*cos(ek)) + dr; i = i0 + idot*tk + di
12. xp = r*cos(u); yp = r*sin(u)        # in-plane position
13. Omega = omega0 + (omdot - we)*tk - we*toe
14. x = xp*cos(Omega) - yp*cos(i)*sin(Omega)
15. y = xp*sin(Omega) + yp*cos(i)*cos(Omega)
16. z = yp*sin(i)
```

μ = 3.986005e14 m³/s², we = 7.2921151467e-5 rad/s (WGS-84)。

### 4.2 GLONASS (PZ-90 数値積分)

```
PZ-90 → WGS-84 変換: 7 パラメータ Helmert (~mm scale shift)。
TOE での位置/速度/加速度を初期値、観測時刻まで 4 次 Runge-Kutta で
重力 + J2 + 太陽月引力 (acceleration field) を積分。
ステップ ~30s で十分。詳細は ICD GLONASS §4.5.4。
```

### 4.3 Galileo / BDS

GPS と同じ Keplerian + 摂動の枠組み。違いは:
- Gal: F/NAV (1045) は E5a 単独、I/NAV (1046) は E1/E5b broadcast。
- BDS: GEO (PRN 1-5) は別座標系 (CGCS2000) で IGSO/MEO とアルゴリズム
  異なる。

### 4.4 光行差時間補正 (light-time iteration)

```
1. τ = 0.075 s (初期推定 = 約 22500 km)
2. sat_ecef_emit = orbit(t - τ)
3. ρ' = ‖sat_ecef_emit − sta_ecef‖
4. τ' = ρ' / c
5. abs(τ' - τ) < 1e-10 なら収束、それ以外は τ = τ' で 2 へ
通常 2-3 回で収束。
6. 地球回転補正: Omega = we * τ で sat_ecef を z 軸回転。
```

---

## 5. DD 形成 + LAMBDA

### 5.1 SD residual

```
L_j_a = ρ_j_a + I_j_a + T_j_a + c·(δt_j − δt_a) + N_j_a·λ + ε
residual_j_a = L_j_a − ρ_j_a − c·δt_j (sat clock from eph)
              = c·(−δt_a) + I_j_a + T_j_a + N_j_a·λ + ε
SD_j_b = residual_j_b − residual_j_a
        = c·(−δt_b + δt_a) + ΔI_j + ΔT_j + ΔN_j·λ + ε
```

Station clock は SD で消える (a,b 同じ衛星なら +δt も -δt も同じ
station clock)、ΔI / ΔT は基線が短いほど小さい。

### 5.2 DD (reference PRN k で除算)

```
DD_jb = SD_j_b − SD_k_b
       = ΔΔI_jk + ΔΔT_jk + ΔN_jk·λ + ε   (clock 完全消去)
```

reference PRN は最高仰角 or 最大 CNR が標準。MSM7 から CNR 抽出
(現在 skip している 10 bit を読み取る) するか、衛星 ECEF + sta ECEF
から仰角計算で elevation を出すか。

### 5.3 LAMBDA

`DD_jb [m]` を波長 λ で割って単位 cycle に直し、float ambiguity
`âj = round(DD_jb / λ + tropo/iono 推定)` を共分散行列付きで生成。
LAMBDA はこの float ambiguity を整数格子に投影する optimization 問題:

```
min  (a - â)^T · Q_â^-1 · (a - â)   s.t. a ∈ Z^n
```

実装は 600 行規模。Teunissen 1995 のオリジナル LAMBDA より MLAMBDA
(Chang & Zhou 2005) の方が数値安定性が高く推奨。Z 行列分解 +
search bound + 整数最小化の三段構成。

### 5.4 Fixed DD residual → FKP plane fit

```
DD_fixed_jb = DD_jb − N_fix·λ     # ~cm scale
DD_fixed_jc = DD_jc − N_fix·λ     # ~cm scale
n_0 = inv_a[0][0]*LIF(DD_fixed_jb) + inv_a[0][1]*LIF(DD_fixed_jc)
e_0 = inv_a[1][0]*LIF(DD_fixed_jb) + inv_a[1][1]*LIF(DD_fixed_jc)
n_i = inv_a[0][0]*LGF(DD_fixed_jb) + inv_a[0][1]*LGF(DD_fixed_jc)
e_i = inv_a[1][0]*LGF(DD_fixed_jb) + inv_a[1][1]*LGF(DD_fixed_jc)
```

(現 `computeFkp` と同じ最終ステップ。入力 LIF/LGF が cm scale 残差に
なっているので n_*/e_* も cm/rad ~ 10 m/rad 級に収まる)

ref PRN k 自身は `FkpParam` 出力に含めない (= DD ベースの構造的帰結)。

---

## 6. 実装計画 (フェーズ分割)

| Phase | 内容 | 工数 |
| --- | --- | --- |
| **7-0** | 設計確認 + フォルダ構造 + skeleton | 半日 |
| **7-1** | GPS 1019 parser + ephemeris store + 既存 upstream に配管 | 1-2 日 |
| **7-2** | GPS 衛星 ECEF (Keplerian + 摂動) + light-time + 単体テスト | 1-2 日 |
| **7-3** | SD/DD residual + ref PRN 選定 (CNR or elev) | 1-2 日 |
| **7-4** | LAMBDA / MLAMBDA 実装 + ambiguity validation (ratio test) | 3-5 日 |
| **7-5** | FKP plane fit を residual 入力に切替 + Type 59 出力検証 | 1 日 |
| **7-6** | GLO 1020 parser + RK4 propagator | 2-3 日 |
| **7-7** | Galileo 1045/1046 + BDS 1042 | 1-2 日 |
| **7-8** | 実機検証 (docker + centipede-paris) + rover RTK fix 確認 | 2-3 日 |
| **合計** | | **2-3 週間** |

GPS only (Phase 7-0..7-5) でも実用検証は可能。GLO/Gal/BDS は段階追加。

---

## 7. リスク + Open Questions

| # | 課題 | メモ |
| --- | --- | --- |
| 1 | LAMBDA の Zig 実装は重い | MLAMBDA で ~600 行、共分散行列の LDL 分解 / Z 行列 / 整数 search ツリーが必要。他言語 ref 実装 (RTKLIB lambda.c) を参照しつつポート |
| 2 | ephemeris の rate of upload | RTCM 1019 は 30 秒〜2 分間隔で出る。startup 直後の数十秒は eph がそろわず DD ができない。Phase 6a fallback (empty FKP) で耐える |
| 3 | cycle slip 検出 | MSM7 DF407 lock_time_indicator を毎 epoch 監視。減少 = slip → ambiguity 再 fix |
| 4 | GPS week rollover | week は 10-bit mod-1024。caster 起動時に現 GPS week を計算して mod 比較で正しい絶対 week を復元 |
| 5 | GLO の channel number は MSM7 + 1020 の両方に登場 | 整合性確認: 1020 の channel と sig_mask から得る周波数を crosscheck |
| 6 | BDS GEO (PRN 1-5) と IGSO/MEO の座標系違い | Phase 7-7 で別アルゴリズムが必要。MSM7 でも識別可能 |
| 7 | 衛星 / 局時計の補正 | af0 + af1*(t-toc) + af2*(t-toc)² から sat clock。station clock は SD で消えるので明示計算は不要 |
| 8 | 大気モデルの初期推定 (LAMBDA float に渡す) | Saastamoinen tropo + Klobuchar iono の broadcast 値で初期化。なくても LAMBDA は動くが収束が遅い |

---

## 8. テスト方針

### 8.1 単体テスト
- `parseMsg1019`: 既知の ephemeris bit pattern (例: IGS BRDC ファイルから
  生成した RTCM 1019 sample) を入力 → struct のフィールド単位で値検証。
- `gpsSatEcef`: TOE+0s / TOE+30min での ECEF 値が IGS sp3 と一致 (許容 1m)。
- `lightTimeIteration`: 既知の sat_ecef + sta_ecef → ρ を IGS DOP map と
  一致 (許容 cm)。
- `lambda`: 既知の float ambiguity + 共分散 → expected integer が返る。
  ratio test の boundary 動作も確認。

### 8.2 結合テスト
- 実機 RTCM3 ストリーム (録音済み 60s 分) を入力 → ephemeris store が
  PRN 全てに valid eph を持つこと、DD residual が cm scale に収まること。
- `computeFkp` の output FkpParam で `max(|n*|, |e*|) < 50 m/rad` が
  9 割以上の PRN で達成されること (経験閾値)。

### 8.3 実機検証 (docker)
- centipede-paris 3 局 → caster → str2str (RTKLIB) → rtkrcv → fix 時間。
- fix が 30 秒以内に立つこと、float→fix 比率 (status) が rover summary で
  読み取れること。

---

## 9. Phase 7 vs 既存資産の関係

Phase 7 で **既存の Phase 4 / 5 / 6a のコードは破壊しない**:

- VRS / forwardFiltered / ref_id 書き換え (Phase 5a): そのまま使う。
  FkpParam の有無に依存しない。
- applyVrsPhaseCorrection / FkpSnapshotStore (Phase 5b): FkpParam の
  semantics は同じ (n_*, e_* in m/rad)、Phase 7 で出る値は magnitude が
  小さくなるだけで API 互換。
- Phase 6a 閾値 100 m/rad: そのまま残す (Phase 7 でも safety net として
  有効)。

つまり Phase 7 は computeFkp の **入力データの質** だけを上げる作業で、
caster 全体の構造には触らない。

---

## 10. 次セッションの着手手順

1. `phase7-eph` ブランチで開始 (master @ faa3819 から派生済み)。
2. `src/fkp/ephemeris.zig` を新規作成、Type 1019 parser を実装。
3. `src/fkp/upstream.zig::handleFrame` で 1019 を捕捉して
   `EphemerisStore.upsert` を呼ぶ配管を追加。
4. ユニットテスト: 既知の 1019 bit pattern → struct 一致。
5. ここまで終わったら Phase 7-1 完了として中間 commit。
6. Phase 7-2 (Keplerian propagator) に進む。

参照すべき外部資料:
- IS-GPS-200 (現行版) § 20.3.3.4: GPS user algorithm
- RTCM 10403.3 § 3.5.13 (1019), § 3.5.14 (1020), § 3.5.25 (1042),
  § 3.5.32-33 (1045/1046)
- RTKLIB `src/ephemeris.c`, `src/lambda.c` を C 実装の参考に
- Teunissen P.J.G. (1995) "The least-squares ambiguity decorrelation
  adjustment: a method for fast GPS integer ambiguity estimation"
- Chang X.-W., Yang X., Zhou T. (2005) "MLAMBDA: a modified LAMBDA
  method for integer least-squares estimation"
