#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
scratch=$(mktemp -d /tmp/capnp-open-driver.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
if [[ -n ${CAPNP_TYPED_DRIVER:-} ]]; then
    driver=$CAPNP_TYPED_DRIVER
else
    swift build --product capnpc-driver
    driver="$(swift build --product capnpc-driver --show-bin-path)/capnpc-driver"
fi
(cd tools/capnpc-swift && mise exec -- zig build)
mkdir -p "$scratch/bundle"
cp "$driver" "$scratch/bundle/capnpc-driver"
cp tools/capnpc-swift/zig-out/bin/capnpc-swift "$scratch/bundle/capnpc-swift"
cp tools/capnpc-swift/wasm/capnp.wasm "$scratch/bundle/capnp.wasm"
cp -R tools/capnpc-swift/wasm/include "$scratch/bundle/include"
driver="$scratch/bundle/capnpc-driver"
schema="$script_dir/open_structs.capnp"
"$driver" --typed --output-dir "$scratch/direct" "$schema"
if ! rg -q 'CapnpStructSchema' "$scratch/direct/open_structs.swift"; then
    echo 'OPEN_DRIVER_FAIL: typed flag reaches native generator' >&2
    exit 1
fi
if ! "$driver" --typed --check --output-dir "$scratch/direct" "$schema"; then
    echo 'OPEN_DRIVER_FAIL: typed check forwards flags' >&2
    exit 1
fi
echo 'PASS: typed driver generation and check'
CAPNPC_SWIFT_DRIVER="$driver" swift package --allow-writing-to-package-directory capnp-generate \
    --typed --output-dir "$scratch/plugin" "$schema"
if ! cmp "$scratch/direct/open_structs.swift" "$scratch/plugin/open_structs.swift"; then
    echo 'OPEN_DRIVER_FAIL: command plugin forwards typed flag' >&2
    exit 1
fi
if ! CAPNPC_SWIFT_DRIVER="$driver" swift package --allow-writing-to-package-directory capnp-generate \
    --typed --check --output-dir "$scratch/plugin" "$schema"; then
    echo 'OPEN_DRIVER_FAIL: typed command plugin check forwards flags' >&2
    exit 1
fi
echo 'PASS: typed command plugin generation and check'
printf '\n// deliberate check-mode drift\n' >> "$scratch/direct/open_structs.swift"
if "$driver" --typed --check --output-dir "$scratch/direct" "$schema" > "$scratch/drift.log" 2>&1; then
    echo 'OPEN_DRIVER_FAIL: typed check rejects drift' >&2
    exit 1
fi
if ! rg -q 'differs: open_structs.swift' "$scratch/drift.log"; then
    cat "$scratch/drift.log" >&2
    echo 'OPEN_DRIVER_FAIL: typed drift diagnostic' >&2
    exit 1
fi
echo 'PASS: typed driver rejects generated-source drift'
if "$driver" --typed --output-dir "$scratch/rejected" "$script_dir/open_rpc_conflict.capnp" > "$scratch/rejected.log" 2>&1; then
    echo 'OPEN_DRIVER_FAIL: conflicting inheritance is rejected through the driver' >&2
    exit 1
fi
if ! rg -q ConflictingInheritedApplication "$scratch/rejected.log"; then
    cat "$scratch/rejected.log" >&2
    echo 'OPEN_DRIVER_FAIL: generator diagnostics reach the caller' >&2
    exit 1
fi
if [[ -d "$scratch/rejected" && -n $(find "$scratch/rejected" -type f -print) ]]; then
    echo 'OPEN_DRIVER_FAIL: rejected driver input writes no source' >&2
    exit 1
fi
echo 'PASS: typed driver preserves atomic generator rejection and diagnostics'
