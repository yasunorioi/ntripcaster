# ntripcaster

📖 **日本語 README**: [README.md](README.md)

NTRIP v1 / v2 caster — a Zig rewrite of the BKG reference implementation,
with an original FKP / VRS Network RTK engine layered on top (not present in
BKG 0.1.5).

> **Originally developed by BKG (Bundesamt für Geodäsie und Kartographie)**
> as part of the NTRIP protocol reference implementation (NtripCaster 0.1.5).
> The C source itself is no longer mirrored in this repo — git history
> through commit `753253f` still contains it under `/legacy/`, and the
> upstream BKG release remains the canonical source.

This English README is a focused summary. For the architecture diagram, FKP /
VRS internals, admin API reference, mountpoint semantics, and detailed
config table, see the Japanese [`README.md`](README.md) — those sections
have not been duplicated here.

---

## Features

- NTRIP v1 / v2 server / source / client relay
- HTTP Basic authentication (per-mountpoint, plus `default_mount_access deny|open`)
- Per-source ring buffer (1 MB, RwLock split so 100+ rovers reading in
  parallel do not contend with each other; verified by `tools/stress.py`
  with 100 clients holding a 5 min soak)
- Connection limits (`max_clients` / `max_clients_per_source` / `max_sources`)
- Fully auto-generated sourcetable: CAS / NET lines are built from config,
  STR lines are derived from live sources. No hand-written `sourcetable.dat`
- RTCM 3 frame analysis (0xD3 sync, CRC-24Q, message-type detection,
  1005/1006 antenna reference point lat/lon extraction)
- **Harsh-conditions hardening** (designed around farm equipment over LTE /
  Starlink): both client and source sockets get `SO_KEEPALIVE` +
  `SO_SNDTIMEO`. Half-open source TCP is detected by the kernel within
  ~75 s. When a new SOURCE login arrives for a mount whose existing source
  has been idle for 30 s, the old connection is force-evicted so the
  reconnect succeeds with zero delay
- **FKP (Flächenkorrekturparameter) live service** — connects to 3+ NTRIP
  upstreams, relays the primary upstream's raw RTCM3 verbatim, and injects
  periodic Type 59 frames into the same virtual mountpoint (Network RTK)
- **Admin UI + JSON API** (`/api/v1/{status,sources,clients,events}`) with
  SSE live updates, embedded vanilla-JS dashboard, a Leaflet + OSM
  base-station map, and a source-offline red banner
- Per-connection telemetry: peer address, bytes_in / bytes_out, started_at,
  last_data_at, per-source RTCM3 message-type counts, BufferOverrun
  disconnect counter
- Cross-compile ready: `x86_64-linux-musl`, `aarch64-linux-musl`,
  `arm-linux-musleabihf`, `mipsel-linux-musl`
- systemd service unit with hardening options
- Single static binary — no runtime dependencies

## Build

Requires **Zig 0.15.x** (tested with 0.15.2). `build.zig` `@compileError`s
on 0.16+ — see "Zig 0.16+ note" below.

```bash
zig build                          # native debug build
zig build test                     # all unit tests
zig build -Doptimize=ReleaseSafe   # optimised release
```

### Cross-compile

```bash
zig build -Dtarget=aarch64-linux-musl     # RPi / ARM64 Linux (static musl)
zig build -Dtarget=x86_64-linux-musl      # x86_64 Alpine / OpenWrt
```

Artifacts land in `zig-out/bin/ntripcaster`.

### Zig 0.16+ note

Zig 0.16 routed `std.Thread.Mutex` and `std.net` through the new
`std.Io` interface (`std.Io.Mutex`, `std.Io.net`), so porting requires
threading an `*std.Io` runtime through ServerState / Source / Relay /
FKP. That work is not done yet, and 0.17 keeps the same design.
Stay on 0.15.x for now (`build.zig` enforces this with a `@compileError`).
If `snap` installed 0.16, replace it with the upstream tarball:

```bash
sudo snap remove zig
mkdir -p ~/.local/zig ~/.local/bin
cd ~/.local/zig
wget https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz
tar xf zig-x86_64-linux-0.15.2.tar.xz
ln -sf ~/.local/zig/zig-x86_64-linux-0.15.2/zig ~/.local/bin/zig
zig version    # → 0.15.2
```

## Install

Three routes. **(A)** is the recommended path; **(B)** is manual setup;
**(C)** has notes for hosts that still have the legacy C version installed.

### (A) Package install (recommended)

Build a `.deb` / `.rpm` / `.ipk` and install:

```bash
make package-deb ARCH=amd64
make package-rpm ARCH=x86_64
make package-opkg ARCH=x86_64
make packages                      # all three at once
```

`.deb` layout (postinst creates the `ntripcaster:ntripcaster` system user,
the log directory, and enables the service):

| Path | Contents |
|---|---|
| `/usr/local/bin/ntripcaster` | Binary |
| `/etc/ntripcaster/ntripcaster.conf` | Live config (seeded from example on first install only — **upgrades never touch it**) |
| `/usr/share/doc/ntripcaster/ntripcaster.conf.example` | Annotated reference |
| `/lib/systemd/system/ntripcaster.service` | systemd unit |
| `/var/log/ntripcaster/` | Log directory |

```bash
sudo dpkg -i ntripcaster_0.5.0_amd64.deb
sudo systemctl start ntripcaster
```

### (B) Source build, manual setup

```bash
zig build -Doptimize=ReleaseSafe
sudo install -m 755 zig-out/bin/ntripcaster /usr/local/bin/ntripcaster

sudo mkdir -p /etc/ntripcaster
sudo cp conf/ntripcaster.conf /etc/ntripcaster/ntripcaster.conf
sudo $EDITOR /etc/ntripcaster/ntripcaster.conf

sudo useradd -r -s /usr/sbin/nologin -d /var/empty ntripcaster
sudo mkdir -p /var/log/ntripcaster
sudo chown ntripcaster:ntripcaster /var/log/ntripcaster
sudo chown -R ntripcaster:ntripcaster /etc/ntripcaster

sudo install -m 644 ntripcaster.service /etc/systemd/system/ntripcaster.service
sudo systemctl daemon-reload
sudo systemctl enable --now ntripcaster
```

### (C) Migrating from the legacy C build

If you previously installed BKG NtripCaster 0.1.5 with
`./configure --prefix=/usr/local/ntripcaster && make install`, paths
differ from the Zig build:

- C: `/usr/local/ntripcaster/bin/ntripcaster` + `/usr/local/ntripcaster/conf/`
- Zig: `/usr/local/bin/ntripcaster` + `/etc/ntripcaster/`

To switch over:

```bash
sudo systemctl stop ntripcaster
sudo systemctl disable ntripcaster
# install Zig version via (A) or (B), then:
sudo systemctl daemon-reload
sudo systemctl enable --now ntripcaster
# move the legacy tree aside after confirming everything works
sudo mv /usr/local/ntripcaster /usr/local/ntripcaster.legacy.bak
```

## Config quick reference

Default config path: `/etc/ntripcaster/ntripcaster.conf`.

Most-touched keys:

| Key | Default | Description |
|---|---|---|
| `port` | `2101` | NTRIP listener port |
| `encoder_password` | *(must set)* | Source push password |
| `server_name` | `localhost` | Server hostname (used in sourcetable CAS line) |
| `max_clients` | `100` | Total concurrent client cap |
| `max_clients_per_source` | `100` | Concurrent clients per mount |
| `max_sources` | `40` | Concurrent source cap |
| `default_mount_access` | `deny` | `/MOUNT` line missing in config: `deny` returns 401, `open` lets anyone GET as long as a source is pushing |
| `admin_bind` | `127.0.0.1` | Admin HTTP listener address |
| `admin_port` | `8080` | Admin HTTP listener port |
| `admin_user` / `admin_password` | *(empty = no auth)* | Required if `admin_bind` is anything other than loopback |
| `caster_country` / `caster_latitude` / `caster_longitude` / `caster_identifier` / `caster_operator` | *(empty)* | Filled into the auto-generated CAS line |

### Mountpoints

Source push side: no config line needed — the mount appears as soon as
the base station connects with `encoder_password`. Client read access,
however, is gated by `/MOUNT` lines in the config (unless
`default_mount_access open`):

```ini
/eniwa-hogehoge333                              # open mount (any rover)
/eniwa-hogehoge333:rover1:pw1,rover2:pw2        # auth-gated mount
```

Config is read once at startup; restart the service after editing.

## Admin UI

Default `http://127.0.0.1:8080/` — SSE-driven dashboard with live status,
sources / clients tables, and a Leaflet map showing the base-station
position whenever the source has sent RTCM Type 1005 / 1006.

![ntripcaster admin dashboard with OpenStreetMap base-station pin](docs/screenshots/admin-map.png)

JSON endpoints:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | Embedded HTML dashboard |
| `GET` | `/api/v1/status` | version / uptime / listen / source + client counts |
| `GET` | `/api/v1/sources` | Source list with peer, bytes_in, msg_types, station coord |
| `GET` | `/api/v1/clients` | Client list with id, peer, mount, bytes_out |
| `GET` | `/api/v1/events` | SSE composite snapshot every 1 s |

If `admin_user` is set, all endpoints require HTTP Basic auth. Setting
`admin_bind 0.0.0.0` is supported but requires the auth pair — there is
no other authorization layer.

## Stress test

`tools/stress.py` runs an asyncio-based 3-phase load drill (limit
enforcement → connect storm → 5 min soak) against any caster.

```bash
ADMIN_USER=admin ADMIN_PW=… python3 tools/stress.py
```

Measured against default config (`max_clients=100`) with a Trimble BD982
pushing multi-GNSS MSM7 at ~470 B/s on a single mount:

| Phase | Setup | Result |
|---|---|---|
| 1. limit enforcement | 110 clients × 30 s hold | 98 connected / 12 `503 Too Many Clients`, 1.39 MB transferred (≈ 14 KB / client) |
| 2. connect storm | 200 clients × 2 s hold | 200 cleanly rejected as 503 (Phase 1 hadn't drained yet) — graceful overload |
| 3. soak | 50 clients × 5 min | 50 connections held, 6.99 MB transferred, RSS flat (3.4 MB), `err_bad_status=0`, `BufferOverrun=0` |

100 concurrent clients hold cleanly for 5 minutes. No memory leak. For
~100-rover agricultural deployments, raising `max_clients` to 150 leaves
headroom for reconnect churn.

## References

- 田中慎治 (2003) "ネットワークRTK-GPS測位に関する研究", master's thesis,
  Tokyo University of Marine Science and Technology (formerly Tokyo
  University of Mercantile Marine).
  - FKP formulae: §4.3.3–4.3.4 (pp. 51–57)

## License

GNU General Public License v2.0 — see [LICENSE](LICENSE).

Original NtripCaster © BKG (Bundesamt für Geodäsie und Kartographie),
Frankfurt, Germany.
Zig rewrite © yasunorioi.
