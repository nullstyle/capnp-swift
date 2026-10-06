# H8 — capnp-zig: transport close must cancel every question, even without memory

- **To:** capnp-zig (the owner lands it on `main` and cuts the tag)
- **From:** capnp-swift
- **Date:** 2026-10-06
- **Status:** DRAFT (the owner sends it)
- **Needed by:** nothing blocks on it. capnp-swift works around it in its shim (below). Other embedders and capnp-zig's own transports still have the defect.

This is a document, not an issue. Nothing here was filed anywhere.

Base: v0.20.0 (`01eaebe`); `src/` is identical at `1ee6d18`. Line numbers are v0.20.0's.

## The defect

`Peer.notifyTransportClosed` (`src/rpc/peer/mod.zig:4080`) reaches `finishTransportClosedNotification`, which calls `forceCancelAllQuestions(disconnected_reason, .disconnected)` (`mod.zig:4125`) to give every open question its terminal. That function (`src/rpc/peer/peer_lifecycle.zig:682-727`, `forceCancelAllQuestionsRouted`) first copies the question ids into an allocated list:

```zig
var ids: std.ArrayList(u32) = .empty;
defer ids.deinit(self.allocator);
var it = self.questions.keyIterator();
while (it.next()) |key| ids.append(self.allocator, key.*) catch break;
```

When an `append` fails, the loop stops and only the ids copied so far are cancelled. When the first `append` fails, **no** question is cancelled. The others stay in `self.questions` with no `on_return` and no `deinit_ctx`:

- `notifyTransportClosed` runs once (`transport_close_notified`), so nothing retries it;
- `checkDeadlines` ends only questions that have a deadline;
- the terminals come only from `Peer.deinit`: its own `forceCancelAllQuestions` (`peer_lifecycle.zig:86`), or, if that fails too, the `deinit_ctx` loop (`:108-112`).

So a caller waiting on such a question waits until the Peer is freed. "A transport close ends every open question with a synthetic disconnect" does not hold under memory pressure.

## Reproduction

capnp-swift `core/src/conn_test.zig`, test `disconnect: with no memory at all, transportClosed still ends every open question before free`: two connected peers, two calls left unanswered, then every allocation of the caller's Peer fails during `notifyTransportClosed`. Without the shim workaround the caller gets 0 terminals for both calls until `Peer.deinit` (M0 review, ADV9). An allocation-failure sweep over a caps-both-ways session hits the same gap at one fail index (capnp-swift `oom sweep: ...` test; the review's ADV4 found it at index 164).

## Proposed fix

Make the cancel pass allocation-free, so it cannot skip questions.

**Option A (recommended): reserve the id list when a question is added.** Keep a `cancel_scratch: std.ArrayList(u32)` on the Peer and, wherever a question enters `self.questions` (`call/peer_call_sender.zig` and the other `questions.put` sites), call `cancel_scratch.ensureTotalCapacity(allocator, questions.count())` next to the `put`. A failure there is an ordinary send failure, reported to the caller of `sendCall`. `forceCancelAllQuestionsRouted` then uses `appendAssumeCapacity` and never allocates. The snapshot semantics stay the same: questions a terminal callback adds during the pass are not in the snapshot.

**Option B: remove one arbitrary key at a time.** Loop `while (self.questions.count() > 0)`: take the first key from a fresh `keyIterator()`, `fetchRemove` it, and deliver its terminal. This needs no list, but a callback that adds a question during the pass would have it cancelled too, and a callback that keeps adding questions could keep the loop going. Bound the loop by the count at entry if you take this option.

Either way, also replace the silent `catch break` with a path that cannot drop questions.

Add a test: fail every allocation inside `notifyTransportClosed` (a `FailingAllocator` with `fail_index = alloc_index`) and require one terminal per open question before `Peer.deinit`. Ablate it once by restoring `catch break`.

## What capnp-swift does until then

`core/src/conn.zig` keeps an intrusive list of the questions it sent and has not seen end. After `notifyTransportClosed` returns, `Conn.transportClosed` queues `RETURN{DISCONNECTED}` for every question still on that list, from a node it reserved when the question was sent, and marks it swept. When the Peer later calls `on_return` or `deinit_ctx` for a swept question (at `Peer.deinit`), the shim only frees its context. `Conn.Stats.terminal_via_close_sweep` counts these. With this fix the counter stays 0 in practice, and the sweep stays as a guard.
