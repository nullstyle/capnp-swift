#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
legacy_scratch=$(mktemp -d /tmp/capnp-legacy-rpc-check.XXXXXX)
trap 'rm -rf "$legacy_scratch"' EXIT
core=CapnpCore.xcframework/macos-arm64_x86_64
if [[ ! -f "$core/libcapnp_core.a" ]]; then
  echo 'LEGACY_RPC_FAIL: missing macOS core archive' >&2
  exit 1
fi
mode=${1:-}
(cd tools/capnpc-swift && mise exec -- zig build)
generator="$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
"$generator" --output-dir="$legacy_scratch/generated" < "$script_dir/legacy_reserved.request.bin"
golden="$script_dir/generated/legacy_reserved.swift"
if [[ "$mode" == --update ]]; then
  cp "$legacy_scratch/generated/legacy_reserved.swift" "$golden"
else
  diff -u "$golden" "$legacy_scratch/generated/legacy_reserved.swift"
fi
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -emit-module -emit-library -module-name Capnp Sources/Capnp/*.swift \
  -emit-module-path "$legacy_scratch/Capnp.swiftmodule" -o "$legacy_scratch/libCapnp.dylib"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -Xcc -Wno-comment \
  -emit-module -emit-library -module-name CapnpRPC Sources/CapnpRPC/*.swift \
  -I "$legacy_scratch" -I "$core/Headers" -L "$legacy_scratch" -lCapnp "$core/libcapnp_core.a" \
  -emit-module-path "$legacy_scratch/CapnpRPC.swiftmodule" -o "$legacy_scratch/libCapnpRPC.dylib" \
  -Xlinker -rpath -Xlinker "$legacy_scratch"
if ! swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -Xcc -Wno-comment \
  -I "$legacy_scratch" -I "$core/Headers" -L "$legacy_scratch" -lCapnp -lCapnpRPC \
  -Xlinker -rpath -Xlinker "$legacy_scratch" "$legacy_scratch/generated/legacy_reserved.swift" \
  "$script_dir/LegacyReservedMain.swift" -o "$legacy_scratch/verify"; then
  echo 'LEGACY_RPC_FAIL: ancestor views preserve target and connection' >&2
  exit 1
fi
"$legacy_scratch/verify"
