#!/usr/bin/env bash
# packaging/build-opkg.sh — Build an OpenWRT .ipk package from a pre-built binary
#
# Usage: packaging/build-opkg.sh <binary> <version> <opkg_arch>
#   binary    : path to the ntripcaster binary
#   version   : e.g. 0.2.0
#   opkg_arch : mipsel_24kc | x86_64 | aarch64_generic | arm_cortex-a7_neon-vfpv4
#
# .ipk format: concatenation of 3 tar.gz files inside an outer tar:
#   debian-binary  (contains "2.0\n")
#   control.tar.gz (DEBIAN control files)
#   data.tar.gz    (payload files)
set -euo pipefail

BINARY="${1:?Usage: $0 <binary> <version> <arch>}"
VERSION="${2:?missing version}"
ARCH="${3:?missing arch}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PKG="ntripcaster_${VERSION}_${ARCH}"
WORK="${REPO_ROOT}/.ipk-tmp/${PKG}"

rm -rf "$WORK"
mkdir -p \
  "${WORK}/data/usr/bin" \
  "${WORK}/data/etc/ntripcaster" \
  "${WORK}/control"

# ── Payload ───────────────────────────────────────────────────────────────────
install -m 0755 "$BINARY"                     "${WORK}/data/usr/bin/ntripcaster"
install -m 0640 "$REPO_ROOT/conf/ntripcaster.conf" \
  "${WORK}/data/etc/ntripcaster/ntripcaster.conf"

# ── Control ───────────────────────────────────────────────────────────────────
sed -e "s/@VERSION@/${VERSION}/g" -e "s/@ARCH@/${ARCH}/g" \
  "$SCRIPT_DIR/opkg/control.in" > "${WORK}/control/control"

# ── Assemble .ipk (ar archive) ────────────────────────────────────────────────
OUT="${REPO_ROOT}/${PKG}.ipk"

# data.tar.gz
tar -czf "${WORK}/data.tar.gz" -C "${WORK}/data" .

# control.tar.gz
tar -czf "${WORK}/control.tar.gz" -C "${WORK}/control" .

# debian-binary
printf '2.0\n' > "${WORK}/debian-binary"

# outer ar archive
ar r "$OUT" "${WORK}/debian-binary" "${WORK}/control.tar.gz" "${WORK}/data.tar.gz"

rm -rf "$WORK"
echo "Built: ${PKG}.ipk"
