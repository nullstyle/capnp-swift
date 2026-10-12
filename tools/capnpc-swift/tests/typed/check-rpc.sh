#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
rpc_scratch=$(mktemp -d /tmp/capnp-open-rpc-check.XXXXXX)
trap 'rm -rf "$rpc_scratch"' EXIT
core=CapnpCore.xcframework/macos-arm64_x86_64
if [[ ! -f "$core/libcapnp_core.a" ]]; then
    echo 'OPEN_RPC_FAIL: missing macOS core archive' >&2
    exit 1
fi
mode=${1:-}
(cd tools/capnpc-swift && mise exec -- zig build)
generator="$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
"$generator" --typed --output-dir="$rpc_scratch/methods" < tools/type-resolver-spike/fixtures/method_generics.request.bin
"$generator" --typed --output-dir="$rpc_scratch/inheritance" < "$script_dir/open_rpc_inheritance.request.bin"
"$generator" --typed --output-dir="$rpc_scratch/external" < "$script_dir/external.request.bin"
"$generator" --typed --output-dir="$rpc_scratch/persistent" < Tests/generated_shape/requests/persistent.request.bin
mkdir -p "$script_dir/generated"
for pair in methods/method_generics inheritance/open_rpc_inheritance; do
    generated="$rpc_scratch/$pair.swift"
    golden="$script_dir/generated/${pair##*/}.swift"
    if [[ "$mode" == --update ]]; then cp "$generated" "$golden"; else diff -u "$golden" "$generated"; fi
done
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-name Capnp -emit-library -emit-module -module-cache-path "$rpc_scratch/module-cache" \
    Sources/Capnp/*.swift -o "$rpc_scratch/libCapnp.dylib" -emit-module-path "$rpc_scratch/Capnp.swiftmodule"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -Xcc -Wno-comment -module-name CapnpRPC -I "$rpc_scratch" -I "$core/Headers" -L "$rpc_scratch" -lCapnp \
    -emit-library -emit-module -module-cache-path "$rpc_scratch/module-cache" \
    Sources/CapnpRPC/*.swift "$core/libcapnp_core.a" -o "$rpc_scratch/libCapnpRPC.dylib" \
    -emit-module-path "$rpc_scratch/CapnpRPC.swiftmodule" -Xlinker -rpath -Xlinker "$rpc_scratch"
compile() {
    xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
        -Xcc -Wno-comment -module-cache-path "$rpc_scratch/module-cache" -I "$rpc_scratch" -I "$core/Headers" \
        -L "$rpc_scratch" -lCapnp -lCapnpRPC -Xlinker -rpath -Xlinker "$rpc_scratch" "$@"
}
compile -emit-library -emit-module -module-name TypedExternal "$rpc_scratch/external/external.swift" \
    -o "$rpc_scratch/libTypedExternal.dylib" -emit-module-path "$rpc_scratch/TypedExternal.swiftmodule"
if ! compile -emit-library -module-name TypedPersistent "$rpc_scratch/persistent/persistent.swift" \
    -o "$rpc_scratch/libTypedPersistent.dylib"; then
    echo 'OPEN_RPC_FAIL: named method payload reuses nested declaration' >&2
    exit 1
fi
echo 'PASS: named method payload reuses nested declaration'
if ! compile -emit-library -module-name TypedInheritance "$rpc_scratch/inheritance/open_rpc_inheritance.swift" \
    -o "$rpc_scratch/libTypedInheritance.dylib"; then
    echo 'OPEN_RPC_FAIL: generated clients reserve members and omit unbound conveniences' >&2
    exit 1
fi
echo 'PASS: generated clients reserve members and omit unbound conveniences'
compile -lTypedExternal "$rpc_scratch/methods/method_generics.swift" \
    "$rpc_scratch/inheritance/open_rpc_inheritance.swift" "$script_dir/VerifyOpenRPC.swift" -o "$rpc_scratch/verify"
"$rpc_scratch/verify"

cat > "$rpc_scratch/wrong.swift" <<'SWIFT'
import Capnp
import CapnpRPC
func invalid(_ client: Child.Typed.Client) async throws {
    _ = try await client.parent.echo(as: CapnpText.self) { try $0.setValue([UInt8](arrayLiteral: 1)) }
}
SWIFT
if compile -typecheck "$rpc_scratch/methods/method_generics.swift" "$rpc_scratch/wrong.swift" > "$rpc_scratch/wrong.log" 2>&1; then
    echo 'OPEN_RPC_FAIL: wrong method binding typecheck' >&2
    exit 1
fi
if ! rg -q 'cannot convert value of type.*UInt8.*expected argument type.*String' "$rpc_scratch/wrong.log"; then
    cat "$rpc_scratch/wrong.log" >&2
    echo 'OPEN_RPC_FAIL: wrong method binding diagnostic guard' >&2
    exit 1
fi
echo 'PASS: open method Text binding rejects Data at Swift typecheck'
cat > "$rpc_scratch/missing.swift" <<'SWIFT'
import Capnp
import CapnpRPC
struct Missing: Child.TypedServer {}
SWIFT
if compile -typecheck "$rpc_scratch/methods/method_generics.swift" "$rpc_scratch/missing.swift" > "$rpc_scratch/missing.log" 2>&1; then
    echo 'OPEN_RPC_FAIL: missing ancestor witness typecheck' >&2
    exit 1
fi
if ! rg -q "does not conform to protocol.*TypedServer" "$rpc_scratch/missing.log" || ! rg -q 'echo' "$rpc_scratch/missing.log"; then
    cat "$rpc_scratch/missing.log" >&2
    echo 'OPEN_RPC_FAIL: missing ancestor witness diagnostic guard' >&2
    exit 1
fi
echo 'PASS: typed inheritance requires ancestor server witnesses'
if "$generator" --typed --output-dir="$rpc_scratch/rejected" < "$script_dir/open_rpc_conflict.request.bin" > "$rpc_scratch/rejected.stdout" 2> "$rpc_scratch/rejected.stderr"; then
    echo 'OPEN_RPC_FAIL: conflicting inherited applications atomic rejection' >&2
    exit 1
fi
if [[ -s "$rpc_scratch/rejected.stdout" ]] || ! rg -q ConflictingInheritedApplication "$rpc_scratch/rejected.stderr" || [[ -n $(find "$rpc_scratch/rejected" -type f -print) ]]; then
    echo 'OPEN_RPC_FAIL: conflicting inherited applications rejection evidence' >&2
    exit 1
fi
echo 'PASS: conflicting inherited applications fail before source is written'
