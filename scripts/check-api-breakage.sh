#!/usr/bin/env bash
# The Stable Swift API gate (docs/stability.md, M9 G4): no breaking change
# in the Capnp, CapnpRPC and CapnpNW products since the last release.
#
# The baseline is the release that the COMMITTED Package.swift downloads
# (its CapnpCore URL .../releases/download/<version>/...), so each release
# commit moves it. CI swaps Package.swift to the local core first; reading
# the committed file keeps the baseline right.
#
# Experimental API (typed generation, QUIC; stability.md) may change. Allow
# such a breakage by its exact message, one per line, in
# scripts/api-breakage-allowlist.txt ('#' lines are comments).
#
#   scripts/check-api-breakage.sh [baseline-tag]
set -euo pipefail
cd "$(dirname "$0")/.."

baseline=${1:-$(git show HEAD:Package.swift |
  sed -n 's#.*releases/download/\([^/"]*\)/CapnpCore.xcframework.zip.*#\1#p' | head -1)}
if [ -z "$baseline" ]; then
  echo "check-api-breakage: the committed Package.swift names no release core URL" >&2
  exit 2
fi
# A shallow CI checkout has no tags: fetch the baseline tag alone.
if ! git rev-parse -q --verify "refs/tags/$baseline^{commit}" >/dev/null; then
  git fetch --quiet --depth=1 origin "refs/tags/$baseline:refs/tags/$baseline"
fi

allow=$(mktemp /tmp/capnp-api-allowlist-XXXXXX)
trap 'rm -f "$allow"' EXIT
grep -v -e '^#' -e '^[[:space:]]*$' scripts/api-breakage-allowlist.txt >"$allow" || true

echo "check-api-breakage: Capnp, CapnpRPC, CapnpNW against $baseline ($(wc -l <"$allow" | tr -d ' ') allowed)"
swift package diagnose-api-breaking-changes "$baseline" \
  --products Capnp CapnpRPC CapnpNW --breakage-allowlist-path "$allow"
