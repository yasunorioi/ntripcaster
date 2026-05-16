# VRS (Virtual Reference Station) 設計ドラフト

Phase 3 で FKP runtime が動いたあと、Phase 4 として VRS 方式を実装するための設計メモ。実装はまだ着手していない。

## なぜ VRS が必要か

Phase 3 の FKP 方式は技術的には完全な Network RTK だが、rover 側に **RTCM3 Type 59 (FKP) 対応** が要求される。実際の RTK 受信機の対応状況:

| 受信機 | Type 59 対応 |
|--------|--------------|
| u-blox ZED-F9P / ZED-F9R | ✗ (無視) |
| Septentrio mosaic / AsteRx | ◯ |
| Trimble BD9xx | ◯ |
| NovAtel OEM7 | △ (構成依存) |

農機向けで使いやすい u-blox / 安価 RTK モジュールは FKP 非対応。Type 59 を受信しても black-hole で fix 精度向上に寄与しない。

VRS なら **rover は標準 MSM7 + 1005 だけ受け取れば良い** ので、どの RTK 受信機でも fix 改善が得られる。これが実運用上の本命。

## VRS 動作フロー

```
   Rover                          Caster                          Upstream bases (3+)
   ─────                          ──────                          ─────────────────────
   
   GET /VRS_AUTO ─────────────────►  認証
                                  ◄─── ICY 200 OK ───────────────
   $GPGGA (10s ごと) ─────────────►  GGA パース → rover 位置更新
                                  │  
                                  │  for each rover:
                                  │    1. 3 局から MSM7 取得 (FKP runtime と共有)
                                  │    2. FKP パラメータで rover 位置への補正計算
                                  │    3. 「rover 位置に居る仮想基準局」を合成
                                  │       - Type 1005 (rover lat/lon を ECEF に変換)
                                  │       - Type 1077/1087/1097 (補正済 MSM7)
                                  │    4. RTCM3 にエンコード
                                  ◄─── 標準 RTCM3 stream ────────► 上流接続維持
   通常 RTK 処理 ────────────────►   (rover からは「近くの基準局」に見える)
```

## FKP との比較

| 項目 | FKP (Phase 3, 実装済) | VRS (Phase 4, 設計中) |
|------|------------------------|------------------------|
| 受信側必要対応 | Type 59 パース + 補正適用 | 標準 RTCM3 のみ (any RTK rover) |
| caster 計算量 | 1 回計算 → 全 rover にブロードキャスト | rover 数 × 合成計算 |
| 通信パス | 共有 RingBuffer (M クライアントに 1 ストリーム) | rover ごとに別ストリーム |
| GGA up | 不要 | 必須 (10s 間隔程度) |
| カバレッジ | FKP セル内 (固定 3 局) | rover 位置がセル内ならどこでも (動的合成) |

## 実装フェーズ分割

### Phase 4a: GGA 受信パス (client.zig 拡張)

現状の `client.zig::clientLoop()` はリングバッファ → 書き出しの **書き専用**。VRS マウントの場合、rover からの GGA を **読みつつ書く** 必要があるので双方向化が必要。

最小構成:
- mountpoint が `vrs_mountpoint` 設定値とマッチしたら VRS モードに分岐
- 各 rover に `*VrsRover` を割り当て (位置 + 出力バッファ + 状態)
- TCP socket を nonblocking にして読み書き両方を 1 スレッドで多重化
- 受信は `$G[NP]GGA,...*XX\r\n` だけ拾えば良いので、ASCII 行検出 + checksum 検証

実装ファイル:
- `src/fkp/vrs.zig` (新規): `VrsRover`、`VrsRuntime`、合成ロジック
- `src/ntrip/client.zig`: VrsRuntime にハンドオフする経路を追加
- `src/config/parser.zig`: `vrs_enable` / `vrs_mountpoint` 追加

### Phase 4b: 簡易合成 (位置補正なし)

検証目的の段階。VRS の本質的価値は位置補正だが、まずは「rover ごとに別 RTCM3 が流れる」配管を作る。

合成内容:
- Type 1005: rover の GGA 緯度経度を ECEF に変換 → 1005 ペイロードに埋め込み
- Type 1077/1087/1097: **主上流の MSM7 をそのままコピー** (補正なし)

これだけだと結局 FKP 非対応 rover は「近くの単一基準局」しか得られないが、配管としては rover ごと独立した RTCM3 が流れるところまで確認できる。

### Phase 4c: FKP 補正適用 (本命)

3 局の MSM7 + FKP パラメータ (engine.computeFkp) を使って rover 位置での観測値を合成:

```
ΔΦ_rover = ΔΦ_master + N_I·dN + E_I·dE + (vertical_term)
```

ここで:
- `ΔΦ_master`: 主上流 (最近接局) の搬送波位相観測
- `N_I, E_I`: 電離層 FKP 係数 ([m/rad])
- `N_0, E_0`: 幾何学 FKP 係数
- `dN, dE`: 主上流から rover までの北・東距離 [rad]

実装は既存 `engine.zig` の出力を rover 位置に適用するだけなので、Phase 4b の上に薄い層を載せる。

### Phase 4d: セル境界処理

rover が 3 局網の外に出た場合の挙動。簡易には:
- セル中心からの距離が一定 (例: 50km) を超えたら 503 で切断
- もしくは「最寄り 3 局を動的選択」して再構築 (複数セル展開時の本格運用向け、Phase 5 以降)

## 設計上の論点

1. **GGA パースのタイミング**
   - rover が GGA を送らないと位置不明 → どうする?
     a) 初回 GGA が来るまで RTCM3 を流さない (待機)
     b) 主上流の生 RTCM3 を流しておいて、GGA 来てから VRS 合成に切替
     c) 完全強制: GGA を 30 秒間貰えなければ切断
   
   推奨: (a) シンプル + 安全。「GGA がないと位置不明」は VRS のルール。

2. **GGA 送信間隔**
   - 5-10 秒間隔が業界標準。rover の移動速度が遅い農機なら 30 秒でも実用上問題ない。
   - 短すぎる (1 秒以下) と CPU 負荷 + 不要 → 30 秒推奨。

3. **per-rover thread vs 共有ループ**
   - rover 数が少ない (< 100) なら 1 スレッド/rover で OK
   - 数千 rover なら epoll/io_uring 必要、これは規模問題なので後回し

4. **認証**
   - 既存の `MountAuth` をそのまま流用可能。`vrs_mountpoint` を `config.mounts` に追加するだけ。
   - 「ユーザーごとに別 VRS インスタンス」のような需要は商用 NRTK の話、農機運用の現段階では不要。

5. **エポック同期**
   - 仮想 RTCM3 の Type 1005 / MSM7 のタイムスタンプを上流の同じエポックに揃える必要がある。
   - 簡易には: 主上流が出す MSM7 frame を基準時刻として、その瞬間に合成する。

6. **Type 1005 の ECEF 変換**
   - 既存 `msm7.zig` に `parseMsg1005()` はあるが、逆向き (lat/lon→ECEF→1005 エンコード) は未実装。
   - WGS84 楕円体パラメータで実装。~30 行で書ける。

## 推定工数

Phase 4a (GGA 受信パス): 1 ファイル新規 + client.zig 軽量改修 → 1 セッション
Phase 4b (簡易合成): VRS runtime + Type 1005 エンコード → 1 セッション
Phase 4c (FKP 補正適用): engine.zig の応用関数追加 → 1 セッション
Phase 4d (境界処理): エラー応答 + 設定 → 0.5 セッション

合計 3〜4 セッション程度。Phase 4a/4b が動けば「VRS 配管」としては完成、4c で「本物の VRS」になる。

## 開始判断

- M5Stack Bridge 側は **追加実装ゼロ** で VRS を受けられる (標準 RTCM3 を受信機に流すだけ)
- ただし Bridge 側で GGA を送る仕組みは必要 → 既に NTRIPConfig に `vrsEnabled` / `useReceiverGGA` / `ggaIntervalSec` のフィールドを置いてあるので、有効化すれば NMEA から GGA 抜き取り → caster へ送信、を実装するだけ
- caster 側を先に進めて mountpoint を作り、後で Bridge 側の GGA up 実装を入れる順序が安全
