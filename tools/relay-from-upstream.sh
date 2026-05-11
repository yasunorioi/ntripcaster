#!/usr/bin/env bash
# tools/relay-from-upstream.sh
#
# 上流 NTRIP caster (例: rtk.toiso.fit:2101/eniwa-bd982) から RTCM3 を取得し、
# ローカル ntripcaster (conf/sample.conf) に SOURCE 接続として中継する。
#
# 使い方:
#   ./zig-out/bin/ntripcaster -c conf/sample.conf &
#   tools/relay-from-upstream.sh
#
# 上流接続: GET /mount → "ICY 200 OK\r\n\r\n" (14 bytes) + RTCM3 stream
# 下流接続: SOURCE password /mount → "OK\r\n" + RTCM3 stream
#
# 上流の ICY ヘッダーをスキップしてから下流へ流す。

set -u

UPSTREAM_HOST="${UPSTREAM_HOST:-rtk.toiso.fit}"
UPSTREAM_PORT="${UPSTREAM_PORT:-2101}"
UPSTREAM_MOUNT="${UPSTREAM_MOUNT:-eniwa-bd982}"
UPSTREAM_USER="${UPSTREAM_USER:-}"
UPSTREAM_PASS="${UPSTREAM_PASS:-}"

LOCAL_HOST="${LOCAL_HOST:-127.0.0.1}"
LOCAL_PORT="${LOCAL_PORT:-12101}"
LOCAL_MOUNT="${LOCAL_MOUNT:-/eniwa-bd982}"
LOCAL_PASS="${LOCAL_PASS:-localpass}"

# 上流が認証を要求する場合は Authorization ヘッダーを生成
AUTH_HDR=""
if [[ -n "${UPSTREAM_USER}" ]]; then
  TOKEN=$(printf '%s:%s' "${UPSTREAM_USER}" "${UPSTREAM_PASS}" | base64 -w0)
  AUTH_HDR=$'Authorization: Basic '"${TOKEN}"$'\r\n'
fi

echo "relay: ${UPSTREAM_HOST}:${UPSTREAM_PORT}/${UPSTREAM_MOUNT}  ->  ${LOCAL_HOST}:${LOCAL_PORT}${LOCAL_MOUNT}" >&2

# 子プロセスを全て道連れにして終了する
cleanup() {
  trap - EXIT INT TERM
  pkill -P $$ 2>/dev/null
  exit 0
}
trap cleanup EXIT INT TERM

# 上流リクエスト + 下流リクエストをパイプで繋ぐ。
# 1. 下流に SOURCE 行を送る
# 2. 上流から GET でストリームを取得し、最初の 14 バイト ("ICY 200 OK\r\n\r\n") をスキップ
# 3. 残りを下流へそのまま流す
{
  # ① 下流に SOURCE 行を送る
  printf 'SOURCE %s %s\r\nSource-Agent: NTRIP relay/0.1\r\n\r\n' "${LOCAL_PASS}" "${LOCAL_MOUNT}"

  # ② 上流に GET → ICY ヘッダー (14 bytes) を破棄して RTCM3 本体を下流へ
  {
    printf 'GET /%s HTTP/1.0\r\nUser-Agent: NTRIP relay/0.1\r\n%s\r\n' "${UPSTREAM_MOUNT}" "${AUTH_HDR}"
    # 上流ソケットを開いたままにする（標準入力 EOF だと OpenBSD nc は読み続けるが
    # 接続を維持するため明示的にスリープ）
    exec </dev/null
    sleep infinity
  } | nc "${UPSTREAM_HOST}" "${UPSTREAM_PORT}" | {
    # ICY 200 OK\r\n\r\n を 1 回だけ読み飛ばし、以降はバッファリング無しで素通し
    dd bs=14 count=1 status=none of=/dev/null
    cat
  }
} | nc "${LOCAL_HOST}" "${LOCAL_PORT}"
