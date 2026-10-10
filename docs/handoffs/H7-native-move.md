# H7 — Move the sans-IO shim into capnp-zig `src/native/` (post-0.1.0)

Status: **EXECUTED 2026-10-08** — capnp-zig v0.23.0 (tag aca9824) ships
the shim as the Experimental `native` module; capnp-swift pins it
(steps 2-3 below are what was done, kept for the next pin bump). D1 is
closed as B.

The second clause is also exported in v0.23.0: the Experimental
`type_resolver` facade. The capnp-swift consumer spike completed on
2026-10-10 (eight ablated cases; all 26 requests produce byte-identical
Swift in a separate v0.21.0/v0.23.0 compatibility build). The shipping
generator retains v0.21.0. [H12](H12-type-resolver-lexical-lookup.md)
records the lookup-only nested RPC defect; full request-node contexts
work. See [the probe](../../tools/type-resolver-spike/README.md) and
[research](type-resolver-research.md) for the remaining adoption decisions.

## Collaboration mechanics (settled this sprint)

- The capnp-zig checkout (`~/prj/zig/capnp-zig`) belongs to the capnp-zig
  session. capnp-swift-side work happens in a worktree:
  `git -C ~/prj/zig/capnp-zig worktree add ~/prj/zig/capnp-zig-zcode <branch>`.
- Branches only; the owner merges and tags. Never push capnp-zig main.
- Base for the move: capnp-zig main (≥ 72d6d7f, i.e. v0.22.0 + the
  ProvisionIndex commit). Note capnp-swift still pins v0.21.0; the H11
  QUIC matrix rides the `e2e-quic-modes` branch until the owner tags.

## What moves

From capnp-swift `core/src/` into capnp-zig `src/native/` (Experimental):

- `conn.zig` (the sans-IO connection: Framing/LengthCodec, bindings,
  bootstrap/call/finish/release/export, effects) and `abi.zig` (the C ABI:
  `capnp_conn_*`, version/features, `capnp_core_quic_alpn`).
- `include/capnp_core.h` (the header IS the ABI; see the gate below).
- `conn_test.zig`, `abi_test.zig`, `fuzz_abi.zig`, `fuzz/seeds/`.
- NOT `apple_root.zig` (capnp-swift's macOS/XCFramework glue stays in
  capnp-swift — upstream builds plain host binaries).

Upstream-side wiring: a `native` module in `src/lib.zig`/`lib_quic.zig`
exports (`pub const native = @import("native/mod.zig")`), the tests on
their `zig build test` graph, and the fuzzer behind its existing fuzz
step. The C-ABI test needs the C allocator + translate-c — mirror
capnp-swift's `core/build.zig` `test-abi` step.

## The header snapshot gate (both repos)

`include/capnp_core.h` becomes capnp-zig's file. capnp-swift keeps a
snapshot at `core/include/capnp_core.h` plus a gate: `diff -q` the
snapshot against a header extracted from the pinned package (or the
tagged tarball) — the pin cannot drift from the header it was built
against. On a pin bump: regenerate the snapshot, update the expected
`capnp_core_version()` string, rerun every core gate (release.md
"Version bookkeeping").

## capnp-swift after the move

- `core/build.zig` builds the XCFramework from the DEPENDENCY's native
  module (the dep already builds with `-Dfd-passing=false`), keeping
  `apple_root.zig` + the xcframework step local. The drift gate on
  header/struct layouts is replaced by the snapshot gate.
- The pin flow gains: bump the capnp-zig tag, `zig build xcframework`,
  refresh the header snapshot + version string, full gates, then the
  release ceremony's `--verify` double build.
- The public `type_resolver` export shipped in v0.23.0 (plan H7's
  second clause). Its consumer spike is complete; adopting it in the
  shipping generator still requires a Swift generic pointer-value design
  and separate generator pin validation.

## Order of work

1. capnp-zig branch `native-shim`: move + tests + fuzz + module exports
   verbatim (no behavior changes); their full suite must stay green
   (245+ steps at time of writing).
2. capnp-swift branch against that tag (owner tags first):
   `core/build.zig` consumes the dep; snapshot gate in; drift gate out;
   all gates; release.md updated.
3. Remove capnp-swift's local `core/src` copies.

## Why now

Two implementations of the same wire no longer exist (H11 proved the
matrix), but two COPIES of the shim do: every pin bump currently
re-verifies a copy that only changes when capnp-swift changes it. After
the move the shim changes once, upstream, with its own tests.
