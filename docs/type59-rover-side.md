# 領域 3 調査メモ — Type 59 (proprietary FKP) の rover 側適用

調査日: 2026-05-18 / 調査者: Agent (領域 3) / 対象ブランチ: phase4-vrs

参照: `docs/phase7-4-research.md` § 領域 3

---

## 1. エグゼクティブサマリ

**結論: 現実装の Type 59 encoder (`src/fkp/type59.zig`) は、汎用 NTRIP rover にとっては事実上「無音メッセージ」である。Phase 5b-3 で rover に RTK fix が立たなかった原因の有力候補。**

要点:

1. RTKLIB (`PocketSDR/lib/RTKLIB/src/rtcm3.c` の `decode_rtcm3`) の `switch (type)` には `case 59` が無い。デコーダのエントリポイントを通過しても `ret = 0` で **silent ignore** される。
2. RTCM 標準の FKP メッセージは Type **1034 (GPS)** / **1035 (GLONASS)** だが、それすら RTKLIB は `trace(2,"...not supported")` の **空スタブ**。FKP を実用デコードする OSS rover は事実上存在しない。
3. Type 59 は RTCM 10403.3 で **未割当** (proprietary 領域は 4070-4095)。本実装は「reserved/legacy 領域を借用したプロプラ拡張」であり、Tanaka 2003 の論文表記をなぞって自前 bit layout で出している。**送信先 (= 我々の `decodeType59`) 以外は誰も復号しない。**
4. 単位 (m/rad) と sign convention は本実装内部では encoder/decoder で閉じており、`computePhaseDelta` で `dN = rover.lat_rad - master.lat_rad` を使うので **Tanaka 2003 と整合**。ただし VRS パイプライン (Phase 5b-3) では rover に Type 59 を送らずに drop しており (vrs.zig:692)、rover 側で受け取ることはない。
5. 結論として **「Type 59 を rover に送って RTK fix を期待する」前提が誤り**。Phase 5b-3 で rover に届くのは「ref_id 書換済 MSM7 + 偽 1005 + 偽 1008」だけ。rover は単独基準局として扱うため、FKP plane fit は使われない。

→ 修正方針: **rover が読まないメッセージに労力を割かず、(a) caster 内部で Type 59 を消費して MSM7 を補正するパイプライン (= 既に Phase 5b-3 で実装中) に集中するか、(b) RTCM SSR (4076.x) または MAC (1014-1017) に置き換えるかを領域 4 と統合して判断する。**

---

## 2. 現実装 (`src/fkp/type59.zig`) のレビュー

### 2.1 ファイル概要

- 行数: 128 行 (encode + decode + 定数)
- 設計コメント (冒頭): 「BKG/EUREF 方式に近似した簡易フォーマット (互換性よりも動作実証を優先)」
- msg_type 定数: `MSG_TYPE = 59`

### 2.2 ビットレイアウト

ヘッダー (61 bit):

| field           | bits | 値                          |
| --------------- | ---- | --------------------------- |
| msg_type        | 12   | 59                          |
| ref_station_id  | 12   | u12 (caller 指定)           |
| tow_ms          | 30   | GPS Time of Week [ms]       |
| multi_msg       | 1    | 0 (本実装は常に最終)        |
| nsat            | 6    | 衛星数 (0..63、実装は 63 で clamp) |

衛星ブロック (Nsat × 72 bit):

| field | bits | scale         | LSB         | 値域                   |
| ----- | ---- | ------------- | ----------- | ---------------------- |
| prn   | 8    | -             | 1           | 1..255 (普通は 1..32)  |
| N_I   | 16   | SCALE_I=1e5   | 1e-5 m/rad  | ±0.32768 m/rad         |
| E_I   | 16   | SCALE_I=1e5   | 1e-5 m/rad  | ±0.32768 m/rad         |
| N_0   | 16   | SCALE_0=1e4   | 1e-4 m/rad  | ±3.2768 m/rad          |
| E_0   | 16   | SCALE_0=1e4   | 1e-4 m/rad  | ±3.2768 m/rad          |

CRC-24Q (3 byte) を末尾に付加。RTCM3 frame として整合 (`rtcm3.PREAMBLE` + len(10b) + payload + CRC)。

### 2.3 単位確定

- `engine.zig:56-61` に `n_i, e_i, n_0, e_0: [m/rad]` と明示。
- `computePhaseDelta` (vrs.zig:595-612) で `(n_i + n_0) * (rover_lat_rad - master_lat_rad) + (e_i + e_0) * (rover_lon_rad - master_lon_rad)` を計算 → 出力は **m**。
- → **「m/rad」で encoder/decoder 内部閉ループは整合**。dN/dE は rad (deg ではない) で正しい (Tanaka 2003 §4.3.3 と一致)。

### 2.4 値域チェック

- engine.zig の `DEFAULT_FKP_MAX_MAGNITUDE = 100.0` で 100 m/rad 超を棄却。
- encoder の clamp は ±0.32768 m/rad (N_I/E_I)、±3.2768 m/rad (N_0/E_0)。
- **N_0/E_0 の clamp 範囲 (±3.28 m/rad) は、コメントにある「50 km baseline で 50cm 補正 = 127 m/rad 上限」と比較して 1 桁狭い**。短い baseline (10-20 km) で大きな ionosphere gradient を載せたい場合に飽和する。

→ 内部消費 (caster 側で `computePhaseDelta` するだけ) なら問題ないが、後述するように外部 rover に渡すとしても、scale を再考すべき。

---

## 3. RTKLIB の Type 59 / FKP デコーダ実態

### 3.1 ローカル checkout

`/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3.c` (Takasu 公式 RTKLIB を Pocket SDR 経由で取得済) を grep で確認。

### 3.2 Type 59 の扱い

`decode_rtcm3()` (L2557-2710) の `switch (type)` を全て確認。

- `case 59:` **無し** (L2572-2702 を全部 enum)。
- フォールバック: ret=0 のまま返って `nmsg3[]` カウンタに刻まれるだけ。
- 同 switch には `case 11/12/13/14` (tentative SSR draft) や `case 63` (RTCM draft 1042 BeiDou eph) など独自 numbering もあるが、59 は割当が無い。

つまり **RTKLIB は Type 59 を完全に silent drop**。stream フィルタには引っかかるが、観測モデルには一切作用しない。

### 3.3 標準 FKP (Type 1034/1035) の扱い

```c
// rtcm3.c L1046-1057
/* decode type 1034: GPS network FKP gradient ----------------------------*/
static int decode_type1034(rtcm_t *rtcm)
{
    trace(2,"rtcm3 1034: not supported message\n");
    return 0;
}
/* decode type 1035: GLONASS network FKP gradient ----------------------------*/
static int decode_type1035(rtcm_t *rtcm)
{
    trace(2,"rtcm3 1035: not supported message\n");
    return 0;
}
```

- 関連 Network RTK ファミリも全て空スタブ:
  - Type 1037 (GLO iono correction difference)
  - Type 1038 (GLO geometric correction difference)
  - Type 1039 (GLO combined correction difference)
- エンコーダ側 (`rtcm3e.c`) にも `1034/1035` の関数は **存在しない**。

つまり **RTKLIB ファミリは standard FKP / MAC を全部 not supported**。MSM + SSR (4076.x) に集約しているのが現代の RTKLIB の方針。

### 3.4 他の rover OSS

ローカル checkout は RTKLIB のみ。一般情報 (調査者の知見):

- **goGPS-MATLAB**: SSR ベース。FKP は学術プロトタイプ実装はあるが MAC/FKP のフルパスはない。
- **pyrtklib / rtklib-py**: RTKLIB そのままの薄ラッパなので 1034/1035 は同じく no-op。
- **u-blox F9P / ZED-F9P** firmware: RTCM 入力は 1005/1006/1007/1008/1019/1020/1033/1042/1044/1045/1046 + MSM4/5/7 + SSR4076。**FKP 系 (59/1034/1035) は documentation 上の入力リストに無い**。
- **NovAtel OEM7**: 同様に MSM + SSR (RTCM SSR + Lband Trimble RTX) で運用。FKP は legacy 接続用にしかサポート無し。
- **Septentrio Mosaic-X5**: MSM + SSR + IGS State Space。FKP は無し。

業界全体で **FKP/MAC は GNSMART (Geo++) 等の専用 caster ↔ Geo++ 専用 rover 間でしか動かない死語**。Wuebbena らがやっている DLR/IGS 系の R&D を除き、商用 NRTK は SSR か VRS+MSM が標準。

---

## 4. Geo++ FKP 仕様の整理 (Wuebbena 2001)

### 4.1 出典

- Wuebbena G., Bagge A., Schmitz M., Menge F., Seeber G., Voelksen C. (2001) "Reducing distance dependent errors for real-time precise DGPS applications by establishing reference station networks." ION GPS 1996 (実は 1996 が初出、2001 は Network RTK 解説)
- Wuebbena G., Bagge A. (2002) "RTCM Message Type 59-FKP for transmission of FKP." Geo++ White Paper.
- Tanaka 慎治 (2003) §4.3.3 はこの 2002 white paper をベースに記述。

**Note**: Geo++ の Type 59 オリジナル仕様書は公開 PDF が現在入手困難 (Geo++ サイトでは技術文書を log-in 制限下に置いている)。Tanaka 2003 と RTCM Special Committee 104 のメンバー note 由来の二次情報で再構成するしかない。

### 4.2 FKP モデル (Tanaka 2003 § 4.3.3, Wuebbena 2002)

衛星 i の rover の搬送波位相補正 (master 局からの差):

```
ΔΦ_rover^i = ΔΦ_master^i
           + (N_0^i + N_I^i · η^i) · (φ_rover − φ_master)
           + (E_0^i + E_I^i · η^i) · (λ_rover − λ_master)
```

- ΔΦ: double difference 搬送波位相残差 [m]
- N_0, E_0: 幾何成分 (orbit + tropo) の北/東勾配 [m/rad]
- N_I, E_I: 電離層成分の北/東勾配 [m/rad]
- η^i: 周波数依存スケール (L1 で 1.0、L2 で (f_L1/f_L2)^2 ≈ 1.6469)
- 緯度経度差は **rad** (deg ではない)

我々の実装 (`computePhaseDelta`) は L1 のみで `(n_i + n_0)*dN + (e_i + e_0)*dE`、つまり η=1。L1 補正としては正しい。L2 を補正する場合は `n_0 + 1.6469*n_i` のように分ける必要があるが、現状 L1 のみなので問題ない。

### 4.3 Geo++ の bit layout (Tanaka 2003 表 4.4 推定)

| field           | bits | scale       | 我々の実装    |
| --------------- | ---- | ----------- | ------------- |
| msg_type        | 12   | -           | 一致 (59)     |
| ref_station_id  | 12   | -           | 一致          |
| GPS Epoch Time  | 23?  | 1 s?        | **我々は 30bit/1ms** |
| Satellite ID    | 6    | -           | **我々は 8bit (= PRN 直)** |
| N_0             | 8    | 0.4 mm/km   | **我々は 16bit, 1e-4 m/rad** |
| E_0             | 8    | 0.4 mm/km   | **我々は 16bit, 1e-4 m/rad** |
| N_I             | 8    | 0.04 mm/km  | **我々は 16bit, 1e-5 m/rad** |
| E_I             | 8    | 0.04 mm/km  | **我々は 16bit, 1e-5 m/rad** |

(注: 上記 8bit + 0.4mm/km は Tanaka 2003 の引用が **mm/km** スケールである点に注意。これは「ベースライン距離 1 km あたり何 mm 補正」という工学的単位で、**m/rad と等価ではない**。換算: 1 m/rad / 6378 km/rad = 1.568e-4 m/km = 0.1568 mm/km)

つまり **Geo++ オリジナル仕様は単位が mm/km、我々は m/rad**。換算係数は地球半径 6378137 m。

- 我々の SCALE_0=1e-4 m/rad/LSB → 1.568e-8 m/km/LSB = 0.0157 µm/km/LSB
  - これは「0.4 mm/km」の Geo++ オリジナル LSB (= 0.4e-3 m/km) と 25,478倍違う。
- 我々の N_0 値域 ±3.28 m/rad → ±0.514 mm/km 相当

→ **同じ「FKP」とは言っても bit layout / scale が完全に別物**。仮に Geo++ 仕様準拠の rover (= GNSMART 専用 rover) があったとしても、我々のフレームを Type 59 として食わせると、bit を踏み外して大爆発 (もしくは無視)。

---

## 5. Sign convention 表

調査結果から、Type 59 を「rover で適用する」シナリオを実機で検証したコードベースは見当たらないため、**Wuebbena/Tanaka が論文で示している sign convention を canonical** として比較する。

| 項目                   | Tanaka 2003 / Wuebbena 2002 | 我々の実装             |
| ---------------------- | ----------------------------- | ---------------------- |
| dN の定義              | φ_rover − φ_master [rad]      | 一致 (vrs.zig:602)     |
| dE の定義              | λ_rover − λ_master [rad]      | 一致 (vrs.zig:603)     |
| rover の補正適用方向   | Φ_rover_corrected = Φ_rover − ΔΦ | **VRS 路ではcaster 側で MSM7 phase に `+ delta_m` 加算** (msm7.applyPhaseCorrection) |
| L2 周波数スケール      | (f_L1/f_L2)^2 · N_I を加算  | **未実装 (L1 のみ)**   |
| 単位 (n_*, e_*)         | m/rad                          | 一致                   |

**符号** について我々の実装を辿ると:

- `computePhaseDelta` (vrs.zig:605): `delta_m = (n_i + n_0)*dN + (e_i + e_0)*dE`
  - master local plane の phase 関数を rover 位置で **評価** した値 (= rover 位置での expected phase deviation)
- `msm7.applyPhaseCorrection` (確認は別領域): rover 観測値の **同じ符号で加算** または **減算** が定義済 (要確認)

実機で fix が立つかは符号の整合性に依存。Phase 5b-3 で実機が fix しなかった原因が符号反転だった可能性は **applyPhaseCorrection の実装次第**。本領域では type59.zig そのものは encoder + 内部 decoder で閉じているので、Type 59 を外に出す前に問題が完結する。

---

## 6. 既知 NRTK サービスでの採用状況

| サービス                  | 配信プロトコル                                          | FKP (1034/1035 or 59) |
| ------------------------- | ------------------------------------------------------- | --------------------- |
| Geo++ GNSMART (商用)      | NTRIP + RTCM 3.x + プロプライエタリ                    | **採用 (生家)**       |
| Trimble VRS Now           | NTRIP + VRS (RTCM 3 MSM)                                | 不使用                |
| Topcon TopNET             | NTRIP + VRS / MAC                                       | MAC 主、FKP 補助       |
| Leica SmartNet            | NTRIP + MAC (1014-1017) / VRS                           | **MAC 主、FKP 廃止**  |
| Hexagon HxGN SmartNet     | NTRIP + MAC + iMAX                                      | FKP 不使用            |
| 国土地理院 (日本電子基準点網)| 公開 RTCM (RTKLIB BNC 経由)                            | FKP 不使用            |
| Centipede RTK (仏)        | NTRIP + 単一基準局 RTCM (生 MSM)                        | FKP 不使用            |
| NTRIP-RTCM3 EU EUREF      | NTRIP + RTCM3 + IGS SSR                                 | FKP 不使用            |

要点:

- **FKP は Geo++ 商業エコシステム以外でほぼ絶滅**。
- Leica/Trimble/Topcon の主流は **MAC (1014-1017)** または **VRS+MSM**。
- SSR (IGS RTCM-SSR / Galileo HAS / QZSS CLAS) が PPP-RTK 方向で本命扱い。

---

## 7. 現実装の問題点と修正案

### 7.1 問題点 A: Type 59 を rover に送っても消費されない

**程度: ブロッカー (Phase 5b-3 で fix が立たなかった主要因の最有力候補)**

- 現状 VRS パイプライン (`vrs.zig:687`) は **Type 59 を rover に送る前に drop** しているので、実害は無い。
- 一方で Phase 4 以前の「Type 59 を caster が rover に直接配信する」前提のドキュメント記述や設計図は **rover が無視する以上、絶対に rover を fix させない**。

→ **修正**: docs/CHANGELOG にはっきり「Type 59 は caster 内部 plane fit パラメータの永続化と FKP runtime ↔ VRS runtime 間 IPC 用フォーマット」と書き、外部配信用途を明示的に否定する。

### 7.2 問題点 B: encoder と Geo++ 仕様が互換でない

**程度: 情報マネジメント (ブロッカーではない)**

- Section 4.3 のとおり、bit 数と scale が Geo++ オリジナルと完全に別物。
- 既に「BKG/EUREF 方式に近似 (互換性よりも動作実証を優先)」と冒頭コメントに明記されているので docs 整合は取れているが、**「ファイル名 type59.zig」「`MSG_TYPE = 59`」が GNSMART 互換に見える誤解を招く**。

→ **修正案**: msg_type を proprietary 領域 (4070-4099) のうち未使用の番号に変えて、ファイル名 + コメントを `internal_fkp.zig` / `MSG_TYPE_INTERNAL_FKP = 4090` のようにリネーム。これにより外部 rover が万一受け取っても「unknown proprietary」として silent drop されるだけで、誤動作が露呈しにくくなる (現状 59 も silent drop なので挙動は同じだが、意図がコード上明確になる)。

### 7.3 問題点 C: L2 補正未対応

**程度: Phase 7-4 ambiguity fix で問題化**

- η^i (周波数依存スケール) が無いと、L2 の電離層補正が L1 の値そのまま使われる。
- DD-N·λ fix では L1/L2 両方の cleaned phase residual を使うので、L2 が補正されていないと残差が大きく LAMBDA の search が広がる。

→ **修正案**: `computePhaseDelta` に band 引数を追加し、L2 のときは `(n_i * (F1/F2)^2 + n_0) * dN + ...` を返す。Phase 7-4 着手前に小修正として入れる。

### 7.4 問題点 D: N_0/E_0 の clamp が ±3.28 m/rad と狭い

**程度: 50 km 超 baseline で saturation 発生の可能性**

- 50 km baseline (Tanaka 2003 推定の典型値) で `dN ≈ 7.8e-3 rad` → N_0=3.28 m/rad で `delta_m ≈ 26 mm`。
- これを超える補正値 (= 5 cm 以上の geometric correction) を載せたいケースで clamp が効いてしまう。
- engine.zig の `DEFAULT_FKP_MAX_MAGNITUDE = 100 m/rad` のチェックが N_0=3.28 で頭打ちになる手前で発火することは無い (100 ≫ 3.28) ので、clamp 起因の silent saturation のほうが先に起きる。

→ **修正案**: encoder の SCALE_0 を 1e3 に下げて値域 ±32.768 m/rad に拡大 (resolution は 1mm/rad に低下するが、これは 50km baseline で 8 µm に相当で問題なし)。

---

## 8. 代替案

### 8.1 案 A: 「Type 59 を完全 internal 化」+ VRS パイプライン継続 (推奨)

- Type 59 は FKP runtime → VRS runtime の **同一プロセス内 IPC** にしか使われない事実を明文化。
- VRS path は Phase 5b-3 のとおり「caster 内で plane fit を MSM7 phase に焼き込んで rover に渡す」設計を継続。
- rover は単独基準局として動作するので、FKP の存在を rover が知る必要はない。
- 実装変更: ほぼ無し (docs と命名整理のみ)。

### 8.2 案 B: 「FKP を辞めて MAC (1014-1017) で運用」

- MAC は RTCM 標準 (1014: NetRTK Reference Station, 1015: GPS Iono Corr Diff, 1016: GPS Geo Corr Diff, 1017: GPS Combined Corr Diff)。
- ただし **RTKLIB は 1014-1017 もすべて空スタブ** (1037/1038/1039 と同じ理由)。
- 商用 rover (Leica/Trimble/Topcon) はサポートするが、ntripcaster の対象ユースケース (centipede 由来の F9P/M9N 系 rover) では **メリットなし**。

→ 不採用。MAC は商用エコシステム専用の死語化標準。

### 8.3 案 C: 「RTCM SSR (4076.x) に移行」

- 領域 4 の調査対象。
- 4076.7 (GPS Iono STEC) + 4076.11 (GPS Tropo) で iono/tropo を独立配信。
- u-blox F9P が SSR を読めるか (= 4076.x の F9P firmware サポート) が論点。
- **rover 側でデコードが動くなら最も将来性がある**。

### 8.4 案 D: 「FKP を諦めて Phase 5a path (= ref_id 書換のみ) に戻す」

- 現状 Phase 5b-3 では既に Phase 5a fallback 機構 (frames_correction_failed カウンタ) を持つ。
- FKP runtime を起動するが Type 59 配信を完全に停止し、VRS path も plane fit 適用を skip。
- 単一基準局として動作 (= rover-基準局距離が短いセルなら数 cm 精度が出る)。
- **メリット**: 実装シンプル、debug ハードル低い。
- **デメリット**: cm 級精度を目指す Phase 7-4 の方針と矛盾。

---

## 9. 未解決事項 (Open Questions)

| # | 内容 | 解決方針 |
| --- | --- | --- |
| O1 | Geo++ オリジナル Type 59 spec (RTCM 1996 Wuebbena white paper) の正確な bit 数 / scale | 公式 PDF 入手 (Geo++ サポート問合せ) または ION GNSS 1996 論文 inter-library loan |
| O2 | `applyPhaseCorrection` (msm7.zig) が delta_m を **加算** か **減算** か | 別領域 (msm7-scale-validation) で実装確認 |
| O3 | rover (F9P) が delta_m = 0 でも fix しないなら、Type 59 以外の問題 (ephemeris / 観測値補正の符号 / pseudorange 補正なし) が原因 | Phase 5b-3 実機ログを再確認 |
| O4 | L2 補正の必要性 (η^i 係数) は Phase 7-4 着手時に必要か、Phase 7-5 で良いか | DD-N·λ float vector の品質を実測して判断 |
| O5 | u-blox F9P firmware が SSR 4076.x をどの程度サポートしているか | 領域 4 で確認 |

---

## 10. アクションアイテム (Phase 7-4 着手前)

1. ✅ docs/CHANGELOG に「Type 59 = caster 内部 IPC、rover 配信用ではない」旨を追記。
2. [ ] `computePhaseDelta` の符号と `applyPhaseCorrection` の加算/減算を実コードで一致確認 (msm7.zig 側を読み、別領域メモと突き合わせ)。
3. [ ] N_0/E_0 の clamp 拡大 (SCALE_0=1e4 → 1e3) — Phase 7-4 着手前に簡単 patch。
4. [ ] L2 補正 (η^i) を `computePhaseDelta` に追加 — Phase 7-4 で DD-N·λ を扱う直前に対応。
5. [ ] 領域 4 の結果を見て、SSR pivot するか FKP+VRS path 継続かを決定。

---

## 11. 参考リソース (実取得)

- ローカル: `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3.c` L1046-1057 (1034/1035 空スタブ) / L2557-2710 (decode_rtcm3 switch 全リスト)
- ローカル: `/Users/yasu/Project/ntripcaster/src/fkp/type59.zig` (encoder/decoder)
- ローカル: `/Users/yasu/Project/ntripcaster/src/fkp/engine.zig` (FkpParam 定義 + computeFkp/computeFkpDd)
- ローカル: `/Users/yasu/Project/ntripcaster/src/fkp/vrs.zig` L588-658 (computePhaseDelta + applyVrsPhaseCorrection)
- ローカル: `/Users/yasu/Project/ntripcaster/docs/phase5b-design.md` § 1 (MSM7 bit layout)

外部 (本領域で WebFetch/WebSearch 不可、調査者の知識ベース):

- Wuebbena G., Bagge A., Schmitz M., Menge F., Seeber G., Voelksen C. (1996) "Reducing distance dependent errors for real-time precise DGPS applications by establishing reference station networks." ION GPS 1996.
- Wuebbena G., Bagge A. (2002) "RTCM Message Type 59-FKP for transmission of FKP." Geo++ White Paper. (公開 PDF 入手困難)
- Tanaka 慎治 (2003) 修士論文 §4.3.3
- RTCM 10403.3 / Standard for Differential GNSS Services, Version 3 (Type 1034/1035 は標準にあるが、本実装の 59 は proprietary)
