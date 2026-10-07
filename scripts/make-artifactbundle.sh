#!/usr/bin/env bash
# Assemble dist/capnpc-swift.artifactbundle (plan §6, D6 option A).
#   - capnpc-driver: universal (arm64 + x86_64) release Swift binary with
#     WasmKit statically linked (it runs capnp.wasm itself).
#   - capnpc-swift: the universal native Zig plugin (ReleaseSafe).
#   - capnp.wasm + include/: the vendored schema compiler (sha256-pinned).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=dist/capnpc-swift.artifactbundle
TRIPLE_DIR="$OUT/capnpc-swift-macos-arm64_x86_64"
rm -rf "$OUT"
mkdir -p "$TRIPLE_DIR"

echo "== driver (swift, release, universal)"
swift build -c release --product capnpc-driver
BIN_DIR="$(swift build -c release --product capnpc-driver --show-bin-path)"
cp "$BIN_DIR/capnpc-driver" /tmp/capnpc-driver-arm64
swift build -c release --product capnpc-driver --arch x86_64
BIN_DIR_X86="$(swift build -c release --product capnpc-driver --arch x86_64 --show-bin-path)"
lipo -create /tmp/capnpc-driver-arm64 "$BIN_DIR_X86/capnpc-driver" -output "$TRIPLE_DIR/capnpc-driver"
rm /tmp/capnpc-driver-arm64

echo "== plugin (zig, ReleaseSafe, universal)"
cd tools/capnpc-swift
mise exec -- zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
cp zig-out/bin/capnpc-swift ../../"$TRIPLE_DIR/capnpc-swift.arm64"
mise exec -- zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe
cp zig-out/bin/capnpc-swift ../../"$TRIPLE_DIR/capnpc-swift.x86_64"
# Leave the dev-tree plugin native again: generate-check runs it directly,
# and an x86_64 leftover dies with EBADEXEC on hosts without Rosetta.
mise exec -- zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
cd ../..
lipo -create "$TRIPLE_DIR/capnpc-swift.arm64" "$TRIPLE_DIR/capnpc-swift.x86_64" -output "$TRIPLE_DIR/capnpc-swift"
rm "$TRIPLE_DIR/capnpc-swift.arm64" "$TRIPLE_DIR/capnpc-swift.x86_64"

echo "== compiler (wasm) + schema include tree"
cp tools/capnpc-swift/wasm/capnp.wasm "$TRIPLE_DIR/"
cp -R tools/capnpc-swift/wasm/include "$TRIPLE_DIR/include"

echo "== the wasm pin"
EXPECTED=5429b7277b18b6e3f65430068ac41ac327ef8dd359603955f16ec576e0c3a14a
ACTUAL=$(shasum -a 256 "$TRIPLE_DIR/capnp.wasm" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] || { echo "capnp.wasm sha256 mismatch: $ACTUAL"; exit 1; }

cat > "$OUT/info.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "artifacts": {
    "capnpc-driver": {
      "type": "executable",
      "variants": [
        { "path": "capnpc-swift-macos-arm64_x86_64/capnpc-driver", "supportedTriples": ["macos-arm64", "macos-x86_64"] }
      ]
    },
    "capnpc-swift": {
      "type": "executable",
      "variants": [
        { "path": "capnpc-swift-macos-arm64_x86_64/capnpc-swift", "supportedTriples": ["macos-arm64", "macos-x86_64"] }
      ]
    }
  }
}
JSON

echo "== smoke: the bundle regenerates mvp.capnp"
BIN="$TRIPLE_DIR/capnpc-driver"
rm -rf /tmp/bundle-smoke
"$BIN" --output-dir /tmp/bundle-smoke interop/schemas/mvp.capnp
diff /tmp/bundle-smoke/mvp.swift interop/mvp-swift-gen/mvp.swift
rm -rf /tmp/bundle-smoke

echo "OK: $OUT"
