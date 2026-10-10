#!/usr/bin/env bash
# Build and execute the optional resolver-to-Swift experiment in a fresh directory.
set -euo pipefail
cd "$(dirname "$0")/.."
spike=tools/type-resolver-spike
scratch=$(mktemp -d "${TMPDIR:-/tmp}/capnp-swift-specializations.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

mise exec -- zig build --build-file "$spike/build.zig" install --summary all
"$spike/zig-out/bin/capnpc-swift-specialize" "$spike/fixtures/specializations.request.bin" :Root > "$scratch/GeneratedSpecializations.swift"
if [[ "${1:-}" == --update ]]; then
    cp "$scratch/GeneratedSpecializations.swift" "$spike/swift/GeneratedSpecializations.swift"
else
    diff -u "$spike/swift/GeneratedSpecializations.swift" "$scratch/GeneratedSpecializations.swift"
fi

# Compile only the pure Swift runtime. No XCFramework or SwiftPM mutation.
xcrun swiftc -swift-version 6 -strict-concurrency=complete -module-name Capnp \
    -emit-library -emit-module -module-cache-path "$scratch/module-cache" \
    Sources/Capnp/*.swift -o "$scratch/libCapnp.dylib" \
    -emit-module-path "$scratch/Capnp.swiftmodule"
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$scratch/module-cache" -I "$scratch" -L "$scratch" \
    -lCapnp -Xlinker -rpath -Xlinker "$scratch" \
    "$scratch/GeneratedSpecializations.swift" "$spike/swift/VerifySpecializations.swift" \
    -o "$scratch/verify"

if command -v capnp >/dev/null 2>&1; then
    capnp --version
    capnp encode "$spike/fixtures/specializations.capnp" Root \
        < "$spike/fixtures/specializations.value.txt" > "$scratch/cpp.bin"
    "$scratch/verify" "$scratch/swift.bin" "$scratch/cpp.bin"
    # Compare canonical decoded values, allowing different valid wire layouts.
    capnp decode --short "$spike/fixtures/specializations.capnp" Root \
        < "$scratch/cpp.bin" > "$scratch/cpp.txt"
    capnp decode --short "$spike/fixtures/specializations.capnp" Root \
        < "$scratch/swift.bin" > "$scratch/swift.txt"
    if ! diff -u "$scratch/cpp.txt" "$scratch/swift.txt"; then
        echo 'FAIL: C++ decoded values differ' >&2
        exit 1
    fi
    echo 'PASS: C++ decodes Swift output to the independent fixture value'
else
    "$scratch/verify" "$scratch/swift.bin"
    echo 'C++ encode/decode checks skipped: capnp is not installed'
fi

# The concrete binding changes both Swift reader and builder types.
printf '%s\n' 'func invalid(_ root: SpecializedRoot.Builder) { root.initTextBox().setValue([UInt8](arrayLiteral: 1)) }' > "$scratch/InvalidBinding.swift"
if xcrun swiftc -swift-version 6 -typecheck -I "$scratch" \
    "$scratch/GeneratedSpecializations.swift" "$scratch/InvalidBinding.swift" \
    > "$scratch/invalid.log" 2>&1; then
    echo 'FAIL: Box(Text) accepted Data' >&2
    exit 1
fi
if ! grep -Eq "cannot convert value of type.*UInt8.*String" "$scratch/invalid.log"; then
    cat "$scratch/invalid.log" >&2
    echo 'FAIL: wrong-binding check failed for an unrelated reason' >&2
    exit 1
fi
echo 'PASS: Box(Text) rejects Data at Swift typecheck'
