# Apple SDK handoff: Network.framework QUIC teardown race (macOS 26.x)

Status: closed on the capnp-swift side by owner decision, 2026-10-12:
"dont report anything". Local reference only. The SDK race is not fixed
and has not been reported to Apple. Do not submit this document or resume
the investigation without a new owner instruction.

Original format: Apple Network.framework engineering / Feedback Assistant.
Prepared from capnp-swift hosted reproductions, 2026-10-12/13. All stacks,
logs and disassembly below come from the referenced artifacts.

## Summary

An intermittent Swift fatal error kills processes that use the modern
structured-concurrency Network API (`NetworkConnection<QUIC>`,
`NetworkListener<QUIC>`, `QUIC.Stream`) on macOS 26:

```
Network/Connection.swift:5833: Fatal error: Neither nw nor nwGroup is initialized
```

The assertion fires inside a Network.framework-internal Swift concurrency
job (state delivery machinery) while connections are being torn down. No
client code frame is present in the crashing job. The client uses only
public API. The modern API exposes no `cancel()`, so teardown is
necessarily reference-drop driven; the crash indicates the wrapper's
backing (`nw` / `nwGroup`) is cleared before its own task-based state
delivery finishes reading it.

## Environment of every captured failure

- Xcode 26.6 (17F113), Swift 6.3.3 (swiftlang-6.3.3.1.3),
  clang-2100.1.1.101, macOS SDK 26.5
- Hosted macOS 26.6.2 (25G83), arm64 runner
- ThreadSanitizer-instrumented test bundle (every capture below; the
  harness verifies actual sanitizer linkage)
- Not reproducible on macOS 27.0 / SDK 27.0 / Swift 6.4 local hardware
  (same binary shape; the assertion string still exists in the macOS 27
  Network binary, so absence of reproduction is a timing/build difference,
  not removal)

## Reproducer

Verified reproducer: `Tests/CapnpRPCTests/QUICTests.swift` in
https://github.com/nullstyle/capnp-swift (branch `main`).

The selection `--filter 'QUICTests.*roundTrip'` runs sixteen parallel
test cases. Each case, in one process:

1. `NetworkListener<QUIC>` on port 0, raw-DER TLS identity, ALPN
   `capnp-rpc/1`; `run` pumps accepted connections; each accepted
   `NetworkConnection<QUIC>` is started and its `inboundStreams` handler
   serves one `QUIC.Stream`.
2. Client `NetworkConnection<QUIC>` to 127.0.0.1; started exactly once;
   `openStream()`; one request/response exchange over stream 0; FIN.
3. Both sides drop their references (close RPC, cancel listener flag),
   sleep 1 s, test returns.

Harness: `scripts/diagnose-network-tests.py` repeats the selection in a
fresh process per attempt. Manual workflow `network-diagnostics.yml`.

Observed trap attempt counts (fresh process each attempt):

| Commit   | Scope  | Run            | Result                                   |
| -------- | ------ | -------------- | ---------------------------------------- |
| b44f48d  | quic   | 38337878901    | trap at attempt 27 (Connection.swift:5833) |
| b44f48d  | network| 38337878901    | trap at attempt 8  (Connection.swift:5817) |
| 78a655f  | quic   | 38339227662    | trap at attempt 8  (Connection.swift:5833) |
| 78a655f  | network| 38339227662    | trap at attempt 4  (Connection.swift:5817) |
| bb83c7c  | quic   | 38342149928    | 32/32 clean                              |
| bb83c7c  | network| 38342149928    | trap at attempt 6  (Connection.swift:5817) |
| bb83c7c  | network| 38343578838    | 16/16 clean                              |
| bb83c7c  | quic   | 38343578838    | trap at attempt 8  (Connection.swift:5833) |

("network" scope runs `QUICTests|TCPTests|M5Tests|ExecutorProbeTests`
together — classic `NWConnection`-based transports in the same process as
the modern QUIC API. "quic" scope runs the QUIC selection alone.)

## Captured stacks (LLDB, all three shapes identical)

Crashing thread — always a Swift concurrency job on the cooperative pool:

```
* thread #11, name = 'Task 867', queue = 'com.apple.root.default-qos.cooperative',
  stop reason = Fatal error: Neither nw nor nwGroup is initialized
    frame #0: libswiftCore.dylib`_swift_runtime_on_report
    frame #1: libswiftCore.dylib`_swift_stdlib_reportFatalErrorInFile + 204
    frame #2: libswiftCore.dylib`closure #1 in _assertionFailure(...) + 508
    frame #3: libswiftCore.dylib`_assertionFailure(...) + 172
    frame #4: Network`___lldb_unnamed_symbol_188b7d440 + 608
    frame #5: libswift_Concurrency.dylib`swift::runJobInEstablishedExecutorContext(swift::Job*) + 472
    frame #6: libswift_Concurrency.dylib`swift_job_runImpl(swift::Job*, swift::SerialExecutorRef) + 156
    frame #7: libdispatch.dylib`_dispatch_root_queue_drain + 360
    frame #8: libdispatch.dylib`_dispatch_worker_thread2 + 184
```

Captures: runs 38339227662 (jobs 115106245517 mixed and 115106245341
quic, commit 78a655f), 38342149928 (job 115115317242, commit bb83c7c)
and 38343578838 (job 115119792571, commit bb83c7c), tasks 867 / 1056 /
838 / 861 respectively. The Network frame offset `+608` is identical
across captures (ASLR varies the base only).

Concurrent context at trap time (quic-scope capture): several server-side
`QUICStreamTransport.close` frames (receive loops failing with "Socket is
not connected"), plus the os_log line immediately prior:

```
[connection_group] nw_connection_group_handle_connection_state_changed [G20]
  connection [C36 connected 127.0.0.1:55854 quic ...] failed with error Socket is not connected
```

Mixed-scope capture, crashing thread, microseconds before the fatal:

```
[connection] nw_connection_set_state_changed_handler_block_invoke [C78]
  Cannot set state changed handler after cancel
Network/Connection.swift:5833: Fatal error: Neither nw nor nwGroup is initialized
```

## Binary analysis of the assertion site (macOS 27.0 Network, local)

Method: located the string in `__cstring`, scanned `__text` for
`adrp/add` pairs resolving to it, fingerprinted each containing function
by its named callees (LLDB script; `/tmp/netprobe/` scratch).

Twenty-two specializations reference the assertion string. They cluster
into generic specializations of the modern wrapper whose named callees
identify the operations:

- eight 0x42c-byte copies calling `nw_connection_set_read_close_handler`,
  `nw_connection_set_write_close_handler`,
  `Network.NWConnection.start(queue:)` and
  `Network.NWConnectionGroup.start(queue:)` — `start()` specializations;
- eight 0x344/0x390-byte copies calling
  `Network.NWConnection.stateUpdateHandler.setter` and
  `Network.NWConnectionGroup.stateUpdateHandler.setter` (the 0x390
  variant also instantiates `NetworkChannel.State` metadata and contains
  `checkIsolated` traps, i.e. it delivers state to
  `@_inheritActorContext` handlers as Swift jobs);
- accessors for `maximumDatagramSize`, `dataTransferReport`, and
  `nw_connection_group_copy_peel_off_connection`.

So the guarded invariant is: the wrapper holds exactly one backing
(`nw: NWConnection?` or `nwGroup: NWConnectionGroup?`), and the task-based
state-delivery path (`onStateUpdate` bridge) reads that backing when it
runs. The fatal is that read finding both nil during teardown.

## Client-side hypotheses tested and falsified

1. **Double-start race (falsified as the cure, fixed anyway).** The
   client transport originally deferred `connection.start()` onto a
   dispatch queue while a concurrent `openStream()` task ran; async
   operations auto-start (WWDC25 session 250), so the two raced. Commit
   bb83c7c starts exactly once, synchronously, before `openStream()`.
   Result across two post-fix confirmation runs: one 32/32-clean quic
   scope and one 16/16-clean network scope, but each scope still trapped
   in the other run (attempts 8 and 6) with the identical job shape.
   The fix remains in the tree as correct usage; it is not the cure.
2. **Server-side redundant start (demoted).** `nw_connection_set_queue`
   "called after nw_connection_start" errors persist post-fix on exactly
   sixteen connections per process with server attribution disjoint from
   them (C65–C80 vs C31–C51), at ~22 occurrences each, in passing and
   failing attempts alike — chronic shim-internal noise, not a client
   double start, and not correlated with the trap.
3. **Remaining cause (this handoff).** Apple-internal race: the
   state-delivery job outlives the backing teardown that reference-drop
   triggers. Public API offers no way to sequence the two (no `cancel()`,
   no terminal-state acknowledgment).

## Suggested investigation on the SDK side

- In the `onStateUpdate` delivery bridge (the specialization family that
  calls the `stateUpdateHandler` setters and constructs
  `NetworkChannel.State`): confirm whether the backing is read after
  teardown can nil it (deinit/cancel path ordering vs queued job).
- The post-cancel sequence logged on the crashing thread
  (`nw_connection_set_state_changed_handler` after cancel, then the
  accessor trap) suggests the re-arm/teardown handshake itself touches
  the backing after clearing it.
- Whether a fix already landed for macOS 27 (we cannot reproduce there).

## Appendix: standalone reproduction sketch

The verified reproducer above carries an RPC stack. A standalone sketch
of the same shape for triage (not verified hosted; the test selection is
the verified path):

```swift
import Network

// Sixteen concurrent iterations per process, fresh process per attempt:
// 1. NetworkListener<QUIC> on port 0 (raw-DER identity, any ALPN), run {}
//    accepts; accepted connections started once, inboundStreams served.
// 2. Client NetworkConnection<QUIC>, start() once, openStream(), short
//    exchange, endOfStream send.
// 3. Drop all references on both sides; sleep ~1 s; exit.
// Trap surfaces within a handful of processes on Xcode 26.6 hosted arm64.
```
