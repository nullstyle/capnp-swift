# capnp-swift task runner. Gates are listed in CLAUDE.md; `just` only wraps
# them. Zig always runs through `mise exec` (pinned toolchain).

set shell := ["bash", "-euo", "pipefail", "-c"]

# List recipes.
default:
    @just --list

# Build the static CapnpCore.xcframework (needed before any swift build).
xcframework:
    cd core && mise exec -- zig build xcframework

# Core unit tests (C ABI, connection core) including test-abi.
core-test:
    cd core && mise exec -- zig build test --summary all

# The C ABI through capnp_core.h against the host static library.
test-abi:
    cd core && mise exec -- zig build test-abi --summary all

# Build the capnp-zig TCP peer for the M1 e2e.
zig-peer:
    cd interop/zig-peer && mise exec -- zig build

# The Swift client starts the Zig peer itself (ephemeral port), runs greet,
# the Swift-served callback and the remote-exception checks, then kills the
# peer and checks the connection reports .disconnected. Exit 0 only if every
# TAP line is `ok`.
# M1 e2e (plan §8): start the Zig peer, run the Swift client, print TAP.
mvp-e2e: xcframework zig-peer
    swift build --product mvp-e2e
    "$(swift build --show-bin-path)/mvp-e2e" --server interop/zig-peer/zig-out/bin/zig-peer

# The TSan gate (M1/M2): the whole Swift suite, incl. 64 connections x 10k
# calls over LoopbackTransport, must run with 0 ThreadSanitizer warnings.
tsan: xcframework
    swift test --sanitize=thread

# The ASan gate (M2).
asan: xcframework
    swift test --sanitize=address

# Fuzz the C ABI for `seconds` (M2 gate: 1800). Exit 1 on a violation.
fuzz-abi seconds="60":
    cd core && mise exec -- zig build fuzz-abi -- --seconds {{seconds}}

# Every gate (CLAUDE.md), in order.
gates: core-test xcframework
    swift build
    swift build -c release
    swift test
    scripts/check-symbols.sh
    scripts/check-dsym.sh debug
    scripts/check-dsym.sh release
    just mvp-e2e
    just tsan
    just asan
    just fuzz-abi 60

# ---- M3 codegen (D6 option A) -------------------------------------------

# The pipeline runner: capnp.wasm under WasmKit + the native plugin.
driver-build:
    swift build --product capnpc-driver

# Regenerate this repo's committed bindings through the command plugin.
generate: driver-build
    swift package --allow-writing-to-package-directory capnp-generate --output-dir interop/mvp-swift-gen interop/schemas/mvp.capnp
    swift package --allow-writing-to-package-directory capnp-generate --output-dir generated/conformance --include Tests/capnp_testdata Tests/capnp_testdata/test.capnp
    swift package --allow-writing-to-package-directory capnp-generate --output-dir interop/importtest/lib-gen --include tools/capnpc-swift interop/importtest/lib.capnp
    swift package --allow-writing-to-package-directory capnp-generate --output-dir interop/importtest/app-gen --include tools/capnpc-swift interop/importtest/app.capnp

# CI: the committed code must match the schemas (diff only, exit 1 on drift).
# --check writes nothing, but the plugin's declared permission still needs
# the allow flag.
generate-check: driver-build
    swift package --allow-writing-to-package-directory capnp-generate --check --output-dir interop/mvp-swift-gen interop/schemas/mvp.capnp
    swift package --allow-writing-to-package-directory capnp-generate --check --output-dir generated/conformance --include Tests/capnp_testdata Tests/capnp_testdata/test.capnp
    swift package --allow-writing-to-package-directory capnp-generate --check --output-dir interop/importtest/lib-gen --include tools/capnpc-swift interop/importtest/lib.capnp
    swift package --allow-writing-to-package-directory capnp-generate --check --output-dir interop/importtest/app-gen --include tools/capnpc-swift interop/importtest/app.capnp

# Assemble dist/capnpc-swift.artifactbundle (D6 option A): the universal
# driver (WasmKit inside), the universal native plugin, capnp.wasm and the
# bundled schema include tree.
artifactbundle:
    scripts/make-artifactbundle.sh
