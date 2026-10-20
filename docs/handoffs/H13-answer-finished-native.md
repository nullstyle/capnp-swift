# H13: tell a native host when the caller finishes a call it still owes

Status: **ACCEPTED by capnp-zig** on 2026-10-20, some asks with changes
(the shape is in "capnp-zig's answer" below). capnp-zig builds it; it
proposes v0.28.0, and the owner has not decided that release. capnp-swift
prepares the adoption and ships nothing against it before the tag. Sent
2026-10-20 at the owner's request, as a message to the capnp-zig "Sprint
planning" session. Written 2026-10-18. Plan: M9 step 6
(`docs/sprint-m9-guardrails-2026-10-18.md`, gap G6). Base: capnp-zig
v0.27.0.

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

## capnp-zig's answer (2026-10-20)

All asks accepted, some with changes. The shape can still change in review.

1. **Feature bit.** `CAPNP_FEATURE_ANSWER_FINISHED = (UINT64_C(1) << 0)`
   from `capnp_core_features()`. The bit means: the core reads the opt-in,
   it can produce effect 6, and it exports `capnp_return_canceled`.
2. **Opt-in.** `uint32_t answer_finished;` after `max_resolved_imports`, at
   offset 56; `capnp_conn_opts` grows from 56 to 60 bytes (4-byte aligned, no
   tail padding). 0 = off, 1 = on, other values = `CAPNP_E_INVAL`. An older
   `struct_size` reads 0. A new host on an older core checks bit 0 first.
3. **Effect.** `#define CAPNP_EFFECT_ANSWER_FINISHED 6`. `id` = the answer
   id; `export_id` and `host_tag` as in its INBOUND_CALL; every other field
   is 0. At most once per answer, only while the host owes it. Its node is
   reserved at INBOUND_CALL delivery (out-of-memory cannot lose it). It can be
   stale: the host answered after the Finish but before it drained the
   effect (FIFO puts the effect before that answer's Return frame), so the
   host applies effects in drain order and treats a stale one as "already
   answered". Also produced for the host's own loopback call when the host
   cancels that loopback question.
4. **Answer.** `int32_t capnp_return_canceled(capnp_conn *conn, uint32_t
   answer_id);` over `Peer.sendReturnCanceled`. `CAPNP_E_BAD_ID` if the id is
   not owed; `CAPNP_E_INVAL` unless the effect was queued for that id (opt-in
   off, no Finish yet, or the effect withheld by a tail-call hold). Success
   removes the pending answer. After the effect the host may still answer
   with results or an exception instead. A yourself call gets
   `Return{canceled}`.
5. **Late answers (a rule, no generation).** The Finish leaves a
   finished-early record; while it exists, a Call or Bootstrap that reuses the
   id fails with `DuplicateQuestionId`. Only the host's one Return frees the
   id. When the records are full, the shim closes the connection on a new
   INBOUND_CALL whose id the host still owes (an exception Return for that
   id, then Abort). Behaviour change: today that reuse ends a held tail-call
   question with `tail_call_reused_reason`. Owed answers are capped at
   `max_active_inbound_questions` (default 4096).

Questions:

- **(a) Tail-call hold.** The effect does not end a held question. The core
  withholds ANSWER_FINISHED(Y) while a held question X waits on Y, and
  queues it once if the hold ends without Y's answer. It never starts a hold
  on a Y it already reported.
- **(b) Records full.** No record, no handler: no effect,
  `capnp_return_canceled` gives BAD_ID, the host's ordinary answer goes on
  the wire. Best effort under that bound, documented; no new event.
- **(c) `capnp_finish` on an open question.** The code is wrong, not the
  header: it returns INVAL today; the fix returns BUSY, with a C-level test.

The same change fixes the header text at `capnp_core.h:335-338` (an answer
after an early Finish is accepted once, not refused with BAD_ID) and a
nested `/*` near line 250. It also fixes a Peer out-of-memory bug:
`capnp_return_exception` after an early Finish could return OK with no
Return on the wire.

## capnp-swift review (2026-10-20)

Sent to "Sprint planning" (full text in the shared session notes,
`capnp-swift-h13-review-2026-10-20.md`). Accepts the shape. Items:

1. **Docs ask.** After the host's one answer (any of the three), the remote
   frees the id and can reuse it at once. Then a second, late answer is not
   refused with BAD_ID: it goes to the new call. H13 makes this reachable,
   because a host now has two answer paths for one call. The C++ reference
   hands out the lowest free question id, so it reuses at once. Asked for a
   sentence in `docs/native-abi.md`: at most one answer per INBOUND_CALL;
   BAD_ID is no guarantee once the id can be reused.
2. (c) has no capnp-swift impact: it ignores `capnp_finish`'s code and never
   finishes an open question.
3. Drain order fits: every effect is handled synchronously on the connection
   actor.
4. Optional e2e scenario (capnp-zig's call): `slow()` cancelled, then
   `fast()`; with the C++ client it also covers item 1.

## capnp-swift adoption plan (prepared, not shipped)

Waits for a capnp-zig tag with this shape. Until then, only a throwaway
local branch builds against a branch archive (`zig build --fork=<dir>`).

1. **Pin.** `core/build.zig.zon` to the tag; copy its header to
   `core/include/capnp_core.h` (`scripts/check-native-header.sh`); update
   `CapnpCoreInfoTests`.
2. **Opt-in.** In `RPCConnection` (where it fills `capnp_conn_opts`), set
   `answer_finished = 1` when `capnp_core_features()` has bit 0.
3. **Answer table.** `handleInboundCall` stores the handler `Task` under
   the answer id with a fresh token. `complete()` answers only when the
   entry is still there with the same token; otherwise it updates only the
   in-flight counters.
4. **Effect 6.** In `handle(_:)`: remove the entry (none = stale: ignore),
   cancel its `Task`, call `capnp_return_canceled`. So the remote gets its
   Return at once, even from a handler that never checks cancellation.
5. **Close.** On transport close, cancel every entry's `Task` (the caller is
   gone). No core call.
6. **Docs.** Remove the H13 known limit (README, release notes) and the
   Finish sentence in `Examples/RPCWorkbench/README.md`.
7. **Tests.** A handler that waits forever sees cancellation within 1 s
   after the caller cancels: `Tests/CapnpRPCTests/RemoteCancellationTests.swift`,
   added 2026-10-20 as a known issue (`withKnownIssue`) on the v0.27.0
   core. Ablation: with the check forced true it fails ("Known
   issue was not recorded"), so the adoption must remove the wrapper. A
   handler that ends at the
   same moment answers once; a late completion after the cancel never calls
   into the core; C-level (`core/abi_test.zig`): one effect, then
   `capnp_return_canceled` OK, then BAD_ID, and no effect without the
   opt-in. Then `swift test`, TSan, ASan, `fuzz-abi`, the Zig, C++ and QUIC
   matrices. Each new test broken once on purpose.

**Owner decision at adoption: the default.** (A) Cancel handlers by
default, with an `Options` switch to turn it off: the Swift idiom (a
cancelled caller cancels the work). (B) Off by default, opt in: as the C++
reference, which cancels a server call only when the method allows it.
Recommended: A.
