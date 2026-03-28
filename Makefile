## NtripCaster — Zig rewrite convenience Makefile
## Wraps `zig build` for common tasks. Requires Zig 0.14.0+ in PATH.
##
## Usage:
##   make                         # build for host (debug)
##   make release                 # build for host (ReleaseSafe)
##   make all-targets             # cross-compile all architectures
##   make test                    # unit + integration tests
##   make interop                 # shell-based interop tests (needs nc/xxd)
##   make package-deb ARCH=amd64  # build .deb (needs dpkg-dev)
##   make package-rpm ARCH=x86_64 # build .rpm (needs rpm-build)
##   make package-opkg ARCH=x86_64 # build .ipk
##   make packages                # build all packages for host arch
##   make clean                   # remove build artefacts

ZIG      ?= zig
VERSION  := $(shell grep '\.version = ' build.zig.zon | head -1 | sed 's/.*"\(.*\)".*/\1/')

# Host binary for packaging targets
BINARY   ?= zig-out/bin/ntripcaster

# Default deb/rpm/opkg arch (override with ARCH=...)
ARCH     ?= $(shell dpkg --print-architecture 2>/dev/null || echo "amd64")

.PHONY: all release test interop clean \
        all-targets x86_64 aarch64 armv7 mipsel \
        package-deb package-rpm package-opkg packages

## ── Build targets ────────────────────────────────────────────────────────────

all:
	$(ZIG) build

release:
	$(ZIG) build -Doptimize=ReleaseSafe

all-targets: x86_64 aarch64 armv7 mipsel

x86_64:
	$(ZIG) build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
	             --prefix zig-out-x86_64-musl

aarch64:
	$(ZIG) build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe \
	             --prefix zig-out-aarch64

armv7:
	$(ZIG) build -Dtarget=arm-linux-musleabihf -Doptimize=ReleaseSafe \
	             --prefix zig-out-armv7

mipsel:
	$(ZIG) build -Dtarget=mipsel-linux-musl -Doptimize=ReleaseSafe \
	             --prefix zig-out-mipsel

## ── Test targets ─────────────────────────────────────────────────────────────

test:
	$(ZIG) build test

interop: all
	bash tests/test_interop.sh

## ── Packaging targets ────────────────────────────────────────────────────────

package-deb: $(BINARY)
	packaging/build-deb.sh "$(BINARY)" "$(VERSION)" "$(ARCH)"

package-rpm: $(BINARY)
	packaging/build-rpm.sh "$(BINARY)" "$(VERSION)" "$(ARCH)"

package-opkg: $(BINARY)
	packaging/build-opkg.sh "$(BINARY)" "$(VERSION)" "$(ARCH)"

packages: package-deb package-rpm package-opkg

## ── Clean ────────────────────────────────────────────────────────────────────

clean:
	rm -rf zig-out zig-out-* .zig-cache .pkg-tmp .rpm-tmp .ipk-tmp
	find . -maxdepth 1 \( -name "*.deb" -o -name "*.rpm" -o -name "*.ipk" \) -delete
