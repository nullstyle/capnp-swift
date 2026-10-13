#!/usr/bin/env bash
set -euo pipefail
sample=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$sample/../.." && pwd)
if [[ $# -gt 1 || ( $# == 1 && $1 != --check ) ]]; then
    echo 'usage: generate.sh [--check]' >&2; exit 2
fi
if [[ -n ${CAPNPC_SWIFT_DRIVER:-} ]]; then
    driver="$CAPNPC_SWIFT_DRIVER"
    extra=(--typed)
else
    # Build only the codegen tools. SwiftPM retains the released core URL.
    swift build --package-path "$repo" --product capnpc-driver
    driver="$(swift build --package-path "$repo" --product capnpc-driver --show-bin-path)/capnpc-driver"
    (cd "$repo/tools/capnpc-swift" && mise exec -- zig build)
    extra=(--typed --plugin "$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
           --wasm "$repo/tools/capnpc-swift/wasm/capnp.wasm"
           --include "$repo/tools/capnpc-swift/wasm/include"
           --include "$repo/tools/capnpc-swift")
fi
unset CAPNPC_SWIFT_PLUGIN CAPNP_WASM
for pair in 'models WorkbenchModels' 'workbench WorkbenchRPC'; do
    read -r schema module <<< "$pair"
    "$driver" "${extra[@]}" "$@" --src-prefix "$sample/Schemas" \
        --output-dir "$sample/Sources/$module" "$sample/Schemas/$schema.capnp"
done
