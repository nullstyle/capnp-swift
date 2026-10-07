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

# ---- M6 QUIC lanes (Experimental; plan §8 M6) --------------------------------

# Swift client -> capnp-zig QUIC server, incl. the three wire gates
# (second-stream reset, clean close -> peer_close, server kill).
quic-e2e-swift-zig: xcframework zig-peer
    swift build --product mvp-e2e
    "$(swift build --show-bin-path)/mvp-e2e" --server interop/zig-peer/zig-out/bin/zig-peer --transport quic

# capnp-zig QUIC client -> Swift QUIC server (scripts/quic-pair-zig-swift.sh
# prints the Zig side's TAP; exit 0 only if every line is ok).
quic-e2e-zig-swift: xcframework zig-peer
    swift build --product mvp-e2e
    scripts/quic-pair-zig-swift.sh

# The 90 s idle gate: slow on purpose (~2 min); part of the M6 sign-off run.
quic-idle-gate: xcframework zig-peer
    swift build --product mvp-e2e
    "$(swift build --show-bin-path)/mvp-e2e" --server interop/zig-peer/zig-out/bin/zig-peer --transport quic --idle-seconds 90

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

# ---- M4 interop matrix ----------------------------------------------------

# Build the Zig e2e peers from the pinned tag export (third_party/capnp-zig).
e2e-zig-peers:
    cd third_party/capnp-zig && mise exec -- zig build e2e-zig-server-install e2e-zig-client-install

# Build the C++ reference peers (needs homebrew capnp; cmake).
e2e-cpp-peers:
    cd third_party/capnp-zig/tests/e2e/cpp && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j

e2e-swift-peers: xcframework
    swift build --product e2e-swift-server --product e2e-swift-client

# The matrix: every schema, both Zig pairings (the M4 gate) and the extras.
e2e-matrix: e2e-zig-peers e2e-swift-peers
    #!/usr/bin/env bash
    set -euo pipefail
    SWIFT_SERVER="$(swift build --product e2e-swift-server --show-bin-path)/e2e-swift-server"
    SWIFT_CLIENT="$(swift build --product e2e-swift-client --show-bin-path)/e2e-swift-client"
    scripts/e2e-pair.sh third_party/capnp-zig/zig-out/bin/e2e-zig-server "$SWIFT_CLIENT"
    scripts/e2e-pair.sh "$SWIFT_SERVER" third_party/capnp-zig/zig-out/bin/e2e-zig-client

# The serialization bench: Swift within 2x of the Zig reference.
bench-ping-pong:
    swift build -c release --product bench-ping-pong
    echo "== zig (reference)"
    cd third_party/capnp-zig && mise exec -- zig build bench-ping-pong -- --iters 10000 --payload 1024 2>/dev/null | grep 'ns/op'
    cd ../..
    echo "== swift"
    "$(swift build -c release --product bench-ping-pong --show-bin-path)/bench-ping-pong" --iters 10000 --payload 1024 | grep 'ns/op'
