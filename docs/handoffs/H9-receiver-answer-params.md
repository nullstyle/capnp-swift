# H9 — capnp-zig: resolve `receiverAnswer` capabilities in call params for the host

- **To:** capnp-zig (the owner lands it on `main` and cuts the tag)
- **From:** capnp-swift (M2)
- **Date:** 2026-10-06
- **Status:** DRAFT (the owner sends it)
- **Needed by:** M4 (interop matrix). Until then capnp-swift refuses such calls with an exception (below), so nothing is silently wrong, but a C++ or Go client that pipelines a capability into a call's params gets that exception from a capnp-zig or capnp-swift server.

This is a document, not an issue. Nothing here was filed anywhere.

## The gap

A caller may pass a capability it does not hold yet as an argument: the result of a pending question, as a `receiverAnswer { questionId, transform }` cap descriptor in the params cap table (the C++ reference does this whenever a pipelined cap is passed to another call). Two cases at v0.21.0:

1. **Call target** `promisedAnswer`: supported. The Peer queues the call until the answer resolves and dispatches it to the resolved export (capnp-swift's `test-abi` "pipelining" test, question `q2`).
2. **Params cap** `receiverAnswer`: the Peer dispatches the call at once and hands the handler an `InboundCapTable` whose entry is `.promised` (`src/rpc/caps/inbound.zig`). `InboundCapTable.resolveCapability` is `get(index)` (`inbound.zig:104`): it never consults the answer table, so the entry stays `.promised` **even after the answer was returned** (capnp-swift's test, question `q4`: the Return for `q1b` had been sent before `q4` arrived). The generated `resolveX(peer, caps)` returns `error.UnexpectedCapabilityType` for it (`tests/e2e/zig/generated/chat.zig`, `resolveRoom`), so no capnp-zig server can use such an argument either.

## What capnp-swift does meanwhile

`core/src/cap_remap.zig` `copyInbound` returns `error.PromisedCapUnsupported` for a `.promised` entry. For a call that makes the Peer answer the caller with an exception whose reason is `PromisedCapUnsupported`; for results it ends the question with `RETURN{EXCEPTION}` (`conn.promised_results_reason`). The host never sees a null capability where the caller sent a real one. Covered by `zig build test-abi` ("pipelining" test, `q3` before the answer and `q4` after it).

## Proposed change

Either of these makes a `receiverAnswer` params cap usable; A matches the reference implementation.

**A (recommended): resolve at dispatch, queue when pending.** When a Call's params cap table holds a `receiverAnswer`:
- if the named answer has returned, replace the entry with the resolved cap (`.exported` for an export of ours, `.imported` for an import we returned) before the handler runs; the answer's result caps are already in `resolved_answers`;
- if it has not, queue the call like a `promisedAnswer`-targeted call (`pending_calls`), and dispatch it when the answer resolves. The queued-call limits (`max_pending_queued_calls`, `max_pending_queued_call_bytes`) bound it.

**B: a local promise client.** Keep immediate dispatch, but give the handler a capability that queues calls until the answer resolves (the C++ `LocalPromiseClient` shape). More code, and the generated `resolveX` API has no promise type today.

Also: make `InboundCapTable.resolveCapability` do what its name says, or rename it.

## A test to add

In `tests/rpc/peer/`: peer A calls B's export (`q1`) whose results carry a new export `E`; before `q1` returns, A sends `q3 = call(bootstrap, params = { cap = receiverAnswer(q1, [0]) })`. Expected: B's handler for `q3` receives `E` (an `.exported` entry) and runs after B's `q1` handler answered. Ablation: skip the resolution; the handler sees `.promised` and the test fails.

## Not verified

- The reference behavior for a `receiverAnswer` whose answer returned an *exception* (the C++ implementation propagates the exception to the call).
- Whether the embargo rules for `Disembargo` apply to a cap resolved this way (they should not: the cap is local to the callee).
