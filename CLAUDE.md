# CLAUDE.md

capnp-swift adds Cap'n Proto RPC to Swift apps. The RPC core is capnp-zig
(a Zig dependency pinned by hash). Swift owns all networking through Apple's
Network.framework. The two talk through a sans-IO C ABI (`core/include/capnp_core.h`):
Swift pushes bytes in and pulls frames and events out; the core never touches a socket.

The plan, milestones and owner decisions: `docs/plan-2026-10-06.md`. Read it first.

## Layout

- `core/` — Zig: the C ABI (`capnp_conn` = capnp-zig `Peer` + `Framer` + effect queue), `apple_root.zig`, the XCFramework build.
- `Sources/Capnp` — pure-Swift message reader/builder (no Zig).
- `Sources/CapnpRPC` — Swift RPC runtime over the C ABI (connection actor, CapRef, RemotePromise).
- `Sources/CapnpNW` — Network.framework transports.
- `tools/capnpc-swift/` — the schema code generator (Zig, on capnp-zig's Stable `request`/`schema`).
- `interop/` — Zig peers and e2e binaries for cross-implementation tests.
- `docs/handoffs/` — requests for capnp-zig and the Zig fork, written as files. capnp-zig handoffs are `H<n>-<slug>.md` (`<n>` = the plan §3 row). Zig-fork handoffs are `handoff-zig-fork-<slug>.md`, the same name capnp-zig uses in its `docs/upstream/`, where the owner copies them (a Zig-fork handoff with a plan §3 row, like H2, keeps this name).

## Toolchain

- Zig and Wasmtime come from `mise.toml`. Always run `mise exec -- zig ...`.
- Xcode 27 / Swift 6.4 from `xcrun`.
- capnp-zig is a hash-pinned dependency in `core/build.zig.zon`. Never edit files under the Zig package cache.

## Gates

- `cd core && mise exec -- zig build test --summary all` (C ABI + connection core tests).
- `cd core && mise exec -- zig build xcframework`, then `swift build`, `swift build -c release`, `swift test`.
- `scripts/check-symbols.sh` (the 0.1 release gate is `--strict`), `scripts/check-dsym.sh [debug|release]`.
- `scripts/ablate.py <file> <old> <new>` breaks one line, runs the core tests, restores the file, and exits 0 only if the tests failed.
- Never run `zig fetch <url>` against `.zig-global-cache` (Zig 0.17.0 defect, `docs/handoffs/handoff-zig-fork-fetch-cache-strip.md`); `zig build` fetches by itself.

## Rules

- Tasks are tracked in this repo (`docs/plan-*.md`, `CHANGELOG.md`, `docs/handoffs/`). Never use GitHub Issues.
- This repo has no remote yet. The owner creates it and approves every push, tag and release-asset upload.
- Never push to capnp-zig, quic-zig or any other repo. Changes they need go out as handoff files in `docs/handoffs/`.
- Zig std defects go to a Zig-fork handoff (`docs/handoffs/handoff-zig-fork-*.md`). Never file bugs with the Zig project.
- Every new gate test must be broken once on purpose (ablation) to prove it can fail.
- The core never calls into Swift except the panic hook. Zig handlers only queue effects.
- Do not bundle compiler-rt, do not ship a dynamic product, do not ship JSON demo exports (plan §10).
