# Phase 7-4 先行調査メモ — DD-N·λ ambiguity fix の実装方針決定前

Phase 7-3 (ephemeris ベース DD residual) まで完成し、次は DD-N·λ の整数
アンビギュイティを fix する。実装案が 3 つあり (MLAMBDA フル / bootstrapping /
float averaging)、それぞれ精度・工数・実装難度のトレードオフがある。実装に
入る前に 4 領域を調査し、根拠に基づいた選択をする。

調査の結果次第で:
- Phase 7-4 を MLAMBDA で進めるか、もっと軽量な手法で済ますか
- 現状の MSM7 fine_phase scale (2^-29 ms) に bug がないか
- Type 59 FKP の plane fit 単位 (m/rad) が rover 側と一致しているか
- そもそも FKP path を辞めて RTCM SSR (4072) に乗り換えるか

を決定する。

---

## 領域 1: LAMBDA / MLAMBDA の参考実装

### 目的

DD-N·λ float vector + 共分散行列 → 整数最小二乗解の Zig 実装方針を確定する。
「ゼロから書く」と「既存実装を移植する」のトレードオフを評価。

### 調査タスク

1. **RTKLIB `src/lambda.c`** (C, ~600 行) を読む
   - `lambda(int n, int m, const double *a, const double *Q, double *F, double *s)`
     のシグネチャ
   - LDL 分解 (`LD` 関数) の数値安定性 (pivoting あり / なし)
   - Z 整数変換 (`reduction` 関数) の Gauss elimination ベース
   - 整数 search (`search` 関数) の depth-first + shrink
   - ratio test の閾値 (typically 2.0 or 3.0)
   - 配置: RTKLIB GitHub mirror で URL を確認

2. **rinex-rs / rtklib-rs** (Rust port) を確認
   - GitHub で検索: "rtklib rust lambda" / "MLAMBDA rust" / "GNSS rust ambiguity"
   - もし存在すれば Zig からの移植難度を評価 (Rust の `nalgebra` 等の依存解消)

3. **goGPS / RTKLIB-Python (pyrtklib)** を確認
   - Python 実装は読みやすいので algorithm 確認用
   - 数値テストデータの取り出し方を確認 (PRN / float ambiguity / Q matrix 例)

4. **Chang & Zhou (2005) MLAMBDA 論文** (academic)
   - 元論文 PDF を探す (Google Scholar / arxiv)
   - LAMBDA との差分 (decorrelation + search shrink) を整理
   - 数値安定性のチューニング箇所を特定

### 期待アウトプット

`docs/lambda-research.md` (新規) に:
- 各実装のソースリンク + 行数 + 依存ライブラリ
- 「Zig でゼロから書く」と「Rust crate を呼ぶ」「C library 経由」の比較表
- 推奨実装方針 (full MLAMBDA / bootstrapping / 第三案) と根拠

### 工数見積

3-5 時間 (Agent 並列実行で実時間短縮可)

---

## 領域 2: MSM7 fine_phase scale の検証

### 目的

`src/fkp/msm7.zig::extractPhase` で fine_phase × `1/(1<<29)` ms と扱っているが、
これが MSM7 spec (RTCM 10403.3 § 3.5.16) の正しい scale か確認する。
仕様によっては 2^-31 ms / 2^-30 ms の可能性があり、これだと全 FKP 計算の
スケールが factor 4 (or 2) ずれている。

Phase 5b-3 実機テストで rover への補正値が clamp ヒットしていた一因の可能性。

### 調査タスク

1. **RTCM 10403.3 spec の DF401 を確認** (PDF 持ってる前提、なければ web で探す)
   - DF401 (Fine PhaseRange) の bit 数と scale
   - MSM5 (type 5) と MSM7 (type 7) で scale が違うか
   - MSM4 (22 bit, 2^-29 ms) vs MSM6/7 (24 bit, 2^-31 ms?) の差

2. **RTKLIB `src/rtcm3.c::decode_msm7`** を読む
   - signal data block のパース順序と各 field の scale 定数
   - 特に `pr` (pseudorange) と `cp` (carrier phase) の単位変換

3. **既知の MSM7 dump (centipede-paris PRN1 など) で算出値を比較**
   - 同じ raw payload を RTKLIB と `extractPhase` でデコードして phase_m 値
     を突き合わせ
   - もし factor 4 ずれていれば scale bug 確定

4. **Phase 7-3 の `synthPhase` ヘルパー (test_fkp.zig) で値域確認**
   - `gpsSatEcef(eph_5)` → ρ ≈ 20-26 Mm
   - `synthPhase` の戻り値が ρ + c·dt ≈ 20-26 Mm + ±数百 m (clock)
   - もし fine_phase scale 誤りなら、現実の MSM7 入力 phase_m 値が予測と
     factor で乖離する → ロギングで確認

### 期待アウトプット

`docs/msm7-scale-validation.md`:
- 仕様抜粋 + RTKLIB 参照箇所 + 既存実装比較
- 「現実装が正しい / scale 修正が必要」の結論 + 必要なら 1-line patch

### 工数見積

1-2 時間

---

## 領域 3: Network RTK FKP の rover 側実装 (Type 59 適用例)

### 目的

`src/fkp/type59.zig` の encode 出力 (Type 59 ≈ proprietary Geo++ FKP) を
rover (RTKLIB / u-blox / NovAtel) がどう解釈し、どの単位で適用しているかを
確認する。現状の `n_*, e_*` が m/rad なのか deg/m なのか、rover との整合性
を検証。

Phase 5b-3 で rover の RTK fix が出なかった一因が「rover が補正を逆方向に
適用していた」「単位ミスマッチ」だった可能性もある。

### 調査タスク

1. **RTKLIB が Type 59 (proprietary) を受け取るか確認**
   - `src/rtcm3.c` で 4088 / 4090 / 59 を grep
   - もし decoder があれば、その plane fit 適用ロジックを読む

2. **BKG NTRIP Client 仕様 / Geo++ GNSMART** を web 検索
   - "FKP RTCM 59 format" / "Geo++ FKP encoding"
   - 公式仕様書 (Wuebbena 2001 paper / BKG NTRIP wiki)

3. **既存 Zig 実装 `src/fkp/type59.zig` を確認**
   - encode 時の単位 (m/rad? m/deg?)
   - bit layout が spec 準拠か検証

4. **rover OSS のソース** を確認
   - rtklib / rtknavi / strsvr2 / pyrtklib などで FKP decode 部分
   - 「rover が補正を加算 / 減算するか」の sign convention

### 期待アウトプット

`docs/type59-rover-side.md`:
- Type 59 の rover 側適用フロー (デコード → 補正適用 → SD 計算前 or 後)
- 単位整合性 (m/rad で send → m/rad で受け取り適用 が一致するか)
- 既知の問題があれば encoder 側の修正案

### 工数見積

2-3 時間

---

## 領域 4: RTCM SSR (State Space Representation) への乗り換え検討

### 目的

FKP は legacy 設計で、現代 NRTK は SSR (RTCM 4072 シリーズ) で iono / tropo /
orbit を別々に送るのが主流。VRS+FKP path を諦めて SSR 化する選択肢を評価。

SSR は ephemeris (1019 etc.) と独立に動くため、Phase 7 で構築中の orbit
propagator + SD residual パイプラインは活かせる。

### 調査タスク

1. **RTCM 4072.1 / 4072.2 (NRT SSR for VRS-RTK by Geo++) を確認**
   - spec 公開元、フリーで読めるか
   - 4076 GPS SSR (orbit/clock) / 4076.7 GPS iono (STEC) / 4076.11 GPS tropo
     の使い分け

2. **RTKLIB の SSR support 状況**
   - "rtklib ssr" grep / RTKLIB 公式 manual
   - rtkpost / rtknavi で SSR 補正適用が working か

3. **既存 NRTK サービス** (CenterFix / Centipede / Trimble VRS-Now) で
   どのフォーマット (FKP / VRS / SSR / MAC) を採用しているか確認

4. **Zig での SSR encoder 実装規模**
   - メッセージ数が多い (10+ type)
   - 既存 `type59.zig` (~150 行) と比較してどのくらい増えるか

### 期待アウトプット

`docs/ssr-feasibility.md`:
- FKP vs SSR の機能比較表
- ntripcaster で SSR 化する場合の追加実装規模見積もり
- 推奨パス (FKP 継続 / SSR 移行 / 並行サポート)

### 工数見積

2-3 時間

---

## 調査の進め方

### セッション 1 (本セッション完了済): リリース + 調査メモ作成

- ✅ v0.4.0 タグ付与 + master マージ
- ✅ 本ドキュメント作成

### セッション 2 (次): 4 領域の並列調査

Agent (Explore / general-purpose) で 4 領域を並列実行:

```
Agent #1: LAMBDA 参考実装 (RTKLIB lambda.c + Rust 実装 + 論文)
Agent #2: MSM7 scale 検証 (RTCM spec + RTKLIB decode_msm7 + 数値突き合わせ)
Agent #3: Type 59 rover side (RTKLIB + Geo++ spec + sign convention)
Agent #4: RTCM SSR (4072 シリーズ仕様 + RTKLIB support + 既存サービス採用状況)
```

各 Agent は調査結果を `docs/{lambda-research,msm7-scale-validation,type59-rover-side,ssr-feasibility}.md` に書き、最後にメインスレッドが結果を統合して Phase 7-4 方針を決定。

### セッション 3 (見込): 方針確定 + 実装ブランチ派生

調査結果をふまえて Phase 7-4 の実装方針 (3 案のどれか) を確定し、
`phase7-lambda` などのブランチを切って実装着手。

---

## 開いている疑問 (Open Questions)

| # | 疑問 | 解決時期 |
| --- | --- | --- |
| Q1 | MLAMBDA の Zig フル実装は実用的か? それとも C 経由が良いか | 領域 1 |
| Q2 | bootstrapping (simple rounding) で fix 率がどの程度落ちるか | 領域 1 |
| Q3 | MSM7 fine_phase scale は 2^-29 ms で正しいか (RTKLIB との一致) | 領域 2 |
| Q4 | rover が Type 59 を受け取れない / 解釈できない可能性 | 領域 3 |
| Q5 | RTCM SSR (4072) が現実的な代替か、それとも仕様が公開されていないか | 領域 4 |
| Q6 | Phase 7-3 で実装した `computeFkpDd` の出力 magnitude を実機で計測 | セッション 3 |
| Q7 | cycle slip 検出 (lock_time monitoring) は Phase 7-4 で必要か、Phase 7-5 で良いか | セッション 3 |

---

## 参考リソース

調査開始用ブックマーク:

- RTKLIB GitHub: https://github.com/tomojitakasu/RTKLIB
- RTCM 10403.3 (有料、IGS で部分公開): https://www.rtcm.org
- Tanaka 慎治 (2003) 修論: ネットワークRTK-GPS測位
- Teunissen P.J.G. (1995) "LAMBDA method" JGPS
- Chang & Zhou (2005) "MLAMBDA"
- Wuebbena G. (2001) "Network RTK FKP" InsideGNSS / GPS Solutions
- Geo++ GNSMART (NRTK service): http://www.geopp.de
- Centipede RTK (用例): https://docs.centipede.fr

---

## 完了条件

本 phase の調査が完了したと言える条件:

1. 4 領域の調査 memo (`docs/{lambda-research,msm7-scale-validation,type59-rover-side,ssr-feasibility}.md`) が揃う
2. Phase 7-4 の実装方針が 1 つに絞られる (MLAMBDA / bootstrapping / SSR pivot / 等)
3. 新ブランチ名と最初の作業項目が確定する
4. CHANGELOG の `[unreleased]` セクションを実装方針に合わせて更新

その状態で次セッションを開始し、実装に入る。
