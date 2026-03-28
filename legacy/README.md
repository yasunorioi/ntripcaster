# legacy — Original C NtripCaster 0.1.5

This directory contains the original C implementation of NtripCaster, version 0.1.5,
developed by **BKG (Bundesamt für Geodäsie und Kartographie)** — the Federal Agency
for Cartography and Geodesy of Germany, located in Frankfurt am Main.

## Origin

- **Developer**: BKG (Bundesamt für Geodäsie und Kartographie), Frankfurt am Main, Germany
  - Lesparre, Weber — BKG
- **Version**: NtripCaster 0.1.5
- **Source**: http://igs.bkg.bund.de/ntrip/download
- **License**: GNU General Public License v2 (see source file headers)
- **Context**: Developed as the NTRIP protocol reference implementation within
  the EUREF-IP project (http://www.epncb.oma.be/euref_IP)

## How to Build (Original autoconf)

```bash
cd legacy/
autoreconf -fi          # autoconf/automake regeneration
./configure --prefix=/usr/local
make
sudo make install
```

Requires: `autoconf`, `automake`, `gcc`, `libc-dev`.

On modern systems (glibc 2.34+), minor patches may be needed for implicit
function declarations. See commit history for musl/Alpine compatibility fixes.

## License

GNU General Public License v2. See individual source file headers for copyright
notices. Key notice from `src/ntripcaster.c`:

> This program is free software; you can redistribute it and/or modify
> it under the terms of the GNU General Public License as published by
> the Free Software Foundation; either version 2 of the License, or
> (at your option) any later version.

## Why We Preserve This

1. **Protocol compliance baseline** — NTRIP v1 SOURCE/GET handshake, `ICY 200 OK`
   responses, and SOURCETABLE format are verified against this implementation
   in interoperability tests (`tests/interop/`).

2. **Configuration format reference** — `ntripcaster.conf` and `sourcetable.dat`
   format is derived directly from this implementation. The Zig parser
   (`src/config/parser.zig`) is validated against legacy config files.

3. **Behavior oracle** — Edge cases and protocol ambiguities are resolved by
   running the original C implementation and observing its behavior.

4. **Historical record** — BKG's work established NTRIP as the de facto standard
   for GNSS correction data distribution. This code is part of that history.

## Zig Rewrite

The active implementation is in `../src/` (Zig 0.14.0).

Key improvements over this C implementation:
- Memory safety (no manual malloc/free)
- Lock-free ring buffer for multi-client relay
- Cross-compile to `aarch64-linux-musl` / `x86_64-linux-musl` from single host
- systemd integration with security hardening
- Single static binary

See `../README.md` for build and usage instructions.
See `../CHANGELOG.md` for full rewrite history.
