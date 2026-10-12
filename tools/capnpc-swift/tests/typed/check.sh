#!/bin/bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
tmp=$(mktemp -d /tmp/capnp-typed-check.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
if [[ $# == 1 ]]; then
  generator=$1
else
  (cd tools/capnpc-swift && mise exec -- zig build)
  generator="$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
fi
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -emit-module -emit-library -module-name Capnp Sources/Capnp/*.swift \
  -emit-module-path "$tmp/Capnp.swiftmodule" -o "$tmp/libCapnp.dylib"
"$generator" --typed --output-dir="$tmp/apps" < tools/type-resolver-spike/fixtures/specializations.request.bin
"$generator" --typed --output-dir="$tmp/structs" < "$script_dir/open_structs.request.bin"
compile() {
  swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -I "$tmp" -L "$tmp" -lCapnp -Xlinker -rpath -Xlinker "$tmp" "$@"
}
compile "$tmp/apps/specializations.swift" "$script_dir/OpenApplicationsMain.swift" -o "$tmp/apps-test"
"$tmp/apps-test"
compile "$tmp/structs/open_structs.swift" "$script_dir/OpenStructsMain.swift" -o "$tmp/structs-test"
"$tmp/structs-test"
"$generator" --typed --output-dir="$tmp/external" < "$script_dir/external.request.bin"
compile -emit-module -emit-library -module-name TypedExternal "$tmp/external/external.swift" \
  -emit-module-path "$tmp/TypedExternal.swiftmodule" -o "$tmp/libTypedExternal.dylib"
"$generator" --typed --output-dir="$tmp/consumer" < "$script_dir/consumer.request.bin"
compile -lTypedExternal "$tmp/consumer/consumer.swift" "$script_dir/CrossModuleMain.swift" -o "$tmp/import-test"
"$tmp/import-test"
for order in ab ba; do
  "$generator" --typed --output-dir="$tmp/collision-$order" < "$script_dir/collision_$order.request.bin"
  compile "$tmp/collision-$order/collision_a.swift" "$tmp/collision-$order/collision_b.swift" \
    "$script_dir/CollisionMain.swift" -o "$tmp/collision-$order-test"
  "$tmp/collision-$order-test"
  rg '^public typealias Clash_Node' "$tmp/collision-$order/" --no-filename | sed 's/ =.*$//' | sort > "$tmp/aliases-$order"
done
if [[ $(wc -l < "$tmp/aliases-ab") -ne 2 ]] || ! cmp -s "$tmp/aliases-ab" "$tmp/aliases-ba"; then
  echo 'TYPED_CLI_FAIL: stable collision application names' >&2
  exit 1
fi
printf 'PASS: stable collision application names\n'
for order in ab ba; do
  "$generator" --typed --output-dir="$tmp/producer-$order" < "$script_dir/producer_$order.request.bin"
  compile -emit-module -emit-library -module-name TypedCollisions "$tmp/producer-$order/producer_a.swift" \
    "$tmp/producer-$order/producer_b.swift" "$script_dir/CollisionProducer.swift" \
    -emit-module-path "$tmp/TypedCollisions.swiftmodule" -o "$tmp/libTypedCollisions.dylib"
  "$generator" --typed --output-dir="$tmp/one-collision" < "$script_dir/consumer_collision.request.bin"
  compile -lTypedCollisions "$tmp/one-collision/consumer_collision.swift" "$script_dir/CollisionImportMain.swift" \
    -o "$tmp/collision-import-$order-test"
  "$tmp/collision-import-$order-test"
done
cat > "$tmp/wrong.swift" <<'SWIFT'
import Capnp
func wrong() throws {
  _ = try Box.Typed<CapnpText>.Value { try $0.setValue([UInt8](arrayLiteral: 1)) }
}
SWIFT
if compile -typecheck "$tmp/apps/specializations.swift" "$tmp/wrong.swift" > "$tmp/wrong.log" 2>&1; then
  echo 'TYPED_CLI_FAIL: wrong binding negative typecheck' >&2
  exit 1
fi
if ! rg -q "cannot convert value of type.*UInt8.*expected argument type.*String" "$tmp/wrong.log"; then
  cat "$tmp/wrong.log" >&2
  echo 'TYPED_CLI_FAIL: wrong binding diagnostic guard' >&2
  exit 1
fi
printf 'PASS: wrong binding negative typecheck\n'
if "$generator" --typed --output-dir="$tmp/rejected" < "$script_dir/duplicate.request.bin" > "$tmp/rejected.stdout" 2> "$tmp/rejected.stderr"; then
  echo 'TYPED_CLI_FAIL: duplicate request atomic rejection' >&2
  exit 1
fi
if [[ -s "$tmp/rejected.stdout" ]] || ! rg -q DuplicateRequestedFile "$tmp/rejected.stderr" || [[ -n $(find "$tmp/rejected" -type f -print) ]]; then
  echo 'TYPED_CLI_FAIL: duplicate request atomic rejection evidence' >&2
  exit 1
fi
printf 'PASS: duplicate request atomic rejection\n'
