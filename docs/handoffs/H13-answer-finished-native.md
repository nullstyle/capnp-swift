# H13: tell a native host when the caller finishes a call it still owes

Status: **OPEN, for the owner to send to capnp-zig** (2026-10-18). Plan:
M9 step 6 (`docs/sprint-m9-guardrails-2026-10-18.md`, gap G6). Base:
capnp-zig v0.27.0.

## The gap

A Swift server handler runs as a `Task`. When the caller cancels the call
or drops its promise, the caller sends Finish. Today the Swift handler
never learns this: it keeps running to the end, and its Return is dropped.
A long query or a stream keeps using CPU, memory and the network for
nothing.

The Peer already has what is needed. H5 delivered it in v0.23.0:

- `Peer.setAnswerFinishedHandler` runs once when the remote finishes an
  answer that the host was handed and has not answered
  (`src/rpc/peer/mod.zig`, the doc comment above line 1687).
- `Peer.sendReturnCanceled` answers such a call with `Return{canceled}`
  and frees the caller's question id.

The native shim does not use either. `src/native/conn.zig` never calls
`setAnswerFinishedHandler`, the C ABI has no effect for it, and
`capnp_core_features()` is always 0. capnp-zig deferred the native feature
bits until capnp-swift took the tail-call work. capnp-swift has done that:
0.1.2 ships the v0.27.0 core.

## The ask

All of it is additive in ABI v1. A host built against the v0.27.0 header
sees no change.

1. **The first feature bit.** For example `CAPNP_FEATURE_ANSWER_FINISHED`
   (bit 0), reported by `capnp_core_features()`.
2. **An opt-in.** A new last field in `capnp_conn_opts`, for example
   `uint8_t answer_finished`. A host that passes an older `struct_size`
   gets 0 and never sees the new effect.
3. **A new effect, `CAPNP_EFFECT_ANSWER_FINISHED` (6).** `id` is the answer
   id of an INBOUND_CALL that the host has not answered. It is queued from
   the Peer's answer-finished handler, at most once per answer, never for
   an answer the host already answered.
4. **A way to answer it.** For example `capnp_return_canceled(conn,
   answer_id)`, over `Peer.sendReturnCanceled`. After the effect, the host
   answers with this, or with its ordinary `capnp_return_results` or
   `capnp_return_exception`: exactly one answer, as today.
5. **A rule for late answers, in `docs/native-abi.md`.** A host answer that
   comes after the effect must never reach a different call that reuses
   the same answer id. Please state the guarantee (or add a generation if
   the Peer cannot give one today; the tail-call notes listed
   `pending_answers` with no generation as a follow-up).

## Questions for capnp-zig to decide

- **Tail-call hold.** A `sendResultsTo = yourself` call Y can be the target
  of a held question X. `native-abi.md` says the remote's Finish of Y does
  not end that wait. Should the effect skip such a Y, or should the host's
  canceled answer end X with RETURN CANCELED?
- **The tombstone bound.** The Peer runs no handler when
  `limits.max_active_inbound_questions` finished-early records are full.
  Is that also the native rule, and should a host see an event for it?
- **`capnp_finish` on an open question.** The header says `CAPNP_E_BUSY`.
  The tail-call work noted that a question that is still in flight returns
  `CAPNP_E_INVAL`. Please check, and align the header or the code, with a
  C-level test.

## How capnp-swift will use it

On `ANSWER_FINISHED`, the Swift runtime cancels the handler `Task` (Swift
cooperative cancellation), answers with `capnp_return_canceled` if the
handler has not answered yet, and stops a stream's send loop. Tests: a
handler that waits forever is cancelled within one tick after the
caller's cancel; a handler that finishes at the same moment answers once;
TSan, ASan, the C ABI fuzz and the full interop matrix stay green.

## Evidence for capnp-zig's own tests

- `test-abi` style: call, then Finish before the host answers. Expect one
  ANSWER_FINISHED effect, then `capnp_return_canceled` succeeds, and a
  second answer returns `CAPNP_E_BAD_ID`.
- Without the opt-in: the same frames give no new effect (old hosts).
- The C++ reference sends Finish when its client drops a promise, so a
  C++ client that cancels a slow call exercises the wire side.
