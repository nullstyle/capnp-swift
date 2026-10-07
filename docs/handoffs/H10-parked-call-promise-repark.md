# H10: re-park question-queued calls when the answer's Return carries an unresolved promise export

Found in capnp-swift M4 (2026-10-07), interop matrix, `resolve_disembargo`
against the C++ reference server and Swift↔Swift pairing.

## What happens

A call pipelined on a promised answer (`target = promisedAnswer(q)`) that
arrives BEFORE the answer's Return is parked at question level
(`Peer.pending_promises`, via `planPromisedTarget` → `queue_promised_call`).
When the Return arrives, `recordResolvedAnswer` → `drainPendingPromises`
(`src/rpc/promises/pending_calls.zig:160`) re-dispatches each parked call
with `handle_resolved_call` directly. If the resolved target is an
UNRESOLVED promise export (a Return carrying a promise cap, exactly the
resolve_disembargo scenario), that lands in `handleResolvedExportedCall`
(`src/rpc/peer/call/peer_call_orchestration.zig:41`) with
`resolved == null`, which answers the parked call with the exception
`"promised capability unresolved"` instead of re-parking it on the promise
export (`queue_promise_export_call`, as `planPromisedTarget` would for a
call arriving after the Return).

Calls arriving AFTER the Return park correctly (the
`planPromisedTarget` → `has_unresolved_promise_export` →
`queue_export_promise` path), which is why Zig↔Zig and Zig↔Swift pairings
pass while clients that pipeline strictly before the Return (the C++
reference, capnp-swift) hit the exception.

## Expected behavior

Per the RPC protocol, a call on an unresolved promise must queue until the
promise resolves. `drainPendingPromises` should route through
`planPromisedTarget` (or equivalently check `hasUnresolvedPromiseExport`)
so a drained call whose target is an unresolved promise export re-parks in
`pending_export_promises` and replays on `resolvePromiseExportTo*`.

## Repro

capnp-swift `scripts/e2e-pair.sh <swift-server> <cpp-client>
resolve_disembargo` (or Swift↔Swift): `Bail out! KJ exception: remote
exception: promised capability unresolved` after `reflect`.
