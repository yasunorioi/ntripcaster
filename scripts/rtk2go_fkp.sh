#!/usr/bin/env bash
# scripts/rtk2go_fkp.sh — FKP計算実証スクリプト（北海道3局 rtk2go）
#
# 使用法: bash scripts/rtk2go_fkp.sh
#
# 前提: zig build 済み (./zig-out/bin/fkp-demo が存在)
#
# 北海道3局 (基線長 ~140km, PoC許容):
#   nakagawa00      中川   44.80°N 142.06°E
#   Asahikawa-HAMA  旭川   43.80°N 142.43°E
#   UEMATSUDENKI-F9P 赤平  43.58°N 142.00°E

set -euo pipefail
cd "$(dirname "$0")/.."

DEMO="./zig-out/bin/fkp-demo"

echo "=== FKP Demo: ntripcaster Phase4 rtk2go実証 ==="
echo "日時: $(date '+%Y-%m-%d %H:%M:%S JST')"
echo ""

# バイナリビルド確認
if [[ ! -f "$DEMO" ]]; then
    echo "[BUILD] zig build ..."
    /snap/bin/zig build 2>&1
fi

echo "[INFO] 北海道3局 rtk2go.com:2101 に接続中..."
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
    echo "[INFO] rtk2go接続失敗時はネットワーク確認またはDNS解決が必要"
    echo ""
    echo "=== ローカル機能テスト (zig build test) ==="
    /snap/bin/zig build test --summary all 2>&1
fi
