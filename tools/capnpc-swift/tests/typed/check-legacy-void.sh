#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
void_scratch=$(mktemp -d /tmp/capnp-legacy-void-check.XXXXXX)
trap 'rm -rf "$void_scratch"' EXIT
(cd tools/capnpc-swift && mise exec -- zig build)
generator="$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
"$generator" --output-dir="$void_scratch/generated" < "$script_dir/legacy_list_defaults.request.bin"
if [[ ${1:-} == --update ]]; then
  cp "$void_scratch/generated/legacy_list_defaults.swift" "$script_dir/generated/legacy_list_defaults.swift"
else
  diff -u "$script_dir/generated/legacy_list_defaults.swift" "$void_scratch/generated/legacy_list_defaults.swift"
fi
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -emit-module -emit-library -module-name Capnp Sources/Capnp/*.swift \
  -emit-module-path "$void_scratch/Capnp.swiftmodule" -o "$void_scratch/libCapnp.dylib"
if ! swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -I "$void_scratch" -L "$void_scratch" -lCapnp -Xlinker -rpath -Xlinker "$void_scratch" \
  "$void_scratch/generated/legacy_list_defaults.swift" "$script_dir/LegacyVoidMain.swift" -o "$void_scratch/verify"; then
  echo 'LEGACY_VOID_FAIL: generated Void list APIs have matching element kind' >&2
  exit 1
fi
"$void_scratch/verify"
