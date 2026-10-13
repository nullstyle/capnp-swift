#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
enum_scratch=$(mktemp -d /tmp/capnp-legacy-enum-check.XXXXXX)
trap 'rm -rf "$enum_scratch"' EXIT
(cd tools/capnpc-swift && mise exec -- zig build)
generator="$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
"$generator" --output-dir="$enum_scratch/generated" < "$script_dir/enum_defaults.request.bin"
if [[ ${1:-} == --update ]]; then
  cp "$enum_scratch/generated/enum_defaults.swift" "$script_dir/generated/enum_defaults.swift"
else
  diff -u "$script_dir/generated/enum_defaults.swift" "$enum_scratch/generated/enum_defaults.swift"
fi
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -emit-module -emit-library -module-name Capnp Sources/Capnp/*.swift \
  -emit-module-path "$enum_scratch/Capnp.swiftmodule" -o "$enum_scratch/libCapnp.dylib"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -I "$enum_scratch" -L "$enum_scratch" -lCapnp -Xlinker -rpath -Xlinker "$enum_scratch" \
  "$enum_scratch/generated/enum_defaults.swift" "$script_dir/LegacyEnumMain.swift" -o "$enum_scratch/verify"
"$enum_scratch/verify"
