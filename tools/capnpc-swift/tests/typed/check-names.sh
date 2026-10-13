#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
scratch=$(mktemp -d /tmp/capnp-typed-names.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
if [[ $# == 1 ]]; then
    generator=$1
else
    (cd tools/capnpc-swift && mise exec -- zig build --prefix "$scratch/generator" --cache-dir "$scratch/zig-cache")
    generator="$scratch/generator/bin/capnpc-swift"
fi
core=CapnpCore.xcframework/macos-arm64_x86_64
if [[ ! -f "$core/libcapnp_core.a" ]]; then
    echo 'TYPED_NAMING_FAIL: missing macOS core archive' >&2
    exit 1
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-name Capnp -emit-library -emit-module -module-cache-path "$scratch/module-cache" \
    Sources/Capnp/*.swift -o "$scratch/libCapnp.dylib" -emit-module-path "$scratch/Capnp.swiftmodule"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -Xcc -Wno-comment -module-name CapnpRPC -I "$scratch" -I "$core/Headers" -L "$scratch" -lCapnp \
    -emit-library -emit-module -module-cache-path "$scratch/module-cache" \
    Sources/CapnpRPC/*.swift "$core/libcapnp_core.a" -o "$scratch/libCapnpRPC.dylib" \
    -emit-module-path "$scratch/CapnpRPC.swiftmodule" -Xlinker -rpath -Xlinker "$scratch"
compile() {
    xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
        -Xcc -Wno-comment -module-cache-path "$scratch/module-cache" -I "$scratch" -I "$core/Headers" \
        -L "$scratch" -lCapnp -lCapnpRPC -Xlinker -rpath -Xlinker "$scratch" "$@"
}
for mode in erased typed; do
    if [[ "$mode" == typed ]]; then
        "$generator" --typed --output-dir="$scratch/$mode" < "$script_dir/nested_reserved.request.bin"
    else
        "$generator" --output-dir="$scratch/$mode" < "$script_dir/nested_reserved.request.bin"
    fi
    if ! compile -emit-library -emit-module -module-name "NestedReserved${mode}" \
        "$scratch/$mode/nested_reserved.swift" -emit-module-path "$scratch/NestedReserved${mode}.swiftmodule" \
        -o "$scratch/libNestedReserved${mode}.dylib"; then
        echo "TYPED_NAMING_FAIL: $mode reserved nested declarations compile as a complete library" >&2
        exit 1
    fi
    echo "PASS: $mode reserved nested declarations compile as a complete library"
done
if ! compile "$scratch/typed/nested_reserved.swift" "$script_dir/NestedReservedMain.swift" -o "$scratch/verify"; then
    echo 'TYPED_NAMING_FAIL: nested declaration reference harness compiles' >&2
    exit 1
fi
"$scratch/verify"
