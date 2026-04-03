#!/usr/bin/env bash
# scripts/fkp_demo.sh — FKP計算実証スクリプト（3局接続デモ）
#
# 使用法: bash scripts/fkp_demo.sh
#
# 前提: zig build 済み (./zig-out/bin/fkp-demo が存在)
# STATIONS 定数は tools/fkp_demo.zig 内で設定すること。

set -euo pipefail
cd "$(dirname "$0")/.."

DEMO="./zig-out/bin/fkp-demo"

echo "=== FKP Demo: ntripcaster Phase4 実証 ==="
echo "日時: $(date '+%Y-%m-%d %H:%M:%S JST')"
echo ""

# バイナリビルド確認
if [[ ! -f "$DEMO" ]]; then
    echo "[BUILD] zig build ..."
    /snap/bin/zig build 2>&1
fi

echo "[INFO] 3局に接続中..."
echo "[INFO] Ctrl+C で中断"
echo ""

# デモ実行（Type59フレームはバイナリなので /tmp に保存）
if "$DEMO" 2>&1 >/tmp/fkp_type59_$(date +%s).bin; then
    echo ""
    echo "[OK] FKP計算・Type59エンコード完了"
    ls -la /tmp/fkp_type59_*.bin 2>/dev/null | tail -5
else
    EXIT=$?
    echo ""
    echo "[INFO] デモ終了 (exit=$EXIT)"
    echo "[INFO] 接続失敗時はネットワーク確認またはDNS解決が必要"
    echo ""
    echo "=== ローカル機能テスト (zig build test) ==="
    /snap/bin/zig build test --summary all 2>&1
fi
