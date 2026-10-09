# Tail-call Returns (`take_from_other_question`) through the native C ABI

Status: open handoff to capnp-zig (2026-10-08). This is the second of the
two filed causes holding `resolve_disembargo` × the C++ reference (the
first is H10); since the shim moved upstream in v0.23.0, the fix is an
upstream `native`-module change.

## The gap

The C++ reflector (capnp-zig's `tests/e2e/cpp`, `resolve_disembargo`
scenario) answers a call with a tail call: a Return whose
`take_from_other_question` redirect points at another question's answer.
When such a Return reaches the native `conn.zig`, the C ABI surfaces it
as an exception — the Swift client sees
`unimplemented("capnp-swift core: unsupported Return variant")` — so
check fails and the schema's last scenario aborts.

Repro (capnp-swift side):

    just e2e-cpp-peers
    scripts/e2e-pair.sh third_party/capnp-zig/tests/e2e/cpp/build/e2e_server \
      <swift e2e-swift-client> resolve_disembargo

Everything else in the C++ matrix passes (4/4 data schemas both
directions, 111 C++-client assertions green through the Swift server).

## What a fix could look like (design space, not a spec)

- Minimal: keep the redirect INSIDE the core — the shim's Peer already
  understands tail calls; the native effect loop just needs to follow
  the redirect and surface the eventual answer (or its failure) as that
  question's RETURN effect, same as any other Return. Host-visible shape
  unchanged.
- Fuller: expose it as a distinct RETURN kind (the host can then decide
  to await the other question itself). That changes the C ABI — v1
  feature bit or ABI v2 territory, alongside ANSWER_FINISHED.

The minimal shape closes the C++ gap without an ABI change.

## Counterpart

H10 (`docs/handoffs/H10-parked-call-promise-repark.md`) holds the OTHER
direction (C++ server / Swift client, and Swift/Swift): a call parked at
question level and drained by a promise-export Return is excepted instead
of re-parked.
