#!/usr/bin/env bash
# M7: build the RELEASE CapnpCore.xcframework from a neutral path.
#
# Zig 0.17.0 has no -fdebugprefix-map (plan §10), so the slices' DWARF holds
# the absolute paths of the build tree. Building from this repo would leak
# the maintainer's home directory into the shipped .a files; staging the
# core under a fixed neutral path keeps the DWARF reproducible and private.
# The dependency cache is redirected too (the default global cache lives
# under $HOME).
#
# Output: dist/CapnpCore.xcframework (+ per-slice sha256 on stdout).
# Fails if any slice's strings mention /Users/ (a leaked home path).
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE=/tmp/capnp-swift-release
OUT=dist
TRIPLES="macos-arm64_x86_64 ios-arm64 ios-arm64_x86_64-simulator"

rm -rf "$STAGE"
mkdir -p "$STAGE/core" "$OUT"
# Only the core build needs staging (Package.swift, Sources, tests never
# enter the .a).
rsync -a --exclude zig-out --exclude .zig-cache core/ "$STAGE/core/"

# Stage the toolchain too: Zig records its std-lib path relative to the
# executable, and the ios-arm64 slice otherwise leaks the mise install
# path into its DWARF (observed 2026-10-07). APFS clone: cheap.
ZIG_INSTALL="$(mise where zig)"
cp -cR "$ZIG_INSTALL" "$STAGE/zigtool"

echo "== staged at $STAGE (neutral paths)"
( cd "$STAGE/core" && env \
    ZIG_GLOBAL_CACHE_DIR="$STAGE/zig-global-cache" \
    E2E_ZIG_GLOBAL_CACHE_DIR="$STAGE/zig-global-cache" \
    "$STAGE/zigtool/zig" build xcframework -Dios=true )

rm -rf "$OUT/CapnpCore.xcframework"
# The build writes the framework next to the stage root (it looks for the
# repo marker above the build dir and stops at the stage boundary).
cp -R "$STAGE/CapnpCore.xcframework" "$OUT/CapnpCore.xcframework"

echo "== slice checksums"
for triple in $TRIPLES; do
    lib="$OUT/CapnpCore.xcframework/$triple/libcapnp_core.a"
    [ -f "$lib" ] || { echo "missing slice: $triple" >&2; exit 1; }
    shasum -a 256 "$lib"
done

echo "== path-leak check (no /Users/ in any slice)"
status=0
for triple in $TRIPLES; do
    lib="$OUT/CapnpCore.xcframework/$triple/libcapnp_core.a"
    if strings "$lib" | grep -q "/Users/"; then
        echo "LEAK: $triple mentions /Users/" >&2
        strings "$lib" | grep "/Users/" | sort -u | head -5 >&2
        status=1
    fi
done
if [ "$status" -ne 0 ]; then exit 1; fi

# --verify: a second fresh build must match the first on its PUBLIC
# surface. Zig 0.17 is not bit-reproducible (~121 bytes of anonymous
# module cache hashes inside DWARF filenames vary; observed 2026-10-07),
# so the plan §10 "identical .a checksums" step is honestly replaced by
# this normalized comparison: exported symbols + strings minus the
# b/<32-hex>/ cache-path components.
if [ "${1:-}" = "--verify" ]; then
    surface() {
        nm -gU "$1" | awk '{$1=""; print}'
        strings "$1" | grep -vE 'b/[0-9a-f]{32}/'
    }
    for triple in $TRIPLES; do
        surface "dist/CapnpCore.xcframework/$triple/libcapnp_core.a" > "/tmp/rel-surface-1.$triple"
    done
    "$0" || exit 1
    for triple in $TRIPLES; do
        lib="dist/CapnpCore.xcframework/$triple/libcapnp_core.a"
        surface "$lib" > "/tmp/rel-surface-2.$triple"
        if ! diff -q "/tmp/rel-surface-1.$triple" "/tmp/rel-surface-2.$triple" > /dev/null; then
            echo "VERIFY FAILED: $triple surfaces differ" >&2
            exit 1
        fi
        rm -f "/tmp/rel-surface-1.$triple" "/tmp/rel-surface-2.$triple"
    done
    echo "VERIFY OK: rebuild surfaces identical on all slices"
fi
echo "OK: dist/CapnpCore.xcframework (neutral paths only)"
