# Release ceremony (0.1.0 and later)

Every step runs from a clean working tree on the release commit. Steps 5
and 6 need the owner; nothing is tagged or uploaded before the owner
says so.

## Current release (2026-10-20)

Release [0.1.4](https://github.com/nullstyle/capnp-swift/releases/tag/0.1.4)
was published on 2026-10-20 at `90f24f29300d88a770a5cea5eace69eab1d15153`,
with the capnp-zig v0.28.0 core and the fix for a Release-build crash of
0.1.3; its codegen asset is the 0.1.2 file byte for byte. The 0.1.3 release
page carries a warning that points to 0.1.4. Release
[0.1.3](https://github.com/nullstyle/capnp-swift/releases/tag/0.1.3)
was published on 2026-10-20 at `d589ff41c29a1aa12fc1fb649a1be5606ed35c11`.
Its two assets are the 0.1.2 files byte for byte (the core and the
generator did not change); its release commit moved the CapnpCore URL to
the 0.1.3 download. Release
[0.1.2](https://github.com/nullstyle/capnp-swift/releases/tag/0.1.2) was
published on 2026-10-18 at `69e392e342fd4fa9ed741c68327fc31c5148e632`,
with the capnp-zig v0.27.0 core, and
[0.1.1](https://github.com/nullstyle/capnp-swift/releases/tag/0.1.1) on
2026-10-10 at `808a90440c4560e7f3a705170b66b3ac969388a6`. All tags and
their assets are immutable. See the [0.1.4 sheet](release-readiness-2026-10-20.md),
the [0.1.3 sheet](release-readiness-2026-10-19.md)
and the [0.1.2 sheet](release-readiness-2026-10-18.md) for assets,
checksums, evidence and the post-publish smokes. The
[2026-10-13 sheet](release-readiness-2026-10-13.md) and the
[2026-10-12 sheet](release-readiness-2026-10-12.md) keep the earlier
snapshots. Confirm the signing policy before any tag or asset upload.

## 0. What ships

- `CapnpCore.xcframework` — static, ReleaseSafe, unstripped (an app's
  dSYM is built from the DWARF inside the `.a`). Slices:
  `macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`
  (macOS 15 / iOS 18 floors; QUIC needs 26 and is availability-gated).
- `dist/capnpc-swift.artifactbundle` — universal driver + universal
  native plugin + the sha256-pinned `capnp.wasm` + the schema include
  tree.
- The SwiftPM package, with `Package.swift` switched to
  `binaryTarget(url:checksum:)` for `CapnpCore`.

## 1. Gates (all must pass on the release commit)

`just gates` (core tests, builds, swift test, symbols, dSYM, mvp-e2e,
TSan, ASan, a 60 s fuzz), plus the full set the plan §8 milestone rows
require:

- `scripts/check-symbols.sh --strict` — no KNOWN SPI exception.
- `just e2e-matrix` — 42/42 TAP against the Zig peers.
- `just quic-e2e-swift-zig`, `just quic-e2e-zig-swift`,
  `just quic-idle-gate` — the M6 QUIC lanes.
- `just artifactbundle`, `just generate-check`.
- `xcodebuild test -scheme capnp-swift-Package -destination
  'platform=iOS Simulator,id=<UDID>'` and the device build with
  `CODE_SIGNING_ALLOWED=NO`.
- The nightly fuzz: `just fuzz-abi 1800` — no crash, no leak.

## 2. Build the release artifacts

```
scripts/make-release-xcframework.sh --verify   # dist/CapnpCore.xcframework
just artifactbundle                             # dist/capnpc-swift.artifactbundle
```

The release XCFramework is built from a neutral staged path
(`/tmp/capnp-swift-release`, toolchain and dependency cache included)
because Zig 0.17.0 has no debug-prefix mapping: building in the
maintainer's tree would bake the home directory into the shipped DWARF.
The script fails if any slice mentions `/Users/`.

`--verify` builds twice and requires identical public surfaces
(exported symbols + strings with the anonymous-module cache hashes
normalized away). Zig 0.17 is NOT bit-reproducible — ~121 bytes of
`b/<hash>/builtin.zig` DWARF filenames vary between identical builds —
so the original "identical .a checksums" check is intentionally replaced
by this normalized one. Record the per-slice sha256 lines the script
prints in the release notes.

## 3. Package.swift: path → url + checksum

Zip the framework and compute its checksum. Prepare the target's final
release-asset URL; uploading waits for owner approval in step 5.

```
zip -r CapnpCore.xcframework.zip CapnpCore.xcframework
swift package compute-checksum CapnpCore.xcframework.zip
```

Flip the target (the line is marked in `Package.swift`):

```diff
-        .binaryTarget(name: "CapnpCore", path: "CapnpCore.xcframework"),
+        .binaryTarget(
+            name: "CapnpCore",
+            url: "https://.../CapnpCore.xcframework.zip",
+            checksum: "<the computed checksum>"
+        ),
```

Commit that diff; it is part of the release commit. The tag must point to
that commit: a tag with `path:` refers to a gitignored framework that a
fresh consumer cannot resolve.

## 4. Sign

```
codesign --timestamp -s "<identity>" dist/CapnpCore.xcframework
```

The identity stays with the owner.

## 5. Owner approval

The owner reviews the gate log and approves (a) tagging the release
commit and (b) uploading the assets. No automation does this.

## 6. Post-publish smoke test

A fresh consumer package (a directory outside this repo):

```swift
// Package.swift
dependencies: [ .package(url: "https://github.com/nullstyle/capnp-swift", from: "0.1.0") ]
```

must resolve the URL, build for macOS and iOS, and complete a TCP
round trip against a `zig-peer` built from the pinned tag. Only then is
the release announced.

## Version bookkeeping

When the core version changes, update together in one commit:

- `core/build.zig.zon` `.version` (feeds `core/src/apple_root.zig`
  through `build_info`; the native ABI reads that root's version string),
- the expected string in `Tests/CapnpRPCTests/CapnpCoreInfoTests.swift`
  (`capnp_core_version()` reports `core <v> / capnp-zig <pin> / <hash>`),
- `CHANGELOG.md`.

Each release pins exactly one capnp-zig tag; the pin and its hash are
visible in that same string.

The release commit's URL/checksum flip also moves the Stable API gate's
baseline (`scripts/check-api-breakage.sh` compares against the release
that the committed `Package.swift` downloads). Clear
`scripts/api-breakage-allowlist.txt` in that commit.

For 0.1.1, the package tag advances while the core version stays 0.1.0;
the staged binary reports the new capnp-zig v0.23.0 pin. The former local
`core/src/abi.zig` moved upstream in H7 and is not a release-edit target.
