# legacy — Original C NtripCaster 0.1.5

This directory contains the original C implementation of NtripCaster, version 0.1.5,
developed by BKG (Federal Agency for Cartography and Geodesy, Germany).

## Origin

- **Source**: BKG NtripCaster 0.1.5 (http://igs.bkg.bund.de/ntrip/download)
- **License**: GNU GPL v2 (see source files)
- **Credit**: Lesparre, Weber — BKG Frankfurt

## Purpose

Kept as a reference implementation for:
- Protocol compliance (NTRIP v1 SOURCE/GET handshake, ICY 200 OK, SOURCETABLE format)
- Configuration file format (`ntripcaster.conf`, `sourcetable.dat`)
- Behavior baseline for interoperability testing

## Zig Rewrite

The active implementation is in `../src/` (Zig 0.14.0).
See `../README.md` for build instructions.
