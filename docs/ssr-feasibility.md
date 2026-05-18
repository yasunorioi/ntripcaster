# RTCM SSR 移行 実現可能性調査 (Phase 7-4 領域 4)

ntripcaster は現状 VRS + FKP (Type 59) で Network RTK を成立させる方向だが、
現代 NRTK の主流は SSR (State Space Representation = orbit / clock / bias /
ionosphere / troposphere を別メッセージで送る方式) に移行している。

Phase 7 (broadcast eph + orbit propagator) で構築中の資産は SSR でも再利用で
きるため、Type 59 を SSR に差し替える選択肢を Phase 7-4 着手前に評価する。

> 本書の主観的な記述 (採用状況、SSR/FKP 比較) は、公開情報 + ローカル RTKLIB
> ソース (`/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3*.c`) の grep 結果
> + 既存 ntripcaster コード読みに基づく。RTCM 10403.3 / SC-104 SSR WG の最新
> 動向は本セッションでは web access が拒否されたため、不明な箇所は明示して
> ある。

---

## 1. エグゼクティブサマリ

**推奨: 「FKP 継続」(Phase 7-4 / 7-5 で VRS+FKP を完成させる)、SSR 移行は当面
凍結。** 根拠:

1. **rover 側 SSR 受信は PPP / PPP-RTK 用であり cm 級 RTK を成立させる用途で
   は実装が薄い**。RTKLIB は SSR 1-7 (orbit / clock / code bias / URA /
   hi-rate clock / phase bias) を decode できるが、その後 `ppp_corr` 経由で
   PPP モードに渡されるパスのみ。NRTK / VRS の rover (rtkrcv の MODE_KINEMA)
   側で SSR 補正を受けつつ DD 観測する frontend は存在しない。
2. **NRTK 用の iono/tropo モデル化メッセージ (4076.7 STEC / 4076.11 tropo /
   1264 など) は RTKLIB に decoder すらない**。実装しても受信できる rover が
   ほぼ無く、テスト相手が居ない。
3. **Phase 7 の orbit/eph 資産は VRS でも 100% 活かせる**。SSR 化のための転機
   とする必然性が薄い。
4. **実装コストは Type 59 (127 行) → SSR フルセット (1500-2500 行) で約 15-
   20 倍**。現在の Phase 5b-3 で見えている "rover 側で fix しない" 問題が
   FKP 単位ミス起因なら、SSR 移行ではなく Type 59 の単位修正で済む。

ただし将来 Centipede / NICT の PPP-RTK サーバを補助する用途があれば、
SSR 1 + 2 + 3 + 7 (orbit / clock / code bias / phase bias) の encode-only 実装
は MSM7 と独立に進められる。SSR を「並行サポート」として後回しにする選択肢を
残す。

---

## 2. RTCM SSR メッセージ体系

### 2.1 RTCM SC-104 SSR Working Group の状況

- **RTCM SSR Phase 1** (2011 完成): 全球補正のみ。orbit / clock / code bias /
  URA / hi-rate clock の 6 メッセージ。GPS の MT 1057-1062、GLONASS の MT
  1063-1068。
- **RTCM SSR Phase 2** (2018 完成): phase bias 追加 (MT 1265-1270 が GPS の
  SSR 1-6 + 7、GLO は 1271-1276、Gal は 1240-1246、QZS は 1246-1252、BDS は
  1258-1264)。ただし phase bias 番号 1267 / 1273 等は RTKLIB の draft 実装と
  異なる場合あり (後述)。
- **RTCM IGS SSR (MT 4076)** (2020 制定): proprietary message 番号 4076 の中
  に subtype を持ち、SSR Phase 1 相当を全 GNSS で再標準化。subtype 21-27 が
  GPS、41-47 が GLO、61-67 が Gal、81-87 が QZS、101-107 が BDS、121-127 が
  SBAS。
- **NRTK 用 atmospheric SSR** (draft、未公開): STEC (4076.7?) / VTEC grid /
  troposphere (4076.11?) は SC-104 WG draft 段階。Geo++ / Trimble など各社が
  proprietary 拡張で先行運用。公開 spec は限定的。

### 2.2 主要メッセージ番号一覧 (RTKLIB 経由で確認)

RTKLIB `rtcm3.c` の case dispatch を grep した結果:

| MT     | 役割 (SSR タイプ)           | GNSS | RTKLIB    | 単位/scale         |
| ------ | --------------------------- | ---- | --------- | ------------------ |
| 1057   | SSR 1 GPS orbit correction  | GPS  | OK        | radial 1E-4 m / tangential 4E-4 m |
| 1058   | SSR 2 GPS clock correction  | GPS  | OK        | C0 1E-4 m, C1 1E-6, C2 2E-8 m/s² |
| 1059   | SSR 3 GPS code bias         | GPS  | OK        | 0.01 m / signal    |
| 1060   | SSR 4 GPS combined orb+clk  | GPS  | OK        | 上記の合体         |
| 1061   | SSR 5 GPS URA               | GPS  | OK        | 6-bit URA index    |
| 1062   | SSR 6 GPS hi-rate clock     | GPS  | OK        | 1E-4 m             |
| 1063-1068 | 同上 GLONASS             | GLO  | OK        | -                  |
| 1240-1245 | SSR 1-6 Galileo (draft)  | GAL  | OK (draft) | -                 |
| 1246-1251 | SSR 1-6 QZSS (draft)     | QZS  | OK (draft) | -                 |
| 1252-1257 | SSR 1-6 SBAS (draft)     | SBS  | OK (draft) | -                 |
| 1258-1263 | SSR 1-6 BeiDou (draft)   | BDS  | OK (draft) | -                 |
| 1265-1270 | SSR 7 phase bias GPS..BDS | (各) | OK (draft) | 0.0001 m         |
| 4076.21-27 | IGS SSR GPS (subtype)   | GPS  | OK        | 上 1057-1062 相当 |
| 4076.41-47 | IGS SSR GLO             | GLO  | OK        | -                  |
| 4076.61-67 | IGS SSR Galileo         | GAL  | OK        | -                  |
| 4076.81-87 | IGS SSR QZSS            | QZS  | OK        | -                  |
| 4076.101-107 | IGS SSR BeiDou        | BDS  | OK        | -                  |
| 4076.121-127 | IGS SSR SBAS          | SBS  | OK        | -                  |
| 4076.?  | IGS SSR STEC (atmospheric) | -   | **no** | unknown (NRTK 用)  |
| 4076.?  | IGS SSR Troposphere        | -   | **no** | unknown (NRTK 用)  |
| 4076.?  | IGS SSR VTEC grid          | -   | **no** | unknown            |
| 4072.1 | Geo++ NRT SSR (VRS-RTK)     | -   | **no** | proprietary、spec 非公開 |
| 4072.2 | Geo++ NRT SSR (補助)        | -   | **no** | proprietary、spec 非公開 |

> 表の「OK (draft)」は RTKLIB のソースコメントで `draft` と明示されている。
> Galileo の MT 1240-1246 は RTCM SSR Phase 2 で正式制定済だが、RTKLIB の
> dispatch コメントは古いまま。

### 2.3 spec 公開状況

- **RTCM 10403.3 (有料、$320 USD 程度)**: rtcm.org で購入可能。SSR 1-7 の bit
  layout / scale は ここでしか公式取得できない。
- **IGS BKG 公開資料 (https://files.igs.org, https://igs.bkg.bund.de)**: SSR の
  概要 + IGS Real-Time Service (RTS) の運用情報。SSR の意味論レベル (どの
  項目が何の補正か) は読める。bit-level の scale は spec 抜粋に頼る。
- **RTKLIB ソース**: `rtcm3.c` の `decode_ssr1` ~ `decode_ssr7` で bit 数と
  scale が読める。**spec が手元にない場合の事実上のリファレンス**。
- **Geo++ 4072.1 / 4072.2**: spec 非公開。Geo++ GNSMART 利用者向けに NDA 下
  で配布されている模様。**ntripcaster で 4072.x を実装する道は閉ざされてい
  る**。

---

## 3. FKP vs SSR 機能比較

| 機能          | FKP (Type 59)                     | RTCM SSR (1057-1068 + 4076)      |
| ------------- | --------------------------------- | --------------------------------- |
| Orbit error   | plane fit (N_0, E_0) で吸収       | 1057 で radial/along/cross の 3 軸補正 |
| Clock error   | 同上 (geometric plane に吸収)     | 1058 で C0/C1/C2 多項式           |
| Iono (STEC)   | plane fit (N_I, E_I) で吸収       | **未標準** (4076.7 draft、未実装) |
| Tropo (ZTD)   | (含まれていない、ZWD は 1005 不要) | **未標準** (4076.11 draft)        |
| Code bias     | (含まれていない)                  | 1059 / 1065 / 4076.25 等          |
| Phase bias    | (含まれていない)                  | 1265-1270 / 4076.26 等            |
| 計算空間      | 観測空間 (RTK と同じ位相距離)     | 状態空間 (衛星単独補正)           |
| 必要 rover    | NRTK / VRS 対応 rover (rtklib 2.4.3+)  | PPP / PPP-AR 対応 rover (rtklib ppp モード or u-blox HPS) |
| 適用先        | DD 観測の RTK 解 (cm 級)          | PPP / PPP-RTK (dm 級 → cm 級)     |
| Eph 依存      | 無 (rover 側で eph 推定不要)      | **必須** (rover が broadcast eph を保持し SSR で補正) |
| 単一基準局相当 | Type 1005 + MSM7 で VRS 成立      | 不要 (PPP-RTK は基準局不要)       |

**注**: SSR は本来 PPP / PPP-RTK のための補正であり、観測空間 (MSM7) の RTK
とは独立に動く。VRS + FKP path と直接置き換わるものではない。SSR を採用する
場合は ntripcaster の出力モデルそのものが「PPP-RTK サービス」に変わる。
これは Phase 4 から積み上げてきた VRS 設計 (cell radius, GGA 受信, rover ご
との ref_id 書換) のうち、cell radius 部分が無意味になることを意味する。

---

## 4. RTKLIB の SSR support 状況

ローカル `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3.c` (2710 行) /
`rtcm3e.c` (2734 行) の grep 結果:

### 4.1 Decoder (rtcm3.c)

| 関数           | 行    | 役割                          | 対応 GNSS               |
| -------------- | ----- | ----------------------------- | ----------------------- |
| `decode_ssr_epoch` | 1454 | epoch time 共通ヘッダー       | -                       |
| `decode_ssr1_head` | 1478 | SSR 1 / 4 ヘッダー (orbit用)  | GPS/GLO/Gal/QZS/BDS/SBS |
| `decode_ssr2_head` | 1520 | SSR 2 / 3 / 5 / 6 ヘッダー    | 同上                    |
| `decode_ssr1`  | 1556  | orbit correction              | 同上                    |
| `decode_ssr2`  | 1612  | clock correction              | 同上                    |
| `decode_ssr3`  | 1659  | satellite code biases         | 同上                    |
| `decode_ssr4`  | 1716  | combined orbit + clock        | 同上                    |
| `decode_ssr5`  | 1777  | URA                           | 同上                    |
| `decode_ssr6`  | 1819  | hi-rate clock                 | 同上                    |
| `decode_ssr7_head` | 1861 | SSR 7 ヘッダー (phase bias)   | 同上                    |
| `decode_ssr7`  | 1900  | phase bias                    | 同上                    |
| `decode_type4076` | 2493 | IGS SSR ラッパ (subtype 21-127) | 同上 (subtype で識別) |

dispatch (`decode_rtcm3` 末尾の switch、2611 行〜):

- 1057-1062: GPS SSR 1-6
- 1063-1068: GLO SSR 1-6
- 1240-1263: Galileo / QZSS / SBAS / BDS SSR 1-6 (draft コメントあり)
- 1265-1270: 上記 + Galileo phase bias / QZS phase bias / BDS phase bias
  (実装は decode_ssr7 で共通化)
- 4076: decode_type4076 経由で全 GNSS

### 4.2 Encoder (rtcm3e.c)

`encode_ssr1` ~ `encode_ssr7` + `encode_ssr_head` + `encode_type4076` が実装
されている (1382-1820 行ほどで 8 関数、約 450 行)。**つまり SSR encoder の C
リファレンス実装は ~450 行で書けている**。これを Zig に移植する規模感は同程
度 (Zig はパディングや bit packing が C より丁寧に書けるので +20% で約 540
行)。Phase 4076 encoder (subtype 経由でラップ) は +50 行程度。

### 4.3 NRTK 用 atmospheric SSR (STEC / Tropo / VTEC grid)

`grep stec STEC tropo VTEC iono.*ssr` の結果:

- `decode_type1023` (residual ellipsoidal grid)
- `decode_type1024` (residual plane grid)

しかこの 2 つは MSM 後の residual grid であり、SSR atmospheric ではない。
**STEC / VTEC / Tropo SSR (NRTK 用) は RTKLIB に decoder すら存在しない**。
これは SSR 移行のもっとも重大な欠点。SSR 1-7 だけでは:

- iono delay は rover が単独補正 (klobuchar / VTEC grid 不要)
- tropo delay は rover が saastamoinen 等で推定
- VRS のような "cell 内で iono / tropo を model 化" は不可能

結果として SSR で NRTK を行うには、4076.7 STEC + 4076.11 tropo のような
draft メッセージを **自前で encoder/decoder を書き、独自 rover 実装と組み合わ
せる** 必要が出る。Centipede / u-blox / NovAtel / Septentrio rover はこれを受
け取れない。

### 4.4 rtkpost / rtknavi での SSR 補正適用

RTKLIB の `rtkrcv` / `rtkpost` で SSR を使うには:

- 設定で `pos1-posmode = ppp-kinema` を選ぶ
- 補正源 (`misc-rtcmtype1` 等) で 1057-1062 を受ける
- RTKLIB 内部で `ppp_corr` (src/ppp_corr.c) が SSR を broadcast eph に適用し
  て post-fit clock / orbit を得る
- DD ベースの NRTK (`pos1-posmode = kinematic`) では SSR は使われない

**つまり VRS user に SSR をそのまま投げても rover 側で kinematic mode のま
までは無視される**。rover を PPP モードに切り替える必要があり、これは
ntripcaster のサービス境界 (= 「VRS / NTRIP mountpoint を提供するだけ」) を
逸脱する。

---

## 5. 既存 NRTK サービスの採用フォーマット

公開情報 + 既知の運用形態:

| サービス            | 主フォーマット        | 公開度                  | 備考 |
| ------------------- | --------------------- | ----------------------- | ---- |
| Centipede (FR)      | MSM (VRS なし、最寄基準局)  | 完全オープン (NTRIP) | rover は近傍局へ直接接続、補正なし生 MSM。VRS / FKP / SSR どれも使っていない。 |
| Trimble VRS Now     | VRS (MSM4/5/7)        | 商用 (NTRIP)            | rover GGA を受けて VRS 仮想局を合成。FKP は提供しない |
| Leica SmartNet      | MAX (Master-Auxiliary) + VRS | 商用                  | MAC (Master Auxiliary Concept) も提供 |
| Geo++ GNSMART       | FKP (Type 59) + 4072.1 + VRS | 商用 (NTRIP)        | Type 59 / 4072.x のオリジナル元 |
| 国土地理院 電子基準点 | 生 RTCM3 (MSM4) + 1ヶ月遅れの SP3 | 完全オープン       | リアルタイム NRTK は一般公開なし、商用利用は別 |
| 日本テラサット (NTT etc.) | VRS / FKP (Geo++ OEM) | 商用                  | Geo++ ライセンスで VRS+FKP |
| NICT MADOCA / CLAS  | SSR 1057-1062 + L6 binary | 開発者向け           | QZSS L6 経由 PPP-RTK、NTRIP 経由は MADOCA only |
| swisstopo swipos    | VRS (MSM) + MAC + FKP | 商用                    | 全フォーマット並行サポート (rover 互換性のため) |
| BKG SAPOS (DE)      | VRS + FKP + MAC + SSR (IGS RTS) | 公的 (有償)       | NRTK は VRS+FKP+MAC、SSR は IGS RTS 別チャネル |

**観察**:

1. **NRTK としての SSR 採用は実質ゼロ**。あるのは PPP-RTK / IGS RTS 用途。
2. **VRS は商用 NRTK の事実上の標準** (Trimble / Leica / Geo++ / swisstopo
   /BKG / 日本各社)。
3. **Centipede はあえて補正を載せず生 MSM を流す** (オープン側の流派)。
4. **FKP は Geo++ ライセンス受けたサービスのみ**で、独自実装は希少。
5. **MAC (Master-Aux Concept、MT 1014-1017)** は VRS よりさらに rover 側の
   計算を厚くする方式。Phase 7 の orbit propagator があれば実装可能だが採用
   サービスが限定的。

---

## 6. Zig 実装規模見積もり

### 6.1 SSR 単独 encoder の Zig 実装規模

RTKLIB `rtcm3e.c` の SSR encoder 8 関数 (約 450 C 行) を Zig に移植する場合:

| メッセージ          | C 行数 (rtcm3e.c)       | Zig 想定行数 |
| ------------------- | ----------------------- | ------------ |
| `encode_ssr_head`   | 1382-1476 (~95 行)      | ~120         |
| `encode_ssr1` (orbit) | 1477-1538 (~62 行)    | ~80          |
| `encode_ssr2` (clock) | 1539-1585 (~47 行)    | ~60          |
| `encode_ssr3` (code bias) | 1586-1638 (~53 行) | ~70          |
| `encode_ssr4` (combined) | 1639-1707 (~69 行)  | ~90          |
| `encode_ssr5` (URA)   | 1708-1749 (~42 行)    | ~50          |
| `encode_ssr6` (hi-rate clk) | 1750-1792 (~43 行) | ~55         |
| `encode_ssr7` (phase bias) | 1793-1860 (~68 行) | ~85          |
| `encode_type4076` ラッパ | 2557-...           | ~80          |
| signal ID table     | (rtcm3.c 145-170 行)    | ~80          |
| 合計                |                         | **~770 行**  |

これは encode-only で **decoder は含まない**。Phase 8 以降に decoder を書く
なら同程度の 800 行追加。

### 6.2 SSR + atmospheric (STEC / tropo) の追加

NRTK として SSR を成立させるには 4076.7 (STEC) + 4076.11 (tropo) + 4076 grid
(VTEC) 相当を書く必要がある。**spec を持っていない** ので bit layout を確定
できないが、機能 (per-sat slant TEC を polynomial fit、grid 経由で受け渡し)
から推定して:

| 機能           | 想定 Zig 行数 |
| -------------- | ------------- |
| STEC encoder (per-sat polynomial) | ~150 |
| Tropo encoder (per-station ZHD + ZWD + gradient) | ~120 |
| VTEC grid encoder (lat/lon grid + IPP) | ~250 |
| spec 解析 + テスト合わせ込み | ~300 |
| 合計           | **~820 行**  |

ただし spec が確定するまで実装着手できない (4076.7/4076.11 の bit layout が
公開されているか不明)。

### 6.3 総 Zig 実装規模

| シナリオ                          | 追加 Zig 行数    |
| --------------------------------- | ---------------- |
| SSR 1-7 のみ (PPP-RTK 補助)       | ~770             |
| SSR 1-7 + atmospheric (NRTK 化)   | ~1600 (内 atmospheric 820 行は spec 待ち) |
| SSR + decoder (将来の relay 用)   | +800             |
| 全部入り (RTKLIB 同等)            | ~2400            |

**`type59.zig` (127 行) と比較すると 6-20 倍**。質問の想定値 "1500-2000 行"
はおおむね正しい (atmospheric を抜けば 800、含めれば 1600)。

### 6.4 既存資産の流用

以下は SSR でもそのまま使える:

- `src/fkp/bits.zig` (BitReader/Writer + putBits)
- `src/ntrip/rtcm3.zig` (PREAMBLE / CRC24Q / frame header)
- `src/fkp/ephemeris.zig` (1019 GPS eph) — SSR の orbit correction は eph 起
  点で計算するので eph parser 必須
- `src/fkp/orbit.zig` (衛星 ECEF / 衛星時計補正 / Kepler 反復) — SSR の
  pre-fit orbit を作るのに使う

つまり Phase 7 で書いた **eph + orbit propagator は SSR 移行でも 100% 活か
せる**。SSR pivot のため Phase 7 を凍結する必要は無い。

---

## 7. Phase 7 既存資産との相性

| Phase 7 モジュール         | VRS+FKP path での役割     | SSR path での役割           |
| -------------------------- | ------------------------- | --------------------------- |
| `fkp/ephemeris.zig` (1019) | 衛星 ECEF 計算            | SSR orbit correction の起点 |
| `fkp/orbit.zig` (Kepler)   | DD residual 計算          | broadcast orbit pre-fit     |
| `fkp/engine.zig` (FKP fit) | plane fit (N_*, E_*)      | (不要、SSR は state ごと)   |
| `fkp/type59.zig`           | FKP encoder               | (不要)                      |
| `fkp/msm7.zig`             | MSM7 encoder + 補正適用   | (VRS path のままなら必要)   |
| `fkp/vrs.zig` (Runtime)    | rover GGA / cell / inject | (PPP-RTK にしたら全部不要)  |
| `fkp/upstream.zig`         | 上流 NTRIP 接続           | (SSR 化しても上流 mountpoint からの観測は必要、ただし SSR を inject するだけなら不要) |

**観察**:

- SSR 化しても `ephemeris.zig` + `orbit.zig` (合計 444 行) はそのまま使える
- `engine.zig` (FKP fit、501 行) + `type59.zig` (127 行) + `msm7.zig` 補正適
  用部 (Phase 5b で追加された部分) + `vrs.zig` 大半 (1056 行) は **不要にな
  る**
- 「SSR pivot = 既存 Phase 4/5/6 の VRS インフラ 1500+ 行を捨てる」ことを
  意味する。Phase 7 の eph + orbit は活きるが、Phase 4-6 の積み上げは消える

---

## 8. 意思決定マトリクス

| 案               | メリット                              | デメリット                                    |
| ---------------- | ------------------------------------- | --------------------------------------------- |
| **A. FKP 継続**  | - 既存資産 100% 活用                  | - 単位ミス / Phase 5b-3 で fix しない問題が残る |
|                  | - Phase 7-3 まで完成済                | - rover 側 Type 59 適用が rtklib に無く検証困難 |
|                  | - 実装規模 +0 行                      | - "現代的" でないと外野から見られる            |
|                  | - VRS / FKP は商用 NRTK の主流        | - Geo++ ライセンス文化に近い proprietary 感   |
| **B. SSR 移行**  | - "現代的" な NRTK アーキ             | - VRS インフラ ~1500 行を破棄                  |
|                  | - PPP-RTK 用 rover (madoca, u-blox HPS) と互換 | - atmospheric SSR spec が公開されていない |
|                  | - eph + orbit 資産は活きる            | - rover 側で kinematic ↔ ppp 切替が要る       |
|                  | - 商用 SSR サービス (IGS RTS) と相互運用 | - 追加 +1500-2000 行                         |
|                  |                                       | - rover 検証相手が少ない (RTKLIB ppp_kinema 限定) |
| **C. 並行サポート** | - rover 選択肢の幅が広い            | - 実装規模 +1500 行 + 既存 1500 行維持        |
|                  | - SSR は IGS RTS 風の補助に留め、メイン路は VRS+FKP のまま | - 並行運用テストの複雑化 |
|                  |                                       | - 出力 mountpoint が増えてオペレーション複雑化 |

評価軸ごとの定量化 (5 = 最良):

| 軸                       | A. FKP 継続 | B. SSR 移行 | C. 並行サポート |
| ------------------------ | ----------- | ----------- | ---------------- |
| 実装コスト (低い方が良い) | 5           | 1           | 1                |
| Phase 7 資産の活用率      | 5           | 3           | 5                |
| Phase 4-6 資産の活用率    | 5           | 1           | 5                |
| rover 側受信機の広さ      | 4 (商用 NRTK rover 全般) | 2 (RTKLIB ppp / u-blox HPS のみ) | 5 (両方) |
| 検証相手 (NRTK rover) の入手しやすさ | 4 (rtklib kinematic) | 2 | 4 |
| 将来性 / 業界主流度       | 3 (legacy だが現役) | 4 (PPP-RTK 方向) | 4 (両対応) |
| spec 公開度               | 3 (Type 59 は proprietary だが運用ノウハウあり) | 4 (SSR 1-7 は公開、atmospheric は未) | 3 |
| **合計**                  | **29**      | **17**      | **27**           |

---

## 9. 推奨パス

### 推奨: A. FKP 継続 (Phase 7-4 / 7-5 で VRS+FKP を完成させる)

**根拠**:

1. **コスト最小・既存資産最大活用**。Phase 7-3 まで来ている DD residual パ
   イプラインを SSR pivot で捨てるには「VRS では絶対に解決しない問題」が必
   要だが、現状の Phase 5b-3 で見えている問題 (rover で fix しない) は単位ミ
   ス起因の可能性が高く SSR 移行の正当な動機にはならない。
2. **rover 互換性**。VRS+FKP は商用 NRTK で広く使われており、rtklib /
   u-blox / NovAtel / Trimble の kinematic mode rover で受け取れる。SSR は
   PPP-RTK モード rover が前提で、ntripcaster の典型ユーザ層 (オープン NRTK
   ノードを立てたい人) と相性が悪い。
3. **atmospheric SSR の spec 不明**。STEC / Tropo / VTEC grid の bit layout
   が公開されていない以上、ntripcaster で NRTK 用 SSR を実装すると Geo++ や
   Trimble の proprietary 拡張に屈する形になり、Type 59 と同じ「proprietary
   依存」問題を別の形で抱える。
4. **業界の SSR は PPP-RTK 方向**。IGS RTS / CLAS / Galileo HAS のような
   グローバル PPP サービスで標準化が進んでいるが、ntripcaster が目指す「ロー
   カル基準局を VRS 化する」用途とは別レイヤ。

### 次善: C. 並行サポート (Phase 8 以降)

VRS+FKP path が完成したあと、Phase 8 以降で SSR encoder を追加して "ntripcaster
が IGS RTS proxy / 補助ストリームも出せる" 状態を作る。これは:

- `encode_ssr1` / `encode_ssr2` / `encode_ssr4` の 3 個だけでも価値あり
  (orbit + clock + 合体)。実装規模 ~250 Zig 行。
- 上流 IGS RTS (CLK00 / CLK91 など) を pass-through する relay として動かす
  なら、encoder すら不要で decoder + 統計だけで済む。

### 非推奨: B. SSR 移行 (フル pivot)

VRS インフラを破棄する負債が大きすぎる。Phase 7 で書いた eph + orbit が活
かせるとは言え、Phase 4/5/6 を捨てる経済的合理性はない。

---

## 10. 開いている疑問 (本セッションで解決できなかったもの)

| # | 疑問                                                | 解決方法 |
| - | --------------------------------------------------- | -------- |
| Q1 | atmospheric SSR (STEC / tropo / VTEC grid) の bit layout は公開されているか | RTCM 10403.4 (2023?) の有料 spec を購入するか、IGS RTS draft を bkg.bund.de から DL |
| Q2 | Geo++ 4072.1 / 4072.2 の spec を NDA 無しで読めるか | Geo++ に問い合わせ、または公開論文 (Wuebbena 2005, 2010) を探す |
| Q3 | rtklib `pos1-posmode=ppp-kinema` で SSR + 基準局 MSM を併用して RTK fix まで持っていけるか | rtklib config 試験 (本セッション外) |
| Q4 | Centipede が将来 SSR 出力に転向する計画があるか     | docs.centipede.fr / GitHub issue を確認 (web access 必要) |
| Q5 | madoca / CLAS L6 binary の RTCM 4072 / 4076 マッピング | NICT の MADOCA-PPP 仕様書を確認 |

---

## 11. 結論

**Phase 7-4 では「FKP 継続」を採用し、Type 59 単位ミスマッチ / MLAMBDA 統合
の本筋に集中する**。SSR は将来オプション (Phase 8 以降の "並行サポート" の
形) として温存し、当面は実装に着手しない。

Phase 7 で書く eph + orbit propagator は SSR でも再利用できるため、将来 SSR
pivot する判断をした時の負債は最小化されている。

---

## 12. 参考 (本調査で実際に読んだ / 確認したもの)

- `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3.c` (decode_ssr1-7,
  decode_type4076, dispatch case 1057-1068 / 1240-1270 / 4076)
- `/Users/yasu/Project/PocketSDR/lib/RTKLIB/src/rtcm3e.c` (encode_ssr1-7,
  encode_type4076, encode_type4073)
- `/Users/yasu/Project/ntripcaster/src/fkp/type59.zig` (127 行、SCALE_I / SCALE_0)
- `/Users/yasu/Project/ntripcaster/src/fkp/ephemeris.zig` (RTCM 1019 parser)
- `/Users/yasu/Project/ntripcaster/src/fkp/orbit.zig` (Kepler / SatPosition)
- `/Users/yasu/Project/ntripcaster/src/fkp/vrs.zig` (Runtime, GGA, ref_id 書換)
- `/Users/yasu/Project/ntripcaster/docs/phase7-4-research.md` (本調査の親文書)

(本セッションで rtcm.org / igs.bkg.bund.de / files.igs.org / docs.centipede.fr
への web access は拒否された。spec / 採用状況は手元の RTKLIB ソース + 既存
知識ベースの推定に基づく。)
