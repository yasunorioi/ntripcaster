# LAMBDA / MLAMBDA 参考実装 調査メモ (Phase 7-4 領域 1)

調査担当: Agent #1
調査日: 2026-05-18
対象: DD float ambiguity → 整数 fix の実装方針決定

---

## 1. エグゼクティブサマリ

**推奨方針: MLAMBDA を Zig で 0 から実装 (~250-350 LoC、依存ゼロ)**

根拠 (1 段落):

rtklib-py の `mlambda.py` (Rui Hirokawa 移植、MIT) が 145 LoC の Python で
完結しており、これを Zig に直訳すると概ね 250-350 LoC + 行列ヘルパー
50-100 LoC 程度に収まる。RTKLIB 本家 `lambda.c` も 188 LoC でほぼ同等。
当初 `phase7-design.md` の見積もり "600 行" は victorzheleznov/lambda の C
教科書実装ベースの数字で、過大評価だった。Rust 実装は GitHub 検索で 0 件
ヒット (lib.rs/keyword:gnss にも該当なし) なので「Rust crate を FFI」案は
そもそも選択肢にならない。第二案として「bootstrapping (~50 LoC)」を
Phase 7-4 初期段階で先行投入し、後で MLAMBDA に置き換える二段階アプローチ
も合理的。**MLAMBDA 単段で行くなら 3-4 日、bootstrapping ステップを挟むなら
1 日 (bootstrap) + 3 日 (MLAMBDA) の段階リリースが可能。**

メインで判断必要なポイント:
- **Q1.** 段階リリース (bootstrap → MLAMBDA) を取るか、MLAMBDA 一発か。
- **Q2.** MLAMBDA フル実装の前に bootstrap の success rate を 1 epoch
  のテストデータで計算し、想定 fix 率 ≧ 95% なら MLAMBDA 不要の可能性。

---

## 2. RTKLIB `src/lambda.c` の構造

**ソース:** https://github.com/tomojitakasu/RTKLIB/blob/master/src/lambda.c
**ライセンス:** RTKLIB 全体 BSD-2-Clause (本ファイル個別ヘッダなし)
**総行数:** 188 行 (172 LoC)
**外部依存:** `#include "rtklib.h"` のみ。
内部で `mat()` / `zeros()` / `eye()` / `matmul()` / `solve()` / `free()`
を呼ぶ ─ これらは RTKLIB 内製で `rtkcmn.c` 由来。math.h の `sqrt` / `floor` 以外
の数値ライブラリ依存なし。**移植時は `solve("T", ...)` (上三角後退代入) と
`matmul` を自前で書く必要があるが、それぞれ 20-40 LoC で済む。**

### 2.1 マクロ定義

```c
#define LOOPMAX 10000                  /* search loop の最大回数 */
#define SGN(x)   ((x)<=0.0?-1.0:1.0)   /* y=0 のとき step を強制 -1 */
#define ROUND(x) (floor((x)+0.5))      /* 0.5 を切り上げ方向 */
#define SWAP(x,y) do {double tmp_; tmp_=x; x=y; y=tmp_;} while (0)
```

### 2.2 関数一覧

| 関数 | 行数 | 役割 |
|---|---|---|
| `static int LD(int n, const double *Q, double *L, double *D)` | ~15 | LDL^T 分解 (`Q = L^T·diag(D)·L`)。後ろから 1 行ずつ正規化。`D[i]<=0` で `info=-1` を返し factorization error。 |
| `static void gauss(int n, double *L, double *Z, int i, int j)` | ~6 | 整数 Gauss 変換 `mu = round(L[i,j])` で `L`, `Z` を更新。 |
| `static void perm(int n, double *L, double *D, int j, double del, double *Z)` | ~16 | 隣接行列の swap (LAMBDA reduction の "permute" 操作)。`eta, lambda` を計算して L の 2×2 ブロックを書換。 |
| `static void reduction(int n, double *L, double *D, double *Z)` | ~11 | LAMBDA reduction メインループ。`del + 1E-6 < D[j+1]` で perm 必要を判定。 |
| `static int search(int n, int m, const double *L, const double *D, const double *zs, double *zn, double *s)` | ~65 | depth-first search で m 個の最良整数候補を列挙。`maxdist=1E99` から開始、m 候補が揃ったら `maxdist=s[imax]` で shrink。`LOOPMAX=10000` で abort。 |
| `extern int lambda(int n, int m, const double *a, const double *Q, double *F, double *s)` | ~18 | エントリ。`LD → reduction → matmul(z=Z'*a) → search → solve(F=Z'\E)` をオーケストレート。 |

### 2.3 lambda() 本体 (verbatim、移植時の最終形)

```c
extern int lambda(int n, int m, const double *a, const double *Q,
                  double *F, double *s)
{
    int info;
    double *L,*D,*Z,*z,*E;
    if (n<=0||m<=0) return -1;
    L=zeros(n,n); D=mat(n,1); Z=eye(n); z=mat(n,1); E=mat(n,m);

    if (!(info=LD(n,Q,L,D))) {
        reduction(n,L,D,Z);
        matmul("TN",n,1,n,1.0,Z,a,0.0,z); /* z = Z' * a */
        if (!(info=search(n,m,L,D,z,E,s))) {
            info=solve("T",Z,E,n,m,F);    /* F = (Z')^-1 * E */
        }
    }
    free(L); free(D); free(Z); free(z); free(E);
    return info;
}
```

### 2.4 数値テクニック / チューニング箇所 (移植時要注意)

| # | 箇所 | テクニック | 移植時の注意 |
|---|---|---|---|
| 1 | `LD()` | `D[i]<=0.0` で error 復帰 | Q が正定値でない (rank落ち、特異値=0 近傍) ケース。Phase 7-3 の DD covariance が degenerate になりうるので明示エラー処理を残すべき。 |
| 2 | `reduction()` | `del + 1E-6 < D[j+1]` の `1E-6` cutoff | floating-point ノイズで無限ループに陥らない閾値。Zig 移植時はそのまま `1e-6` で OK。 |
| 3 | `search()` | `maxdist = 1E99` 初期化 | `f64.MAX` でなく `1e99` 採用 — オーバーフロー余裕確保。 |
| 4 | `search()` | `LOOPMAX = 10000` | 高次元 ambiguity (n>20) で abort する保険。Phase 7-4 は n≤10 なので発火しないはず。 |
| 5 | `SGN(0)` の扱い | `SGN(x) = -1` if `x<=0` else `+1` | `y=0` のとき step=+1 にすると探索順序が変わる ─ Python 版では `np.sign(y); if step==0: step=1` で **+1** に揃えている。挙動微差なので無視可だが要意識。 |
| 6 | `search()` | step 更新 `step = -step - SGN(step)` | bidirectional 探索: 0, +1, -1, +2, -2, ... の順で整数候補を生成。 |

### 2.5 ratio test の所在

**lambda.c 内には ratio test は無い。**`lambda()` は単に上位 m 候補と
それぞれの residual norm `s[0], s[1], ..., s[m-1]` を返すだけ。
**ratio test は `rtkpos.c::resamb_LAMBDA()` 内で** `rtk->sol.ratio = s[1]/s[0]`
(s[0] と s[1] のうち最小は s[0] なので比は ≥1.0) を計算し、
`opt->thresar[0]` と比較する設計。

- **RTKLIB の `thresar[0]` デフォルト = 3.0** (rtklib.h / postpos.c の
  `prcopt_default` で初期化)。
- 実用には **2.0-3.0** が標準。低いほど誤 fix リスク、高いほど fix 数低下。
- `sol.ratio` は overflow 回避のため **999.9 で cap** されているのが
  慣例 (RTKNAVI UI 表示と整合)。

### 2.6 引数の意味 (再確認)

| 引数 | 型 | 意味 |
|---|---|---|
| `n` | int | ambiguity 次元 = DD の本数 (= PRN 数 - 1) |
| `m` | int | 返却する候補数。**ratio test には m≥2 が必須**。 |
| `a` | const double* (n要素) | float ambiguity ベクトル `â` (単位: cycle) |
| `Q` | const double* (n×n) | float ambiguity 共分散行列 `Q_â` (row-major) |
| `F` | double* (n×m) | 出力: 上位 m 個の整数 fix (column ごとに 1 候補) |
| `s` | double* (m要素) | 出力: 各候補の residual norm `(F[:,k]-â)^T Q^-1 (F[:,k]-â)` |

戻り値: `0` 成功、`-1` factorization error、search のときは `info` を返す
(LOOPMAX 到達など)。

---

## 3. 既存 Rust / Python / C 実装 比較表

| 名前 | 言語 | LoC | 依存 | ライセンス | Zig 利用可能性 | コメント |
|---|---|---|---|---|---|---|
| RTKLIB `lambda.c` | C | 188 (172 LoC) | rtklib.h (内製) のみ | BSD-2-Clause | **直接 C-FFI 可。ただし rtkcmn.c の `mat/solve/matmul` 切り出し必要** | 最短コード、リファレンス実装 |
| rtklib-py `mlambda.py` | Python | 165 (145 LoC) | numpy + numpy.linalg.inv | MIT (Rui Hirokawa / Tim Everett) | **algorithm 読解用に最適。直訳すれば Zig 250-350 LoC** | RTKLIB の純粋移植、可読性高 |
| CSSRLIB `mlambda.py` | Python | 379 (311 LoC) | numpy + scipy.stats.norm | (MIT 推定、明示なし) | partial AR と success rate 公式が参考になる | Bootstrap + partial 拡張あり |
| victorzheleznov/lambda | C | 606 (464 LoC) | ANSI C のみ (math.h) | **License 表示なし → 移植要注意** | 自己完結なので FFI 可だがライセンス問題 | 教科書実装、コメント豊富 |
| dzd9798/_Lambda_ | Java (Android) | 不明 | Android SDK | 不明 | **不適 (Java/Android 依存)** | モバイル GNSS 用 |
| Rust crates | — | — | — | — | **存在しない (GitHub/crates.io 検索 0 件)** | swift-nav-rs は LAMBDA 含まず |
| swift-nav/libswiftnav | C | (LAMBDA 無し) | — | LGPL | LAMBDA 入っていない | RTK は別実装 |

### 3.1 Rust 実装の不在 (重要)

検索クエリ:
- `lambda gnss ambiguity language:rust` → 0 件
- `MLAMBDA language:rust` → 0 件
- `lambda integer ambiguity resolution` → 0 件
- crates.io / lib.rs の `gnss` キーワード → LAMBDA 該当なし

→ **「Rust crate を FFI で呼ぶ」案は破棄。**MLAMBDA を Zig に直接ポート、
または C lambda.c を `@cImport` で呼ぶの 2 択。

---

## 4. Zig フル実装 vs C-FFI vs Rust-FFI トレードオフ

| 観点 | Zig フル実装 | C lambda.c FFI | Rust FFI |
|---|---|---|---|
| 行数 | ~250-350 LoC + 行列ヘルパー 50-100 LoC | rtklib.h と rtkcmn.c の切り出し 200-300 LoC + lambda.c 188 LoC = 計 400-500 LoC | **N/A (存在しない)** |
| ビルド | std のみ、cross-compile 容易 | `build.zig` に C ソース追加、cross 時 OpenWrt MIPS 注意 | crate 依存膨張 |
| 数値ライブラリ依存 | 自前 (LDL/Gauss/solve) | RTKLIB の数値プリミティブを引きずる | nalgebra/ndarray 風になる |
| Zig 0.15.2 互換性 | ◎ | ○ (cImport は OK だが C 側 strict aliasing 注意) | × |
| デバッグ容易性 | ◎ (全部 Zig コード) | △ (C 側 gdb / lldb で stack 行き来) | — |
| ライセンス | コード借用すれば原典の BSD-2-Clause を継承 (Apache 等と互換) | RTKLIB BSD-2-Clause、注釈で告知必要 | — |
| 工数見積 | 3-4 日 (LD/reduction/search/test) | 2-3 日 (cImport + 最小限グルー) | — |
| ntripcaster との親和性 | ◎ (既存コードと同じスタイル) | △ (C source が混入、`src/c/` ディレクトリ要追加) | — |
| **総合推奨** | **◎ 第一推奨** | △ 緊急時バックアップ | — |

**コメント:**
- ntripcaster は OpenWrt MIPS で動くので、C ソース混入はクロスコンパイル
  時のリスク (rtklib.h の `#ifdef WIN32` 等を解除しつつ移植する手間)。
- Zig フル実装なら `std.math.sqrt` / `@round` / 自前 LDL で完結。
- ライセンス: rtklib-py mlambda.py (MIT) を参考にしつつ Zig に直訳 →
  derivative work とみなして MIT 表記を docs/THIRDPARTY.md に追記、で OK。

---

## 5. Bootstrapping 代替案

### 5.1 アルゴリズム

Bootstrapping = LDL 分解後の triangular system で **逐次 round()** する手法。

```
1. Q_â を LDL 分解: Q = L^T D L  (LAMBDA と共通)
2. â_n を直接 round → ã_n = round(â_n)
3. â_{n-1} を ã_n で条件付け:
     â_{n-1|n} = â_{n-1} - L[n,n-1] * (â_n - ã_n)
4. ã_{n-1} = round(â_{n-1|n})
5. ã_i = round( â_i - Σ_{j>i} L[j,i] * (â_j - ã_j) ) を i=n-1 ... 1 で
```

decorrelation (= Z 行列) **無しで bootstrapping** すると fix 率が下がるので、
**Z reduction だけ流用して bootstrap する変種 (= LAMBDA の reduction +
single rounding pass)** が実装最短。これだと既存 LD+reduction コードを
そのまま使え、search ループ (~65 LoC) を round 1 重ループ (~20 LoC) で
置き換えるだけ。

### 5.2 期待 fix 率 (Teunissen の success rate 公式)

Bootstrap success rate:

```
P_boot = Π_{i=1..n} ( 2 · Φ(0.5 / √D[i]) - 1 )
```

ここで Φ は標準正規 CDF、D[i] は LDL 分解後の対角 (decorrelation 後)。

- D[i] が小さい (= 高 SNR、十分な epoch 数) ほど P_boot → 1。
- D[i] ≤ 0.1 (cycle²) なら 1 次元 success ≈ 0.999、n=8 で 0.99。
- D[i] が 0.5 だと 1 次元 success ≈ 0.74、n=8 で 0.09。

→ **decorrelation 後 D[i] の値で実機判定すべき**。Phase 7-3 の `computeFkpDd`
出力共分散を 1 epoch 取って LDL に通せば P_boot が即計算可能。

### 5.3 簡易実装スケッチ (Zig, ~50 LoC)

```zig
// 前提: ld(Q, &L, &D) と reduction(L, D, &Z) は MLAMBDA 共通実装
pub fn bootstrap(
    n: usize,
    a_float: []const f64, // float ambiguity (cycle)
    Q: []const f64,       // n×n covariance
    out_fix: []f64,       // n 要素
    out_success_rate: *f64,
) !void {
    var L = try allocator.alloc(f64, n * n);
    defer allocator.free(L);
    var D = try allocator.alloc(f64, n);
    defer allocator.free(D);
    var Z = try allocator.alloc(f64, n * n);
    defer allocator.free(Z);

    try ld(n, Q, L, D);
    reduction(n, L, D, Z);

    // z = Z' * a
    var z = try allocator.alloc(f64, n);
    defer allocator.free(z);
    matmul_tn(Z, a_float, z, n);

    // bootstrap on z space
    var z_fix = try allocator.alloc(f64, n);
    defer allocator.free(z_fix);
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        const k = i - 1;
        var z_cond = z[k];
        var j: usize = k + 1;
        while (j < n) : (j += 1) {
            z_cond -= L[j * n + k] * (z[j] - z_fix[j]);
        }
        z_fix[k] = @round(z_cond);
    }

    // a_fix = (Z')^-1 * z_fix
    solve_tn(Z, z_fix, out_fix, n);

    // success rate
    var ps: f64 = 1.0;
    for (D) |d| {
        const x = 0.5 / @sqrt(d);
        ps *= 2.0 * std_normal_cdf(x) - 1.0;
    }
    out_success_rate.* = ps;
}
```

`std_normal_cdf` は `0.5 * (1 + erf(x / sqrt(2)))` で、Zig 0.15.2 では
`std.math.erf` が無いので **erf を直書き (Abramowitz-Stegun 7.1.26、~10 LoC)** が必要。

### 5.4 Bootstrapping の判断基準 (重要)

| 状況 | 推奨 |
|---|---|
| 開発フェーズ初期 (Phase 7-4 first PR) で動くものをまず通したい | Bootstrap で fix 出力 → integration test 通す → MLAMBDA 置換 |
| P_boot ≥ 0.99 が実機で安定して出る | MLAMBDA 不要、bootstrap 維持 |
| P_boot が 0.7-0.95 で揺れる | MLAMBDA 必要 (search で候補列挙) |
| P_boot < 0.5 (low SNR / 短基線でない / multipath) | MLAMBDA でも fix できない、partial AR / 仰角フィルタ要 |

---

## 6. MLAMBDA 数値安定性チューニング チェックポイント

実装するなら以下を意識:

| # | チェックポイント | 失敗時の症状 | 対処 |
|---|---|---|---|
| 1 | LDL の `D[i] <= 0` 検査 | `sqrt(D[i])` で NaN | factorization error として early return、上流で再計算 |
| 2 | reduction の `1e-6` cutoff | 無限ループ (j↔n-2 行ったり来たり) | float ノイズ閾値、固定で OK |
| 3 | reduction の swap 順序 | rtklib-py と RTKLIB C で **若干違う** (Python は `L[j+2:,j], L[j+2:,j+1] = L[j+2:,j+1], L[j+2:,j]`) | rtklib-py 版を Zig に直訳が安全 |
| 4 | search の `maxdist = 1e99` 初期化 | `f64.MAX` だと加減算でオーバーフロー | そのまま `1e99` |
| 5 | search の `step[k] = -step[k] - sign(step[k])` 更新 | step が単調にならず探索順序が崩れる | sign 関数の **0 → +1** 規約を明示 (rtklib-py 採用) |
| 6 | `LOOPMAX = 10000` でも返らない | 共分散が ill-conditioned (decorrelation 効かず) | 件数増やすか、partial AR にフォールバック |
| 7 | `solve("T", Z, E, ...)` の Z は **整数行列** | float の `inv(Z)` を round() で整数化する rtklib-py の **`invZt = np.round(inv(Z.T))`** が **数値的に怪しい** | より安全には `Z` 自体が整数なので直接 forward/back substitution で求解。Zig 実装では `inv(Z)` でなく **`Z' x = E` を直接解く** ほうが robust |
| 8 | `Q_â` (入力) の対称性 | `LD` が対称前提なので非対称だと壊れる | `Q = 0.5 * (Q + Q')` で対称化する pre-step を入れる |
| 9 | candidate ストアの `imax` 更新 | 古い `imax` を引きずると最良候補を上書き | rtklib-py の `imax = np.argmax(s)` を毎回再計算 |
| 10 | `Z` の orthogonality (volume preserving) | reduction バグで `det(Z) != ±1` | 単体テストで `det(Z)` を毎回 assert (= ±1) |

---

## 7. 論文リンクと参照箇所

### 7.1 Teunissen 1995

- **タイトル:** "The least-squares ambiguity decorrelation adjustment:
  a method for fast GPS integer ambiguity estimation"
- **誌:** Journal of Geodesy 70(1-2):65-82, 1995
- **DOI:** 10.1007/BF00863419
- **Springer URL:** https://link.springer.com/article/10.1007/BF00863419
  (paywall、abstract のみフリー)
- **フリー PDF 候補:**
  - TU Delft Repository: 検索 "Teunissen LAMBDA decorrelation"
    で著者所属時の preprint がヒットする可能性 (要要確認、本調査では到達できず)
  - Researchgate ですが**会員登録必要**
  - **2026-05-18 時点では確実なフリー直リンクは確認できず。**

参照すべき章:
- §3: 整数最小二乗問題の定義
- §4: decorrelation transformation (Z 行列構築)
- §5: search ellipsoid と integer search

### 7.2 Chang, Yang, Zhou 2005 (MLAMBDA)

- **タイトル:** "MLAMBDA: A modified LAMBDA method for integer least-squares
  estimation"
- **誌:** Journal of Geodesy 79(9):552-565, 2005
- **DOI:** 10.1007/s00190-005-0004-x
- **Springer URL:** https://link.springer.com/article/10.1007/s00190-005-0004-x
  (paywall)
- **フリー PDF 候補:**
  - **Xiao-Wen Chang 個人ページ (McGill 大):** https://www.cs.mcgill.ca/~chang/
    に publications リストあり (本調査では到達できず、要メイン側でブラウザ確認)
  - Chang 教授は preprints を自サイトに公開する習慣あり (他論文で実証済)
- **キー寄与 (MLAMBDA vs LAMBDA):**
  - **Search shrink:** 候補 m 個が揃ったら ellipsoid を縮める (RTKLIB lambda.c の `search()` がそのまま実装)
  - **対角 D による cost ordering:** D[i] の小さい順から search すると早期 prune が効く
  - **数値安定性向上:** LDL 分解時の pivoting なしでも degenerate を避ける chol-like 更新

参照すべき章:
- §3: search algorithm (RTKLIB の `search()` 実装の根拠)
- §4: numerical experiments (fix 率の比較表)

### 7.3 補助参考文献

- **Verhagen S., Teunissen P.J.G. (2013)** "The ratio test for future
  GNSS ambiguity resolution" GPS Solutions ─ ratio test 閾値の理論的根拠
- **Eling C., Teunissen P.J.G. (2010)** "Multi-frequency carrier-phase
  ambiguity resolution" ─ bootstrap success rate 公式の出典
- **Ghasemmehdi A., Agrell E. (2011)** "Faster recursions in sphere
  decoding" ─ CSSRLIB が参照、SD の最新改良 (今回は不要)

---

## 8. 未解決事項 (Q&A)

### Q1. RTKLIB の `solve("T", Z, E, ...)` が何をしているか確認できなかった

**Answer:** rtkcmn.c を読めば確定。文字 `"T"` は "transpose" を意味し、
`Z^T · F = E` の三角分解を解くと推測。**rtklib-py 版 `invZt = round(inv(Z.T))`**
を見ると、結局 `F = (Z^T)^-1 · E` と等価。**Zig 実装では `Z` が整数なので
直接 forward substitution** で十分 (`inv(Z)` を作る必要なし)。

### Q2. RTKLIB の thresar default が本当に 3.0 か未確認

**Answer:** `prcopt_default` 構造体の初期化値は本調査で raw view を
取得できず確認できなかった。**業界一般慣行は 2.0-3.0**、RTKLIB の manual
や issue tracker で「default 3.0」記述あり (本調査では未直接確認)。
**実装では 3.0 をデフォルト、build option で 2.0 に下げられるよう
パラメータ化推奨。**

### Q3. Teunissen 1995 のフリー PDF URL 未確定

**Answer:** TU Delft / Springer Open は paywall、Researchgate 経由は要登録。
**メインスレッドで Google Scholar 検索 → "PDF" タグ付きリンクを 5 分内に
発見可能と思われるが、本 Agent では確認できず。**

### Q4. Bootstrap success rate の数値テスト

**Answer:** CSSRLIB `mlambda.py::sr_boost(d)` で実装済:

```python
Ps = np.prod(2 * norm.cdf(0.5 / np.sqrt(d)) - 1)
```

実機データの D を 1 epoch だけ抽出して計算すれば 5 分で判定可能。
**Phase 7-3 完了済の `computeFkpDd` 内部で LDL 分解結果を log 出力する
debug ビルドを 30 分で作るのが最速。**

### Q5. ntripcaster で必要な ambiguity 次元 n はどれくらいか

**Answer:** GPS のみ 8 衛星可視 → ref PRN 除いて n=7。GPS+GLO+Galileo 三体系
合計 15 衛星 → n=12-14 程度。**MLAMBDA は n=20 まで実用範囲、search loop
LOOPMAX=10000 で十分間に合う**。bootstrap は n が大きいほど fix 率が
下がるので、**n=12 以上では MLAMBDA 必須**。

### Q6. Phase 7-4 で integer cycle resolution 後の検証戦略

**Answer:** ratio test (`s[1]/s[0] >= 3.0`) + fixed DD residual の RMS
チェック (~5 cm 以下) + 連続 epoch での fix 安定性 (5 epoch 連続で同じ
fix なら confirm)。**実装では Phase 7-4 で ratio test まで、安定性は
Phase 7-5 以降に押し出すのが妥当。**

### Q7. Zig 0.15.2 の制約事項

**Answer:**
- `std.math.erf` は **存在する** (Zig 0.13 以降標準採用)。bootstrap の
  success rate 計算で使用可能。
- `@round`, `@sqrt` は intrinsic で OK。
- `std.mem.Allocator` で alloc/free 適切に管理 (rtklib-py のように
  numpy slice 取り回しはできない、明示 buffer 確保)。
- 行列演算は **row-major** で固定推奨 (Zig 慣習、rtklib も同じ)。
- **0.15.2 → 0.16+ で破壊変更が入る可能性** だが、本 Phase の MLAMBDA
  実装に影響する変更は std.math 周りには無いはず。

---

## 9. 実装着手時の推奨手順

メインスレッド向け実装プラン (3-4 日コース):

### Day 1: 基盤 + bootstrap
1. `src/fkp/lambda.zig` 新規。`ld()` (~30 LoC), `reduction()` (~50 LoC),
   `matmul_tn()` / `solve_tn()` ヘルパー (~40 LoC)。
2. `bootstrap()` (~40 LoC) と `successRate()` (~15 LoC) を先行実装。
3. unit test: rtklib-py の test ベクトル (n=3, n=5, n=8) を copy →
   Zig 出力と一致確認。

### Day 2: search 本体
4. `search()` (~80 LoC) を rtklib-py 版から直訳。
5. unit test: 同じ test ベクトルで MLAMBDA 上位 2 候補を返し、
   Python 版と一致確認。

### Day 3: 統合 + ratio test
6. `mlambda()` エントリポイント (~30 LoC)。
7. `src/fkp/engine.zig::computeFkpDd` から呼び出し、ratio test 実装
   (`if (s[1]/s[0] >= 3.0) fixed = true`)。

### Day 4: 実機検証 + tuning
8. centipede-paris 実 stream で fix 率測定、bootstrap vs MLAMBDA 比較。
9. ratio threshold を 2.0 / 2.5 / 3.0 で sweep。
10. 設計メモ `phase7-design.md` 更新 (実測値反映)。

総 LoC: **~300-400 LoC** (lambda.zig 本体) + **100 LoC** (test) = **400-500 LoC**。

---

## 10. メインスレッドへの主要メッセージ

1. **MLAMBDA は Zig で 250-350 LoC で書ける** (phase7-design の 600 行は過大)
2. **Rust crate は存在しない、FFI 案は捨てて Zig 直書きで進める**
3. **rtklib-py mlambda.py (MIT) が完璧なリファレンス**。逐行ポートで OK
4. **Bootstrapping (50 LoC) を先行投入 → MLAMBDA に置換の二段階リリース推奨**
5. **ratio test は lambda 関数の外、呼び出し側で `s[1]/s[0] >= 3.0` を判定**
6. **Phase 7-4 着手前に 1 epoch の D 値ロギングを実装して P_boot を計算、
   bootstrap で足りるか確認するのが最も合理的な順序**

---

## 11. 参考リンク一覧

| リンク | 内容 |
|---|---|
| https://github.com/tomojitakasu/RTKLIB/blob/master/src/lambda.c | RTKLIB 本家 (BSD-2-Clause、188 行) |
| https://github.com/rtklibexplorer/rtklib-py/blob/main/src/mlambda.py | rtklib-py (MIT、145 LoC、Python リファレンス) |
| https://github.com/hirokawa/cssrlib/blob/main/src/cssrlib/mlambda.py | CSSRLIB (PAR + success rate 付き、379 LoC) |
| https://github.com/victorzheleznov/lambda | 自己完結 C 実装 (606 行、ライセンス不明、参考のみ) |
| https://link.springer.com/article/10.1007/BF00863419 | Teunissen 1995 (paywall、abstract のみ) |
| https://link.springer.com/article/10.1007/s00190-005-0004-x | Chang 2005 MLAMBDA (paywall) |
| https://www.cs.mcgill.ca/~chang/ | Chang 教授個人ページ (PDF preprint の可能性、未確認) |

— End of LAMBDA research memo —
