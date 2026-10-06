# H5 — capnp-zig: tell the host when the caller finishes an unanswered call; typed promise rejection

- **To:** capnp-zig (the owner lands it on `main` and cuts the tag)
- **From:** capnp-swift
- **Date:** 2026-10-06
- **Status:** DRAFT (the owner sends it)
- **Needed by:** M2 (RPC complete). Until then capnp-swift's `ANSWER_FINISHED` effect is best effort.

This is a document, not an issue. Nothing here was filed anywhere.

Base: v0.20.0 (`01eaebe`); `src/` is identical at `1ee6d18`. Line numbers are v0.20.0's. `main` is now `5fabb36` (the H4 fix); it adds one line to `src/rpc/peer/mod.zig` at `:1991`, so `mod.zig` lines after that are one higher on `main`. No other cited file changed.

## Summary

Three additive, Experimental `Peer` APIs:

1. `setAnswerFinishedHandler`: a callback when the remote sends Finish for an inbound call that the host was handed and has not answered.
2. `sendReturnCanceled`: the natural reply after that callback (`Return{canceled}`, and the calls pipelined on the answer get their own Return).
3. `resolvePromiseExportToExceptionTyped`: `resolvePromiseExportToException` with an `Exception.Type`, mirroring `sendReturnExceptionTyped`.

A prototype of all three passes `zig build test-rpc-peer` (518 of 518), and each of its 5 new tests was ablated.

## What happens today

A host export handler (`Export.on_call`) may return without replying and reply later with `sendReturnResults` (`mod.zig:3587`), `sendReturnException` (`:3606`) or `sendReturnExceptionTyped` (`:3612`). Suppose the caller sends Finish first.

1. `handleFinish` (`mod.zig:4471`) removes the answer from `active_inbound_questions` (`was_active`, `:4498`).
2. It records a tombstone with the Finish's `releaseResultCaps`: `finished_early_answers.put` (`:4508-4520`).
3. It cancels queued *pipelined* calls whose own id is the finished one and sends their `Return{canceled}` itself (`:4524`, `:4607`).
4. **Nothing tells the host.** There is no callback and no event (`events.zig` has no Finish event; `getLastInboundTag`, `mod.zig:1578`, gives only the last tag). The host's handler keeps working.
5. When the host replies, the late Return is accepted: it goes on the wire, is not recorded, and its result caps are released per the Finish flag (`return/peer_return_send.zig:118-133`, `:480-496`; the exception path `:369`, `:380`; `sendReturnTag` `:581-591`). Existing tests show it: `tests/rpc/peer/rpc_answer_lifecycle_test.zig:244` and `:1009`.
6. Until the host replies, the id stays taken: `inboundAnswerQuestionIdInUse` (`mod.zig:5520-5526`) includes the tombstone, so a reuse of the id is rejected (test `:1066`). A host that never replies leaks one tombstone (bounded by `max_active_inbound_questions`, `mod.zig:4517`) and blocks the caller's question id.

The host also has no public way to send `Return{canceled}`: `sendReturnTag` is private (`mod.zig:3678`).

## Why capnp-swift needs it

- Swift handlers run as `Task`s. Finish means the caller dropped its promise or cancelled. Swift should cancel the handler `Task` (cooperative cancellation stops a long query or a stream) and answer at once, so the caller's question id is freed.
- capnp-swift's C ABI already has the effect: `ANSWER_FINISHED {answer_id}` (plan §4). Without a hook, the shim would have to decode every inbound frame a second time to spot Finish (`protocol.DecodedMessage.init` runs the full validation walk, `src/rpc/wire/protocol.zig:330`, `:342`) and then guess whether the Peer still owes a Return. The Peer already knows: it skips the guess for queued pipelined calls, forwarded calls, joins and third-party routes.
- Typed rejection: a Swift `RemotePromise` rejected with `RPCError.overloaded`, `.disconnected` or `.unimplemented` should keep its type on the wire, as it already does for returns (`capnp_return_exception` takes a type; `capnp_reject_promise` cannot until this lands).

## Proposed change

### 1. `setAnswerFinishedHandler`

Contract:

- `handler(ctx, peer, answer_id, release_result_caps)` runs at most once per answer, inside `handleFrame`, after the Finish is fully applied.
- It runs only when the call was handed to the host and no Return was sent or begun for it. Not after the host replied; not while a Return is being sent (`was_resolving`); not for a queued pipelined call the Peer cancelled itself; not for a completing Join or a cancelled automatic third-party target.
- It can still run for an answer the Peer handles on the host's behalf (a forwarded call). The host ignores ids it does not hold.
- The host should stop the work and answer soon, normally with `sendReturnCanceled`. Any later Return is still accepted (the behavior above).
- capnp-swift's handler only queues an effect. Whether the handler may call `sendReturn*` re-entrantly was not tested; document "queue only" unless a test shows otherwise.

```diff
--- a/src/rpc/peer/mod.zig
+++ b/src/rpc/peer/mod.zig
@@ -198 +198,4 @@
 const ExportDeinitCtxFn = *const fn (std.mem.Allocator, *anyopaque) void;
+
+/// Experimental. See `Peer.setAnswerFinishedHandler`.
+pub const AnswerFinishedFn = *const fn (ctx: *anyopaque, peer: *Peer, answer_id: u32, release_result_caps: bool) void;
@@ -535 +538,4 @@
     finished_early_answers: std.AutoHashMap(u32, bool),
+    /// Experimental: `setAnswerFinishedHandler`.
+    answer_finished_ctx: ?*anyopaque = null,
+    answer_finished_fn: ?AnswerFinishedFn = null,
@@ -1576 +1582,14 @@ (after setSendFrameOverride)
+    /// Experimental. Call `handler` when the remote sends Finish for an
+    /// inbound call that this peer delivered and has not answered: no
+    /// Return was sent or begun for `answer_id`. The host should stop the
+    /// work and answer soon, normally with `sendReturnCanceled`; any later
+    /// Return is still accepted. It runs inside `handleFrame`, after the
+    /// Finish is fully applied, at most once per answer. It can also fire
+    /// for an answer the peer forwards on the host's behalf; ignore ids you
+    /// do not hold. Pass `null` to clear.
+    pub fn setAnswerFinishedHandler(self: *Peer, ctx: ?*anyopaque, handler: ?AnswerFinishedFn) void {
+        self.assertThreadAffinity();
+        self.answer_finished_ctx = ctx;
+        self.answer_finished_fn = handler;
+    }
@@ handleFinish, after :4505 (finished_completing_join)
+        // The host was handed this call and has not begun a Return for it.
+        const host_owes_return = was_active and !was_resolving and
+            !finished_completing_join and !self.resolved_answers.contains(qid);
+        var tombstoned = false;
@@ :4519
-            self.finished_early_answers.put(qid, finish_msg.release_result_caps) catch |err| self.reportNonfatalError(err);
+            if (self.finished_early_answers.put(qid, finish_msg.release_result_caps)) |_| {
+                tombstoned = true;
+            } else |err| self.reportNonfatalError(err);
@@ end of handleFinish, after the canceled_automatic_target cleanup (:4567-4569)
+        // A Return sent while this Finish was applied (a queued call the peer
+        // cancelled itself) consumed the tombstone; then the host owes nothing.
+        if (host_owes_return and !canceled_automatic_target and
+            (!tombstoned or self.finished_early_answers.contains(qid)))
+        {
+            if (self.answer_finished_fn) |notify| {
+                if (self.answer_finished_ctx) |ctx| notify(ctx, self, qid, finish_msg.release_result_caps);
+            }
+        }
```

`!tombstoned` covers the case where the bounded tombstone map was full (`:4517`): then the hook still fires.

### 2. `sendReturnCanceled`

It mirrors `sendReturnResultsSentElsewhere` (`return/peer_return_send.zig:572-579`). A bare `Return{canceled}` would leave calls pipelined on this answer queued forever; `failQueuedPromisedCalls` (`:433`) gives each its own exception Return.

```diff
--- a/src/rpc/peer/return/peer_return_send.zig
+++ b/src/rpc/peer/return/peer_return_send.zig
@@ before sendReturnTag (:581)
+        pub fn sendReturnCanceled(self: *Peer, answer_id: u32) !void {
+            self.assertThreadAffinity();
+            try sendReturnTag(self, answer_id, .canceled);
+            failQueuedPromisedCalls(self, answer_id, "call canceled", .failed);
+        }
--- a/src/rpc/peer/mod.zig
+++ b/src/rpc/peer/mod.zig
@@ after sendReturnExceptionTyped (:3612-3619)
+    /// Experimental. Send `Return{canceled}` for an answer whose caller sent
+    /// Finish first, and fail the calls pipelined on it. Body in
+    /// `return/peer_return_send.zig`.
+    pub fn sendReturnCanceled(self: *Peer, answer_id: u32) !void {
+        return ReturnSendImpl.sendReturnCanceled(self, answer_id);
+    }
```

### 3. `resolvePromiseExportToExceptionTyped`

Today `buildResolveException` (`src/rpc/wire/protocol.zig:1122-1128`) writes no type, so the remote sees `failed`. The Stable `resolvePromiseExportToException` (`docs/api-snapshot.txt:991`) keeps its signature and delegates with `.failed`. `sendReturnExceptionTyped` is Experimental (`docs/api-snapshot-experimental.txt:2254`), and so is the new function.

```diff
--- a/src/rpc/wire/protocol.zig
+++ b/src/rpc/wire/protocol.zig
     pub fn buildResolveException(self: *MessageBuilder, promise_id: u32, reason: []const u8) !void {
+        return self.buildResolveExceptionTyped(promise_id, reason, .failed);
+    }
+
+    /// `buildResolveException` carrying an explicit `Exception.Type`.
+    pub fn buildResolveExceptionTyped(self: *MessageBuilder, promise_id: u32, reason: []const u8, ex_type: ExceptionType) !void {
         var root_builder = try rpc_capnp.Message.Builder.init(&self.builder);
         ...
         try ex_builder.setReason(reason);
+        writeExceptionType(&ex_builder, ex_type);
     }
--- a/src/rpc/peer/peer_outbound_control.zig
+++ b/src/rpc/peer/peer_outbound_control.zig
 pub fn sendResolveException(...) !void {
+    return sendResolveExceptionTyped(PeerType, peer, promise_id, reason, .failed, send_builder);
+}
+
+/// `sendResolveException` carrying an explicit `Exception.Type`.
+pub fn sendResolveExceptionTyped(
+    comptime PeerType: type,
+    peer: *PeerType,
+    promise_id: u32,
+    reason: []const u8,
+    ex_type: protocol.ExceptionType,
+    send_builder: *const fn (*PeerType, *protocol.MessageBuilder) anyerror!void,
+) !void {
     var builder = protocol.MessageBuilder.init(peer.allocator);
     defer builder.deinit();
-    try builder.buildResolveException(promise_id, reason);
+    try builder.buildResolveExceptionTyped(promise_id, reason, ex_type);
     try send_builder(peer, &builder);
 }
--- a/src/rpc/peer/peer_promise_exports.zig
+++ b/src/rpc/peer/peer_promise_exports.zig
         pub fn resolvePromiseExportToException(self: *Peer, promise_id: u32, reason: []const u8) !void {
+            return resolvePromiseExportToExceptionTyped(self, promise_id, reason, .failed);
+        }
+
+        /// Resolve a previously exported promise to an exception of `ex_type`.
+        pub fn resolvePromiseExportToExceptionTyped(self: *Peer, promise_id: u32, reason: []const u8, ex_type: protocol.ExceptionType) !void {
             self.assertThreadAffinity();
             ...
-            try peer_outbound_control.sendResolveExceptionViaSendFrame(Peer, self, promise_id, reason, Peer.sendFrame);
+            try peer_outbound_control.sendResolveExceptionTyped(Peer, self, promise_id, reason, ex_type,
+                peer_outbound_control.sendBuilderForPeerFn(Peer, Peer.sendFrame));
--- a/src/rpc/peer/mod.zig
+++ b/src/rpc/peer/mod.zig
@@ after resolvePromiseExportToException (:2860-2862)
+    /// Experimental. `resolvePromiseExportToException` carrying an explicit
+    /// `Exception.Type`. Body in `peer_promise_exports.zig`.
+    pub fn resolvePromiseExportToExceptionTyped(self: *Peer, promise_id: u32, reason: []const u8, ex_type: protocol.ExceptionType) !void {
+        return PromiseExportsImpl.resolvePromiseExportToExceptionTyped(self, promise_id, reason, ex_type);
+    }
```

Two related gaps, not part of this request:

- Calls queued on the promise export before the rejection get `"promise broken"` and type `failed` (`src/rpc/promises/pending_calls.zig:240`), not the new type or reason.
- capnp-zig's own inbound `Resolve{exception}` drops the reason and the type (`src/rpc/peer/resolve.zig:100-103`), so a capnp-zig importer (including capnp-swift's core) never sees them. The typed send helps C++, Go and Rust importers today.

All new declarations default to the Experimental tier: regenerate `docs/api-snapshot-experimental.txt` and `docs/api-snapshot-experimental-quic.txt` (the prototype did not).

## The tests that prove it

Append these to `tests/rpc/peer/rpc_answer_lifecycle_test.zig`. That file is already registered (`build/build_impl.zig:994`, run by `test-rpc-peer` at `:1510`), so the tests cannot be dead. They reuse the file's helpers `ReturnCapture`, `newCapture`, `buildExportCallFrame`, `buildPipelinedCallFrame` and `buildFinishFrame`.

```zig
const FinishedRecorder = struct {
    count: usize = 0,
    last_answer: u32 = 0,
    last_release: bool = false,

    fn onFinished(ctx: *anyopaque, _: *Peer, answer_id: u32, release_result_caps: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.last_answer = answer_id;
        self.last_release = release_result_caps;
    }
};

/// Export handler that keeps every call pending (the host answers later).
const DeferringHost = struct {
    fn onCall(_: *anyopaque, _: *Peer, _: protocol.Call, _: *const cap_table.InboundCapTable) anyerror!void {}
};

fn deliver(peer: *Peer, allocator: std.mem.Allocator, frame_result: anyerror![]const u8) !void {
    const frame = try frame_result;
    defer allocator.free(frame);
    try peer.handleFrame(frame);
}

test "answer-finished hook fires once when Finish beats the host's Return" {
    const allocator = std.testing.allocator;
    var peer = Peer.initDetached(allocator);
    peer.disableThreadAffinity();
    defer peer.deinit();
    var capture = newCapture(allocator);
    defer capture.deinit();
    peer.setSendFrameOverride(&capture, ReturnCapture.onFrame);
    var rec = FinishedRecorder{};
    peer.setAnswerFinishedHandler(&rec, FinishedRecorder.onFinished);

    var host_ctx: u8 = 0;
    const export_id = try peer.addExport(.{ .ctx = &host_ctx, .on_call = DeferringHost.onCall });
    try deliver(&peer, allocator, buildExportCallFrame(allocator, 7, export_id));
    try std.testing.expectEqual(@as(usize, 0), rec.count);

    try deliver(&peer, allocator, buildFinishFrame(allocator, 7, true));
    try std.testing.expectEqual(@as(usize, 1), rec.count);
    try std.testing.expectEqual(@as(u32, 7), rec.last_answer);
    try std.testing.expect(rec.last_release);

    // The host stops and answers: exactly one Return{canceled}, no second
    // notification, and the early-Finish tombstone is consumed.
    try peer.sendReturnCanceled(7);
    try std.testing.expectEqual(@as(usize, 1), capture.countReturns(7, .canceled));
    try std.testing.expectEqual(@as(usize, 1), rec.count);
    try std.testing.expectEqual(@as(usize, 0), peer.finished_early_answers.count());
}

test "answer-finished hook stays quiet when the host already replied" {
    // ... same setup ...
    try deliver(&peer, allocator, buildExportCallFrame(allocator, 8, export_id));
    try peer.sendReturnEmptyStruct(8);
    try deliver(&peer, allocator, buildFinishFrame(allocator, 8, false));
    try std.testing.expectEqual(@as(usize, 0), rec.count);
}

test "answer-finished hook stays quiet for a pipelined call the peer cancels itself" {
    // ... same setup ...
    try deliver(&peer, allocator, buildExportCallFrame(allocator, 9, export_id));
    // Question 42 is pipelined on answer 9, so the peer queues it.
    try deliver(&peer, allocator, buildPipelinedCallFrame(allocator, 42, 9));
    try deliver(&peer, allocator, buildFinishFrame(allocator, 42, true));
    // The peer answered 42 itself (Return{canceled}); the host owes nothing.
    try std.testing.expectEqual(@as(usize, 1), capture.countReturns(42, .canceled));
    try std.testing.expectEqual(@as(usize, 0), rec.count);
}

test "sendReturnCanceled fails the calls pipelined on the cancelled answer" {
    // ... same setup, no recorder ...
    try deliver(&peer, allocator, buildExportCallFrame(allocator, 10, export_id));
    try deliver(&peer, allocator, buildPipelinedCallFrame(allocator, 43, 10));
    try deliver(&peer, allocator, buildFinishFrame(allocator, 10, true));
    try peer.sendReturnCanceled(10);
    try std.testing.expectEqual(@as(usize, 1), capture.countReturns(10, .canceled));
    try std.testing.expectEqual(@as(usize, 1), capture.countReturns(43, .exception));
}

test "resolvePromiseExportToExceptionTyped carries the exception type" {
    // ... setup with capture ...
    const typed = try peer.addPromiseExport();
    try peer.resolvePromiseExportToExceptionTyped(typed, "busy", .overloaded);
    // decode the captured Resolve for `typed`: exception.kind() == .overloaded, reason "busy"
    const plain = try peer.addPromiseExport();
    try peer.resolvePromiseExportToException(plain, "busy");
    // decode the captured Resolve for `plain`: exception.kind() == .failed
}
```

The full text of all five tests (with the setup written out and the `Resolve` decoder) is in the scratch file listed below.

**Measured** on a scratch copy of v0.20.0 with sections 1-3 applied (Zig 0.17.0, macOS 27 arm64): `zig build test-rpc-peer` passes 518 of 518 (the file's 22 existing tests, the 5 new ones, and 491 in the other peer suites). All changed files are `zig fmt` clean.

**Ablations** (each applied alone, then restored; restored runs pass):

| # | Ablation | Result |
|---|---|---|
| A1 | Never call the handler (`notify(...)` → `_ = notify;`) | RED: "fires once when Finish beats the host's Return": `expected 1, found 0` |
| A2 | Drop the tombstone check (fire for every `host_owes_return`) | RED: "stays quiet for a pipelined call the peer cancels itself": `expected 0, found 1` |
| A3 | `host_owes_return = true` | RED: "stays quiet when the host already replied": `expected 0, found 1` |
| A4 | Remove `failQueuedPromisedCalls` from `sendReturnCanceled` | RED: "sendReturnCanceled fails the calls pipelined...": `expected 1, found 0` |
| A5 | Remove `writeExceptionType` from `buildResolveExceptionTyped` | RED: "resolvePromiseExportToExceptionTyped carries the exception type": `expected .overloaded, found .failed` |

Each RED run reported 517 of 518 passed, 1 failed.

Found while ablating: my first A5 attempt removed the `writeExceptionType` call in `buildAbortTyped` (`protocol.zig:1087-1092`) by mistake, and `test-rpc-peer` stayed green. So no peer test checks the type of an outbound `Abort`. I did not run the other suites to see whether one does.

## Not verified

- A handler that calls `sendReturnCanceled` re-entrantly from inside the callback.
- The forwarded-call case (the hook firing for an answer the Peer forwards). It is documented, not tested.
- The full `zig build test`, `check-api` and the `-Dquic=true` root with the prototype.

## Scratch evidence (not in any repo)

Under `/private/tmp/claude-501/-Users-nullstyle-prj-zig-capnp-zig/d3e1b574-cf0b-4f76-a01c-9b84d5bc10a3/scratchpad/capnp-swift/h5-proto/`:

- `h5-src.diff`: the full source diff against v0.20.0.
- `tests/rpc/peer/rpc_answer_lifecycle_test.zig`: the five tests in full, after the line `// --- H5 (capnp-swift)`.
- `ablate_A1_no_notify.txt`, `ablate_A2_fire_on_any_active.txt`, `ablate_A3_owes_always.txt`, `ablate_A4_no_drain.txt`, `ablate_A5b.txt`: the RED logs. `restored.txt`, `restored2.txt`: the green re-runs.
