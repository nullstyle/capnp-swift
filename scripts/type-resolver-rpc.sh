#!/usr/bin/env bash
# Concrete generic RPC prototype, compiled separately from production generation.
set -euo pipefail
cd "$(dirname "$0")/.."
spike=tools/type-resolver-spike
scratch=$(mktemp -d "${TMPDIR:-/tmp}/capnp-swift-rpc-specializations.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
core=CapnpCore.xcframework/macos-arm64_x86_64
if [[ ! -f "$core/libcapnp_core.a" ]]; then
    echo 'Missing macOS core archive; run just xcframework first' >&2
    exit 1
fi
mise exec -- zig build --build-file "$spike/build.zig" install --summary all
"$spike/zig-out/bin/capnpc-swift-specialize" "$spike/fixtures/rpc_specializations.request.bin" :Root > "$scratch/GeneratedRPCSpecializations.swift"
if [[ "${1:-}" == --update ]]; then
    cp "$scratch/GeneratedRPCSpecializations.swift" "$spike/swift/GeneratedRPCSpecializations.swift"
else
    diff -u "$spike/swift/GeneratedRPCSpecializations.swift" "$scratch/GeneratedRPCSpecializations.swift"
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete -module-name Capnp \
    -emit-library -emit-module -module-cache-path "$scratch/module-cache" \
    Sources/Capnp/*.swift -o "$scratch/libCapnp.dylib" \
    -emit-module-path "$scratch/Capnp.swiftmodule"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -module-name CapnpRPC \
    -I "$scratch" -I "$core/Headers" -L "$scratch" -lCapnp \
    -emit-library -emit-module -module-cache-path "$scratch/module-cache" \
    Sources/CapnpRPC/*.swift "$core/libcapnp_core.a" -o "$scratch/libCapnpRPC.dylib" \
    -emit-module-path "$scratch/CapnpRPC.swiftmodule" \
    -Xlinker -rpath -Xlinker "$scratch"
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$scratch/module-cache" -I "$scratch" -I "$core/Headers" -L "$scratch" \
    -lCapnp -lCapnpRPC -Xlinker -rpath -Xlinker "$scratch" \
    "$scratch/GeneratedRPCSpecializations.swift" "$spike/swift/VerifyRPCSpecializations.swift" \
    -o "$scratch/verify"
"$scratch/verify"

printf '%s\n' 'func invalid(_ params: SpecializedRoot.TextDiamondCapability.Super0.Super0.EchoParams.Builder) { params.setValue([UInt8](arrayLiteral: 1)) }' > "$scratch/InvalidBinding.swift"
if xcrun swiftc -swift-version 6 -typecheck -I "$scratch" -I "$core/Headers" \
    "$scratch/GeneratedRPCSpecializations.swift" "$scratch/InvalidBinding.swift" \
    > "$scratch/invalid.log" 2>&1; then
    echo 'FAIL: inherited Base(Text) accepted Data' >&2
    exit 1
fi
if ! grep -Eq 'cannot convert value of type.*UInt8.*String' "$scratch/invalid.log"; then
    cat "$scratch/invalid.log" >&2
    echo 'FAIL: inherited binding check failed for an unrelated reason' >&2
    exit 1
fi
echo 'PASS: inherited Base(Text) rejects Data at Swift typecheck'
cat > "$scratch/MissingAncestor.swift" <<'SWIFT'
import CapnpRPC
struct MissingAncestor: SpecializedRoot.TextDiamondCapability.Server {
    typealias D = SpecializedRoot.TextDiamondCapability
    func local(params: D.LocalParams.Reader, on connection: RPCConnection) async throws -> D.LocalResults.Value { .init() }
    func left(params: D.Super0.LeftParams.Reader, on connection: RPCConnection) async throws -> D.Super0.LeftResults.Value { .init() }
    func right(params: D.Super1.RightParams.Reader, on connection: RPCConnection) async throws -> D.Super1.RightResults.Value { .init() }
}
SWIFT
if xcrun swiftc -swift-version 6 -typecheck -I "$scratch" -I "$core/Headers" \
    "$scratch/GeneratedRPCSpecializations.swift" "$scratch/MissingAncestor.swift" \
    > "$scratch/ancestor.log" 2>&1; then
    echo 'FAIL: diamond Server accepted a missing inherited method' >&2
    exit 1
fi
if ! grep -Eq "protocol requires function 'echo\(params:on:\)'" "$scratch/ancestor.log"; then
    cat "$scratch/ancestor.log" >&2
    echo 'FAIL: missing-ancestor check failed for an unrelated reason' >&2
    exit 1
fi
echo 'PASS: diamond Server requires its inherited method'
