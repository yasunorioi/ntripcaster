# Phase 7-3.5 検証メモ (2026-05-18)

MSM7 parser バグ修正 (field-major layout + fine_phase 2^-31 ms) の実機検証。
RTKLIB CLI tools (convbin / rtkrcv) を用いて二段階で確認した。

## 環境

- macOS 26.3.1 ARM、Apple Silicon
- Zig 0.15.2 (docker linux/arm64 `ntripcaster-zig:0.15.2` で build)
- RTKLIB master (commit 不明、2026-05 時点) を `/tmp/rtklib-build` に clone
  - app/rtkrcv/gcc/makefile を `-std=gnu99 -D_DARWIN_C_SOURCE` で patch して build
  - `LDLIBS=-lm -lpthread` (Linux 専用 `-lrt` を除外)
  - rtkrcv / str2str / convbin の 3 つの CLI を build 成功

## 段階 1: convbin による binary cross-decode

ntripcaster (Phase 7-3.5 修正済) の `/VRS_PARIS` 出力が RTKLIB convbin で
正しく RINEX に変換できるかを検証。

### 手順

```bash
# caster 起動
docker run -d --name nc-test --platform linux/arm64 \
  -v "$PWD":/work -p 12101:12101 ntripcaster-zig:0.15.2 \
  sh -c "cd /work && zig build -Doptimize=ReleaseSafe && \
         ./zig-out/bin/ntripcaster -c conf/centipede-paris.conf"

# 60s キャプチャ
str2str -in 'ntrip://localhost:12101/VRS_PARIS' \
        -out 'file:///tmp/vrs_paris.bin' \
        -p 48.72 2.28 50 -n 5000

# 比較用: 上流 CROI を直接キャプチャ
str2str -in 'ntrip://caster.centipede.fr:2101/CROI' \
        -out 'file:///tmp/croi_direct.bin' -n 5000

# RINEX 変換 (両方とも -tr で時刻 hint 必須)
convbin -r rtcm3 -tr 2026/5/18 4:55:00 -v 3.04 \
  -o /tmp/vrs_paris.obs -n /tmp/vrs_paris.nav \
  -g /tmp/vrs_paris.gnav -h /tmp/vrs_paris.hnav \
  -q /tmp/vrs_paris.qnav -l /tmp/vrs_paris.lnav \
  -s /tmp/vrs_paris.sbas \
  /tmp/vrs_paris.bin
```

### 結果

| 入力 | 経路 | epoch 数 | sat 数 | サンプル PRN | pseudo [m] | phase [cycles] | cycle×λ [m] |
| --- | --- | --- | --- | --- | --- | --- | --- |
| centipede.fr/CROI | 直結 | 29 | 31 | G04 | 25,011,382 | 131,436,431 | 25,001,810 |
| ntripcaster/VRS_PARIS | Phase 7-3.5 経由 | 59 | 30 | R04 | 22,860,052 | 122,414,485 | 22,851,505 |

(R04 λ = c/1,602.5625 MHz ≈ 0.18705 m、CN0 mask 通った frames だけ集計)

**両者とも phase × λ ≈ pseudo (Mm スケール一致)** で **物理的に妥当**。CRC は
両方とも整合し convbin が full RINEX (header + 全 epoch obs + nav) を生成。

### 結論

Phase 7-3.5 修正 (field-major layout + fine_phase 2^-31 ms) は RTKLIB
互換であることが確認できた。前の cell-major / 2^-29 ms 実装では
convbin が obs body を出せなかったはず (構造的に bit 位置がズレるため)
が、修正後は **完全に動作**。

成果物 fixture (binary cross-decode のレグレッションテスト化に有用):
- `/tmp/vrs_paris.bin` (159 KB) — Phase 7-3.5 修正済 caster 出力
- `/tmp/croi_direct.bin` (78 KB) — 上流生 RTCM3 (比較ベース)
- `/tmp/vrs_paris.obs` (191 KB) — convbin 出力 RINEX OBS
- `/tmp/croi_direct.obs` (96 KB) — 同上 (CROI 直結)

## 段階 2: rtkrcv による RTK fix 試行

`rtkrcv` で base=`/VRS_PARIS`、rover=`caster.centipede.fr/CDFX` (~22 km
baseline) でフル RTK パイプラインを走らせて fix が立つか確認。

### 設定

`/tmp/rtkrcv-ntripcaster.conf` (本セッションで作成):
- inpstr1 (rover) = ntrip://caster.centipede.fr:2101/CDFX
- inpstr2 (base) = ntrip://localhost:12101/VRS_PARIS + NMEA GGA (48.707, 1.980)
- pos1-posmode = kinematic
- pos1-frequency = l1+l2
- pos1-navsys = 47 (GPS + SBAS + GLO + GAL + BDS)
- pos2-armode = continuous, arthres = 3.0
- ant2-postype = llh (rover 公称 (48.707, 1.980))

### 起動

```bash
rtkrcv -s -p 52001 -o /tmp/rtkrcv-ntripcaster.conf -t 2 \
       < /dev/null > /tmp/rtkrcv.log 2>&1 &
```

`/tmp/rtkrcv_sol.pos` に LLH solution が 1 Hz で書き出される。

### 結果

| 観測時間 | epoch 数 | Q=1 (fix) | Q=2 (float) | Q=5 (single) | ratio |
| --- | ---: | ---: | ---: | ---: | --- |
| 858s (~14 分) | 858 | 0 | 0 | **858** | **0.0** |

**全 epoch が Q=5 (single point)、ratio=0.0 → LAMBDA は試行すらされて
いない**。age=1.00 で base 受信は OK、ns=18 で衛星数も十分。

サンプル solution (rover CDFX 公称 48.7070/1.9800 に対して):

```
2026/05/18 06:45:56.000  48.7070...  1.9795...  205.5... Q=5 ns=18 age=1.00 ratio=0.0
```

single point GPS 精度 (~5-10m) で偶然マッチしているだけで、RTK 補正の効果なし。

### 根本原因

`Phase 7-3.5 修正 (MSM7 parser) が問題ではない`。Phase 5b/6a の VRS+FKP
設計の根本問題が露呈した:

1. **VRS の inject 1005 座標 = rover 近傍 (48.72, 2.28) を申告**
2. **MSM7 観測値は元 CROI (物理基準局) のもの**、ref_id だけ書き換え (Phase 5a)
3. `applyPhaseCorrection` は empty deltas で no-op (Phase 6a で全 PRN 閾値超過棄却)
4. → rtkrcv は「(48.72, 2.28) で取れた MSM7」と解釈、でも実際は CROI 位置の
   観測 → DD = (CDFX - VRS_center) に CROI と VRS_center の baseline (~10 km)
   差が乗る → DD 残差が km スケール → ratio test 通らず Q=5 のまま
5. **LAMBDA は試行されない** (DD 残差が大きすぎると ar 候補が探索されない)

### 結論

Phase 7-3.5 修正は MSM7 parser を正しく field-major + 2^-31 ms に直したが、
これだけでは RTK fix までは到達できない。

Phase 7-4 (DD-N·λ ambiguity fix) + Phase 7-5 (runtime 配線で computeFkpDd
の出力を applyPhaseCorrection に流す) を実装する **論理的必然性が改めて
確認された**。

特に Phase 7-5 で重要なのは:

- VRS 仮想 1005 の coord (= rover 近傍) と一致するように **MSM7 の phase
  観測値を applyPhaseCorrection で書き換える**こと
- 書き換え量は `computeFkpDd` が出す DD residual + N·λ fix した値
- 現状 (Phase 6a) は applyPhaseCorrection が no-op (empty deltas) なので
  rover に届く MSM7 は CROI 位置のものそのまま → 不整合

つまり Phase 7-4/7-5 で:
- DD residual を物理妥当範囲 (cm-scale) に落とす (= Phase 7-4 LAMBDA)
- 結果を applyPhaseCorrection の delta として inject (= Phase 7-5 配線)

これで rover には「VRS_center 位置で取れたであろう仮想観測値」が届き、
DD 残差が cm scale になり LAMBDA fix も DD-only で完結する。

## 次セッション

1. Phase 7-4 (Bootstrapping → 必要なら MLAMBDA) で DD-N·λ ambiguity fix
2. Phase 7-5 で computeFkpDd → applyPhaseCorrection delta の runtime 配線
3. 本検証を再実行 (rtkrcv で /VRS_PARIS @ rover=CDFX) して fix が立つか確認
4. fix が立てば Phase 7 はメインゴール達成
