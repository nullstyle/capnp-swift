#!/usr/bin/env bash
# H7 snapshot gate (replaces the header-drift test, which runs upstream as
# capnp-zig's src/native/abi_header_test.zig since v0.23.0): the header we
# SHIP (core/include/capnp_core.h — what the XCFramework carries and what
# translate-c compiles against) must be identical to the pinned package's
# src/native/include/capnp_core.h, so a pin bump can never drift from the
# header it was built against.
#
# Refresh procedure on a pin bump (release.md "Version bookkeeping"):
#   cp core/zig-pkg/capnpc_zig-<new>/src/native/include/capnp_core.h \
#      core/include/capnp_core.h
set -euo pipefail
cd "$(dirname "$0")/.."

pkg="$(ls core/zig-pkg/capnpc_zig-*/src/native/include/capnp_core.h 2>/dev/null | head -1)"
[ -n "$pkg" ] || { echo "check-native-header: no capnpc_zig package under core/zig-pkg (run a core build first)" >&2; exit 1; }

if diff -u "core/include/capnp_core.h" "$pkg"; then
    echo "check-native-header: OK (snapshot == $(basename "$(dirname "$(dirname "$(dirname "$pkg")")")"))"
else
    echo "check-native-header: FAIL: core/include/capnp_core.h drifted from the pinned package's header" >&2
    echo "  refresh with: cp $pkg core/include/capnp_core.h" >&2
    exit 1
fi
