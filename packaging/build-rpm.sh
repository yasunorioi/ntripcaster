#!/usr/bin/env bash
# packaging/build-rpm.sh — Build an .rpm package from a pre-built binary
#
# Usage: packaging/build-rpm.sh <binary> <version> <rpm_arch>
#   binary   : path to the ntripcaster binary
#   version  : e.g. 0.2.0
#   rpm_arch : x86_64 | aarch64 | armv7hl | mipsel
#
# Requires: rpm-build (apt-get install rpm  OR  dnf install rpm-build)
set -euo pipefail

BINARY="${1:?Usage: $0 <binary> <version> <arch>}"
VERSION="${2:?missing version}"
ARCH="${3:?missing arch}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RPMBUILD_ROOT="${REPO_ROOT}/.rpm-tmp"
mkdir -p "${RPMBUILD_ROOT}/SOURCES" "${RPMBUILD_ROOT}/SPECS" \
         "${RPMBUILD_ROOT}/BUILD"   "${RPMBUILD_ROOT}/RPMS" \
         "${RPMBUILD_ROOT}/SRPMS"

# Copy sources into rpmbuild SOURCES
cp "$BINARY"                              "${RPMBUILD_ROOT}/SOURCES/ntripcaster"
cp "$REPO_ROOT/ntripcaster.service"       "${RPMBUILD_ROOT}/SOURCES/ntripcaster.service"
cp "$REPO_ROOT/conf/ntripcaster.conf"     "${RPMBUILD_ROOT}/SOURCES/ntripcaster.conf"

# Expand spec template
sed -e "s/@VERSION@/${VERSION}/g" -e "s/@RPMARCH@/${ARCH}/g" \
  "$SCRIPT_DIR/rpm/ntripcaster.spec.in" \
  > "${RPMBUILD_ROOT}/SPECS/ntripcaster.spec"

rpmbuild --target "${ARCH}" \
  --define "_topdir ${RPMBUILD_ROOT}" \
  -bb "${RPMBUILD_ROOT}/SPECS/ntripcaster.spec"

# Copy built RPM to repo root
find "${RPMBUILD_ROOT}/RPMS" -name "*.rpm" -exec cp {} "${REPO_ROOT}/" \;

rm -rf "${RPMBUILD_ROOT}"
echo "Built RPM for ${ARCH} v${VERSION}"
