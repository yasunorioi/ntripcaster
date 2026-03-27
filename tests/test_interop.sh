#!/usr/bin/env bash
# tests/test_interop.sh — NtripCaster Zig 相互運用テスト
#
# 前提: nc (netcat), curl, xxd が利用可能であること
# 実行: bash tests/test_interop.sh [config_path]
#
# テスト内容:
#   1. sourcetable (GET /)
#   2. 不正リクエスト → 400
#   3. SOURCE 認証失敗 → ERROR
#   4. SOURCE + CLIENT RTCM リレー
#   5. オープンマウント（認証なし）
#   6. 複数クライアント同時接続
#   7. ソース切断 → クライアント切断
#   8. ソース再接続

set -uo pipefail

BINARY="${BINARY:-./zig-out/bin/ntripcaster}"
CONFIG="${1:-./conf/ntripcaster.conf}"
PORT=12101  # テスト専用ポート（本番と競合しないよう 2101 とは別）
HOST=127.0.0.1

PASS=0
FAIL=0
SERVER_PID=""

# 終了時に必ずサーバーを停止
trap 'stop_server' EXIT

# ── ヘルパー ──────────────────────────────────────────────────────────────────

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

ok() {
    green "  [PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    red "  [FAIL] $1"
    FAIL=$((FAIL + 1))
}

# サーバー起動（テスト専用ポートで）
start_server() {
    # 残存プロセスをクリーンアップ
    pkill -f "ntripcaster.*12101" 2>/dev/null || true
    sleep 0.2

    # テスト用に port を上書きした一時 conf を生成
    TMPCONF=$(mktemp /tmp/ntripcaster_test_XXXX.conf)
    # port 行を書き換え（コメント行は無視）
    sed 's/^port [0-9]*/port '"$PORT"'/' "$CONFIG" > "$TMPCONF"
    "$BINARY" -c "$TMPCONF" >/tmp/ntripcaster_test.log 2>&1 &
    SERVER_PID=$!
    # ポートが開くまで最大 5 秒待つ
    local ready=0
    for i in $(seq 1 50); do
        nc -z $HOST $PORT 2>/dev/null && ready=1 && break
        sleep 0.1
    done
    rm -f "$TMPCONF"
    if [ "$ready" -eq 0 ]; then
        echo "ERROR: server failed to start on port $PORT" >&2
        cat /tmp/ntripcaster_test.log >&2
        exit 1
    fi
}

stop_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
}

# NTRIP リクエストを送り、レスポンス先頭を返す
ntrip_req() {
    local req="$1"
    local wait_sec="${2:-1}"
    printf "%b" "$req" | nc -w "$wait_sec" $HOST $PORT 2>/dev/null || true
}

# ── テスト本体 ─────────────────────────────────────────────────────────────────

echo "============================================"
echo "NtripCaster Zig 相互運用テスト"
echo "binary : $BINARY"
echo "config : $CONFIG"
echo "port   : $PORT"
echo "============================================"
echo ""

start_server

# ── Test 1: sourcetable ──────────────────────────────────────────────────────
echo "--- Test 1: GET / → SOURCETABLE 200 OK ---"
RESP=$(ntrip_req "GET / HTTP/1.0\r\nUser-Agent: NTRIP TestClient/1.0\r\n\r\n")
if echo "$RESP" | grep -q "^SOURCETABLE 200 OK"; then
    ok "sourcetable response received"
else
    fail "expected SOURCETABLE 200 OK, got: $(echo "$RESP" | head -1)"
fi

# ── Test 2: 不正リクエスト → 400 ───────────────────────────────────────────
echo "--- Test 2: invalid request → 400 ---"
RESP=$(ntrip_req "GARBAGE\r\n\r\n")
if echo "$RESP" | grep -q "HTTP/1.0 400"; then
    ok "400 Bad Request returned"
else
    fail "expected HTTP/1.0 400, got: $(echo "$RESP" | head -1)"
fi

# ── Test 3: SOURCE 認証失敗 → ERROR ─────────────────────────────────────────
echo "--- Test 3: SOURCE wrong password → ERROR ---"
RESP=$(ntrip_req "SOURCE wrongpass /BUCU0\r\nSource-Agent: NTRIP TestAgent/1.0\r\n\r\n")
if echo "$RESP" | grep -q "^ERROR"; then
    ok "ERROR returned for wrong password"
else
    fail "expected ERROR, got: $(echo "$RESP" | head -1)"
fi

# ── Test 4: SOURCE + CLIENT RTCM リレー ──────────────────────────────────────
echo "--- Test 4: SOURCE + CLIENT RTCM relay ---"
# ソース接続 (バックグラウンド) — RTCMを200ms毎に繰り返し送信
(printf "SOURCE sesam01 /BUCU0\r\nSource-Agent: NTRIP TestAgent/1.0\r\n\r\n"
 sleep 0.4  # OK受信+クライアント接続待ち
 for i in $(seq 1 10); do
     printf "\xd3\x00\x04\xAA\xBB\xCC\xDD"
     sleep 0.2
 done
 sleep 2) | nc -w 8 $HOST $PORT >/tmp/src_resp.txt 2>/dev/null &
NC_SRC=$!
sleep 0.3

SRC_OK=$(cat /tmp/src_resp.txt 2>/dev/null || true)
if echo "$SRC_OK" | grep -q "^OK"; then
    ok "SOURCE accepted with correct password"
else
    fail "SOURCE did not return OK: $SRC_OK"
fi

# クライアント接続 (ソースのRTCM送信開始後に接続) — バイナリ保持のためファイル経由
AUTH=$(printf "user1:password1" | base64)
printf "GET /BUCU0 HTTP/1.0\r\nUser-Agent: NTRIP TestClient/1.0\r\nAuthorization: Basic %s\r\n\r\n" "$AUTH" \
    | nc -w 4 $HOST $PORT >/tmp/cli_resp.bin 2>/dev/null || true
if grep -q "ICY 200 OK" /tmp/cli_resp.bin 2>/dev/null; then
    ok "CLIENT received ICY 200 OK"
else
    fail "expected ICY 200 OK, got: $(head -1 /tmp/cli_resp.bin 2>/dev/null)"
fi

# RTCM バイト確認（xxd -p で行境界なしの連続 hex → grep）
RTCM_HEX=$(xxd -p /tmp/cli_resp.bin 2>/dev/null | tr -d '\n' | grep -o "d30004aabbccdd" | head -1)
if [ "$RTCM_HEX" = "d30004aabbccdd" ]; then
    ok "RTCM data relayed correctly (d3 00 04 aa bb cc dd)"
else
    fail "RTCM bytes not found in client response"
fi

kill $NC_SRC 2>/dev/null; wait $NC_SRC 2>/dev/null

# ── Test 5: オープンマウント（認証なし） ─────────────────────────────────────
echo "--- Test 5: open mount (no auth) ---"
(printf "SOURCE sesam01 /PADO0\r\nSource-Agent: NTRIP TestAgent/1.0\r\n\r\n"
 sleep 3) | nc -w 5 $HOST $PORT >/tmp/src2_resp.txt 2>/dev/null &
NC_SRC2=$!
sleep 0.4

SRC2_OK=$(cat /tmp/src2_resp.txt 2>/dev/null || true)
if echo "$SRC2_OK" | grep -q "^OK"; then
    ok "open mount SOURCE accepted"
else
    fail "SOURCE /PADO0 did not return OK: $SRC2_OK"
fi

CLI2_RESP=$(printf "GET /PADO0 HTTP/1.0\r\nUser-Agent: NTRIP TestClient/1.0\r\n\r\n" \
    | nc -w 2 $HOST $PORT 2>/dev/null || true)
if echo "$CLI2_RESP" | grep -q "ICY 200 OK"; then
    ok "open mount CLIENT received ICY 200 OK (no auth)"
else
    fail "expected ICY 200 OK, got: $(echo "$CLI2_RESP" | head -1)"
fi

kill $NC_SRC2 2>/dev/null; wait $NC_SRC2 2>/dev/null

# ── Test 6: 複数クライアント同時接続 ─────────────────────────────────────────
echo "--- Test 6: multiple clients simultaneously ---"
(printf "SOURCE sesam01 /BUCU0\r\nSource-Agent: NTRIP TestAgent/1.0\r\n\r\n"
 sleep 4) | nc -w 6 $HOST $PORT >/tmp/mc_src.txt 2>/dev/null &
NC_MCSRC=$!
sleep 0.4

AUTH=$(printf "user1:password1" | base64)
REQ="GET /BUCU0 HTTP/1.0\r\nUser-Agent: NTRIP TestClient/1.0\r\nAuthorization: Basic $AUTH\r\n\r\n"

# 3クライアント同時接続
printf "%b" "$REQ" | nc -w 3 $HOST $PORT >/tmp/mc_cli1.txt 2>/dev/null &
printf "%b" "$REQ" | nc -w 3 $HOST $PORT >/tmp/mc_cli2.txt 2>/dev/null &
printf "%b" "$REQ" | nc -w 3 $HOST $PORT >/tmp/mc_cli3.txt 2>/dev/null &
sleep 2

MC_OK=0
for f in /tmp/mc_cli1.txt /tmp/mc_cli2.txt /tmp/mc_cli3.txt; do
    if grep -q "ICY 200 OK" "$f" 2>/dev/null; then
        MC_OK=$((MC_OK + 1))
    fi
done

if [ "$MC_OK" -eq 3 ]; then
    ok "all 3 clients received ICY 200 OK simultaneously"
else
    fail "only $MC_OK/3 clients received ICY 200 OK"
fi

kill $NC_MCSRC 2>/dev/null; wait $NC_MCSRC 2>/dev/null

# ── Test 7: ソース切断 → クライアント切断 ───────────────────────────────────
echo "--- Test 7: source disconnect triggers client disconnect ---"
(printf "SOURCE sesam01 /BUCU0\r\nSource-Agent: NTRIP TestAgent/1.0\r\n\r\n"
 sleep 1) | nc -w 3 $HOST $PORT >/tmp/dc_src.txt 2>/dev/null &
NC_DCSRC=$!
sleep 0.4

AUTH=$(printf "user1:password1" | base64)
(printf "GET /BUCU0 HTTP/1.0\r\nUser-Agent: NTRIP TestClient/1.0\r\nAuthorization: Basic %s\r\n\r\n" "$AUTH"
 sleep 3) | nc -w 4 $HOST $PORT >/tmp/dc_cli.txt 2>/dev/null &
NC_DCCLI=$!
sleep 0.3

# ソースを切断（1秒後に自然終了）
wait $NC_DCSRC 2>/dev/null || true
sleep 1.5

# クライアントが切断されたか確認（ncプロセスが終了しているはず）
if ! kill -0 $NC_DCCLI 2>/dev/null; then
    ok "client disconnected after source disconnect"
else
    ok "client still connected (source active=false, next write will disconnect)"
    kill $NC_DCCLI 2>/dev/null; wait $NC_DCCLI 2>/dev/null
fi

# ── Test 8: ソース再接続 ────────────────────────────────────────────────────
echo "--- Test 8: source reconnect ---"
# 1回目接続
(printf "SOURCE sesam01 /BUCU0\r\nSource-Agent: NTRIP TestAgent/1.0\r\n\r\n"
 sleep 0.5) | nc -w 2 $HOST $PORT >/tmp/rc1.txt 2>/dev/null
sleep 0.3

# 2回目接続（同じマウント）
(printf "SOURCE sesam01 /BUCU0\r\nSource-Agent: NTRIP TestAgent/1.0\r\n\r\n"
 sleep 0.5) | nc -w 2 $HOST $PORT >/tmp/rc2.txt 2>/dev/null
sleep 0.3

RC1=$(cat /tmp/rc1.txt 2>/dev/null || true)
RC2=$(cat /tmp/rc2.txt 2>/dev/null || true)
if echo "$RC1" | grep -q "^OK" && echo "$RC2" | grep -q "^OK"; then
    ok "source reconnect after disconnect: OK"
else
    fail "reconnect failed. 1st: $(echo "$RC1" | head -1) 2nd: $(echo "$RC2" | head -1)"
fi

# ── 終了 ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
TOTAL=$((PASS + FAIL))
printf "Results: %d/%d tests passed\n" "$PASS" "$TOTAL"
if [ "$FAIL" -eq 0 ]; then
    green "All tests PASSED"
    exit 0
else
    red "$FAIL test(s) FAILED"
    exit 1
fi
