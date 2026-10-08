# H7 — Move the sans-IO shim into capnp-zig `src/native/` (post-0.1.0, refined 2026-10-08)

Status: handoff (not started). D1 said "A until M7, then B" — M7 shipped,
so this is the next structural move. Refined from the plan §3/§10 sketch
after the H11 sprint established the collaboration mechanics.

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
- Also export `type_resolver` for generics while touching the seam
  (plan H7's second clause).

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
