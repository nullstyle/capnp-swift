#!/usr/bin/env bash
# Explicit method-generic client applications and an erased server, compiled separately from production generation.
set -euo pipefail
cd "$(dirname "$0")/.."
spike=tools/type-resolver-spike
scratch=$(mktemp -d "${TMPDIR:-/tmp}/capnp-swift-method-specializations.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
core=CapnpCore.xcframework/macos-arm64_x86_64
if [[ ! -f "$core/libcapnp_core.a" ]]; then
    echo 'Missing macOS core archive; run just xcframework first' >&2
    exit 1
fi
mise exec -- zig build --build-file "$spike/build.zig" install --summary all
"$spike/zig-out/bin/capnpc-swift-specialize" "$spike/fixtures/method_generics.request.bin" :Root --methods "$spike/fixtures/method_generics.profiles.json" > "$scratch/GeneratedMethodSpecializations.swift"
if [[ "${1:-}" == --update ]]; then
    cp "$scratch/GeneratedMethodSpecializations.swift" "$spike/swift/GeneratedMethodSpecializations.swift"
else
    diff -u "$spike/swift/GeneratedMethodSpecializations.swift" "$scratch/GeneratedMethodSpecializations.swift"
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete -module-name Capnp \
    -emit-library -emit-module -module-cache-path "$scratch/module-cache" \
    Sources/Capnp/*.swift "$spike/swift/ProbePointer.swift" -o "$scratch/libCapnp.dylib" \
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
    "$scratch/GeneratedMethodSpecializations.swift" "$spike/swift/VerifyMethodSpecializations.swift" \
    -o "$scratch/verify"
"$scratch/verify"

# A call-site Text argument changes the generated builder's field type.
printf '%s\n' 'func invalid(_ params: SpecializedRoot.ChildCapability.Super0.EchoAsTextParams.Builder) { params.setValue([UInt8](arrayLiteral: 1)) }' > "$scratch/InvalidMethodBinding.swift"
if xcrun swiftc -swift-version 6 -typecheck -I "$scratch" -I "$core/Headers" \
    "$scratch/GeneratedMethodSpecializations.swift" "$scratch/InvalidMethodBinding.swift" \
    > "$scratch/invalid.log" 2>&1; then
    echo 'FAIL: method Text argument accepted Data' >&2
    exit 1
fi
if ! grep -Eq 'cannot convert value of type.*UInt8.*String' "$scratch/invalid.log"; then
    cat "$scratch/invalid.log" >&2
    echo 'FAIL: method binding rejected for an unrelated reason' >&2
    exit 1
fi
echo 'PASS: method Text argument rejects Data at Swift typecheck'

# Invalid profiles must fail atomically, with no partial generated source.
printf '%s\n' '[{"interface":":Parent","method":"echo","cases":[{"name":"Text","arguments":[]}]}]' > "$scratch/InvalidProfiles.json"
if "$spike/zig-out/bin/capnpc-swift-specialize" "$spike/fixtures/method_generics.request.bin" :Root \
    --methods "$scratch/InvalidProfiles.json" > "$scratch/rejected.swift" 2> "$scratch/rejected.log"; then
    echo 'FAIL: invalid method profile accepted' >&2
    exit 1
fi
if [[ -s "$scratch/rejected.swift" ]] || ! grep -q 'error: InvalidMethodApplication' "$scratch/rejected.log"; then
    cat "$scratch/rejected.log" >&2
    echo 'FAIL: method profile rejection was not atomic or had the wrong cause' >&2
    exit 1
fi
echo 'PASS: invalid method profile rejects before writing source'
