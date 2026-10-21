#!/usr/bin/env bash
# Print core/zig-pkg/<hash>, the unpacked capnp-zig package of the hash that
# core/build.zig.zon pins. After a pin bump core/zig-pkg/ still holds the old
# package too, so a glob's first match can be the stale one. Exit 1 when the
# pin or its unpacked package is missing (run a core build first).
set -euo pipefail
cd "$(dirname "$0")/.."
hash="$(sed -n 's/^ *\.hash = "\(capnpc_zig-[^"]*\)",$/\1/p' core/build.zig.zon)"
[ -n "$hash" ] || { echo "pinned-capnp-zig: no capnpc_zig hash in core/build.zig.zon" >&2; exit 1; }
[ -d "core/zig-pkg/$hash" ] || { echo "pinned-capnp-zig: no core/zig-pkg/$hash (run a core build first)" >&2; exit 1; }
echo "core/zig-pkg/$hash"
