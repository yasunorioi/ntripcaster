#!/usr/bin/env bash
# packaging/build-deb.sh — Build a .deb package from a pre-built binary
#
# Usage: packaging/build-deb.sh <binary> <version> <deb_arch>
#   binary   : path to the ntripcaster binary
#   version  : e.g. 0.2.0
#   deb_arch : amd64 | arm64 | armhf | mipsel
#
# Requires: dpkg-deb (apt-get install dpkg-dev)
set -euo pipefail

BINARY="${1:?Usage: $0 <binary> <version> <arch>}"
VERSION="${2:?missing version}"
ARCH="${3:?missing arch}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PKG="ntripcaster_${VERSION}_${ARCH}"
WORK="${REPO_ROOT}/.pkg-tmp/${PKG}"

# ── Directory layout ──────────────────────────────────────────────────────────
rm -rf "$WORK"
mkdir -p \
  "$WORK/DEBIAN" \
  "$WORK/usr/local/bin" \
  "$WORK/lib/systemd/system" \
  "$WORK/etc/ntripcaster" \
  "$WORK/usr/share/doc/ntripcaster"

# ── Files ──────────────────────────────────────────────────────────────────────
install -m 0755 "$BINARY" "$WORK/usr/local/bin/ntripcaster"
install -m 0644 "$REPO_ROOT/ntripcaster.service" \
  "$WORK/lib/systemd/system/ntripcaster.service"
# Config: both the live location (conffiles) and a doc example
install -m 0640 "$REPO_ROOT/conf/ntripcaster.conf" \
  "$WORK/etc/ntripcaster/ntripcaster.conf"
install -m 0644 "$REPO_ROOT/conf/ntripcaster.conf" \
  "$WORK/usr/share/doc/ntripcaster/ntripcaster.conf.example"

# ── DEBIAN control ────────────────────────────────────────────────────────────
sed -e "s/@VERSION@/${VERSION}/g" -e "s/@ARCH@/${ARCH}/g" \
  "$SCRIPT_DIR/deb/control.in" > "$WORK/DEBIAN/control"

install -m 0755 "$SCRIPT_DIR/deb/postinst" "$WORK/DEBIAN/postinst"
install -m 0755 "$SCRIPT_DIR/deb/postrm"   "$WORK/DEBIAN/postrm"
install -m 0644 "$SCRIPT_DIR/deb/conffiles" "$WORK/DEBIAN/conffiles"

# ── Build ──────────────────────────────────────────────────────────────────────
dpkg-deb --root-owner-group --build "$WORK" \
  "${REPO_ROOT}/${PKG}.deb"

rm -rf "$WORK"
echo "Built: ${PKG}.deb"
