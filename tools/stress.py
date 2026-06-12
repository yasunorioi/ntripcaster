#!/usr/bin/env python3
"""ntripcaster 簡易耐久テスト (3 フェーズ)

usage:
  python3 tools/stress.py
  HOST=192.0.2.1 PORT=2101 MOUNT=/eniwa-bd982 python3 tools/stress.py

env:
  HOST       NTRIP host           (default 127.0.0.1)
  PORT       NTRIP port           (default 2101)
  MOUNT      mountpoint path      (default /eniwa-bd982)
  ADMIN      admin base URL       (default http://127.0.0.1:8080)
  ADMIN_USER admin Basic auth user
  ADMIN_PW   admin Basic auth password

phases:
  1. limit enforcement: 110 concurrent clients × 30 s
     → max_clients_per_source の動作確認 (default 100)
  2. connect storm:     200 concurrent clients × 2 s
     → listener / accept / thread spawn race の検出
  3. soak:               50 concurrent clients × 5 min
     → RSS が単調増加するかでメモリリーク監視

asyncio で 1 プロセス内に並列接続を作るので、bash + /dev/tcp + & の
取りこぼしが無い。各接続の終了状態 (connected / closed_ok / err_*) を
集計し、HTTP ステータス行の先頭 80 byte をサンプルで残す。
"""
import asyncio
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "2101"))
MOUNT = os.environ.get("MOUNT", "/eniwa-bd982")
ADMIN = os.environ.get("ADMIN", "http://127.0.0.1:8080")
USER = os.environ.get("ADMIN_USER", "admin")
PW = os.environ.get("ADMIN_PW", "")


async def one_client(idx: int, duration: float, stats: dict) -> None:
    try:
        reader, writer = await asyncio.open_connection(HOST, PORT)
        req = (
            f"GET {MOUNT} HTTP/1.0\r\n"
            f"User-Agent: ntripcaster-stress/{idx}\r\n\r\n"
        ).encode()
        writer.write(req)
        await writer.drain()
        # status line
        try:
            line = await asyncio.wait_for(reader.readline(), timeout=3)
        except asyncio.TimeoutError:
            stats["err_no_response"] += 1
            writer.close()
            await writer.wait_closed()
            return
        if b"200" not in line and b"ICY" not in line:
            stats["err_bad_status"] += 1
            stats.setdefault("samples", []).append(line[:80])
            writer.close()
            await writer.wait_closed()
            return
        stats["connected"] += 1
        # hold the connection by reading bytes until duration elapses
        try:
            data = await asyncio.wait_for(
                reader.read(1024 * 1024), timeout=duration
            )
            stats["bytes"] += len(data)
        except asyncio.TimeoutError:
            pass
        writer.close()
        await writer.wait_closed()
        stats["closed_ok"] += 1
    except (ConnectionRefusedError, ConnectionResetError):
        stats["err_conn"] += 1
    except Exception as e:  # noqa: BLE001
        stats["err_other"] += 1
        stats.setdefault("samples", []).append(str(e)[:80])


def admin_status() -> dict:
    try:
        req = urllib.request.Request(f"{ADMIN}/api/v1/status")
        if USER:
            cred = base64.b64encode(f"{USER}:{PW}".encode()).decode()
            req.add_header("Authorization", f"Basic {cred}")
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.loads(r.read())
    except Exception as e:  # noqa: BLE001
        return {"err": str(e)}


def rss_kb():
    try:
        out = subprocess.check_output(["pidof", "ntripcaster"]).strip().split()
        if not out:
            return None
        pid = out[0].decode()
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except Exception:  # noqa: BLE001
        return None


def snap(label: str) -> None:
    s = admin_status()
    print(f"[{label}] {s} RSS={rss_kb()}KB", flush=True)


async def phase(name: str, n_clients: int, hold_sec: int) -> None:
    print(
        f"\n=== {name}: {n_clients} clients × {hold_sec}s hold ===",
        flush=True,
    )
    snap("before")
    stats = {
        "connected": 0,
        "closed_ok": 0,
        "err_no_response": 0,
        "err_bad_status": 0,
        "err_conn": 0,
        "err_other": 0,
        "bytes": 0,
    }
    t0 = time.monotonic()
    tasks = [
        asyncio.create_task(one_client(i, hold_sec, stats))
        for i in range(n_clients)
    ]
    deadline = t0 + hold_sec
    while time.monotonic() < deadline:
        sleep_for = min(30, max(1, hold_sec / 4))
        await asyncio.sleep(sleep_for)
        snap(f"t={int(time.monotonic()-t0)}s")
    await asyncio.gather(*tasks, return_exceptions=True)
    snap("after")
    print(f"  results: {stats}", flush=True)


async def main() -> None:
    snap("baseline")
    await phase("Phase 1 (limit enforcement)", 110, 30)
    await phase("Phase 2 (connect storm)", 200, 2)
    await phase("Phase 3 (soak)", 50, 300)
    snap("final")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(130)
