#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
empty_scratch=$(mktemp -d /tmp/capnp-empty-composite-check.XXXXXX)
trap 'rm -rf "$empty_scratch"' EXIT
core=CapnpCore.xcframework/macos-arm64_x86_64
(cd tools/capnpc-swift && mise exec -- zig build)
generator="$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
"$generator" --typed --output-dir="$empty_scratch/generated" < "$script_dir/empty_composite.request.bin"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -emit-module -emit-library -module-name Capnp Sources/Capnp/*.swift \
  -emit-module-path "$empty_scratch/Capnp.swiftmodule" -o "$empty_scratch/libCapnp.dylib"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -Xcc -Wno-comment \
  -emit-module -emit-library -module-name CapnpRPC Sources/CapnpRPC/*.swift \
  -I "$empty_scratch" -I "$core/Headers" -L "$empty_scratch" -lCapnp "$core/libcapnp_core.a" \
  -emit-module-path "$empty_scratch/CapnpRPC.swiftmodule" -o "$empty_scratch/libCapnpRPC.dylib" \
  -Xlinker -rpath -Xlinker "$empty_scratch"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -Xcc -Wno-comment \
  -I "$empty_scratch" -I "$core/Headers" -L "$empty_scratch" -lCapnp -lCapnpRPC \
  -Xlinker -rpath -Xlinker "$empty_scratch" "$empty_scratch/generated/empty_composite.swift" \
  "$script_dir/EmptyCompositeMain.swift" -o "$empty_scratch/verify"
"$empty_scratch/verify" "$empty_scratch/swift.bin"
if command -v capnp >/dev/null; then
  printf '(items = [], zeros = [])\n' | capnp encode "$script_dir/empty_composite.capnp" EmptyContainer > "$empty_scratch/cpp.bin"
  if ! cmp "$script_dir/empty_composite.cpp.bin" "$empty_scratch/cpp.bin"; then
    echo 'EMPTY_COMPOSITE_FAIL: independent C++ fixture is reproducible' >&2
    exit 1
  fi
  capnp decode "$script_dir/empty_composite.capnp" EmptyContainer < "$empty_scratch/swift.bin" > "$empty_scratch/decoded.txt"
  if ! rg -q 'items = \[\]' "$empty_scratch/decoded.txt" || ! rg -q 'zeros = \[\]' "$empty_scratch/decoded.txt"; then
    echo 'EMPTY_COMPOSITE_FAIL: C++ decodes Swift empty composite overrides' >&2
    exit 1
  fi
  echo 'PASS: C++ reproduces fixture and decodes Swift empty composite overrides'
elif [[ ${1:-} == --require-cpp ]]; then
  echo 'EMPTY_COMPOSITE_FAIL: native C++ compiler is required' >&2
  exit 1
else
  echo 'SKIP: live C++ reproduction unavailable; committed independent bytes verified by Swift and released core'
fi
