#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
defaults_scratch=$(mktemp -d /tmp/capnp-legacy-defaults-check.XXXXXX)
trap 'rm -rf "$defaults_scratch"' EXIT
mode=${1:-}
(cd tools/capnpc-swift && mise exec -- zig build)
generator="$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
"$generator" --output-dir="$defaults_scratch/widget" < tools/capnpc-swift/tests/requests/defaults.request.bin
"$generator" --output-dir="$defaults_scratch/vendor" < Tests/capnp_test_vendor/test.request.bin
"$generator" --output-dir="$defaults_scratch/lists" < "$script_dir/legacy_list_defaults.request.bin"
vendor_source=$(find "$defaults_scratch/vendor" -name test.swift)
for pair in "widget/defaults.swift:tools/capnpc-swift/tests/golden/defaults.swift" \
            "lists/legacy_list_defaults.swift:$script_dir/generated/legacy_list_defaults.swift"; do
  source_file="$defaults_scratch/${pair%%:*}"
  golden_file=${pair#*:}
  if [[ "$mode" == --update ]]; then cp "$source_file" "$golden_file"; else diff -u "$golden_file" "$source_file"; fi
done
if [[ "$mode" == --update ]]; then cp "$vendor_source" generated/vendor/test.swift; else diff -u generated/vendor/test.swift "$vendor_source"; fi
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -emit-module -emit-library -module-name Capnp Sources/Capnp/*.swift \
  -emit-module-path "$defaults_scratch/Capnp.swiftmodule" -o "$defaults_scratch/libCapnp.dylib"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -I "$defaults_scratch" -L "$defaults_scratch" -lCapnp -Xlinker -rpath -Xlinker "$defaults_scratch" \
  "$defaults_scratch/widget/defaults.swift" "$vendor_source" "$defaults_scratch/lists/legacy_list_defaults.swift" \
  "$script_dir/LegacyDefaultsMain.swift" -o "$defaults_scratch/verify"
"$defaults_scratch/verify"
