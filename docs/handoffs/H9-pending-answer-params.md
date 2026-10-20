# H9 (pending) — capnp-zig: evidence from the cap_passing matrix, and a test that shows the limit

- **To:** capnp-zig (the owner copies it there)
- **From:** capnp-swift (M8, matrix catch-up)
- **Date:** 2026-10-18
- **Status:** SENT to capnp-zig on 2026-10-20 (at the owner's request, as a
  message to the capnp-zig "Sprint planning" session). Waiting for its answer.
- **Row:** plan §3 H9. capnp-zig `docs/downstreams.md` lists it as "H9 (pending)", deferred.

This is a document, not an issue. Nothing here was filed anywhere.

## Summary

No new design ask. capnp-zig v0.27.0 resolves a `receiverAnswer` param only
after the named answer has returned (the H9 part delivered in v0.23.0), and
`docs/supported-surface.md` documents why a pending answer stays `.promised`.
This file gives the evidence from capnp-swift's run of the two new e2e
scenarios, and asks for one test that makes the limit visible in
capnp-zig's own matrix.

## What capnp-swift saw

capnp-swift ran `pass_back` and `pipelined_params`
(`tests/e2e/schemas/cap_passing.capnp`, v0.27.0) with its Swift peers on
the native core (v0.27.0). `pass_back` passes everywhere. `pipelined_params`:

| Client → server | Transport | Result |
|---|---|---|
| C++ → Swift (native core) | TCP | `check(pipelined mint().token)` and `check(pipelined mintFail().token)` fail with `PromisedCapUnsupported`, 20 of 20 runs. |
| Zig → Swift (native core) | TCP, Unix | Mostly passes. In 1 of 6 Unix runs, the mintFail() check failed. |
| Zig → Swift (native core) | QUIC | Both checks failed in each run. |
| Zig → Swift, the four calls sent in one write (test proxy) | TCP | Both checks fail with `PromisedCapUnsupported`, every run. |
| Swift → Zig, Swift → C++, Swift → Swift | all | Pass. The Swift runtime waits for mint()'s Return before it sends check() (the capnp-swift H9 wait), so check() carries `receiverHosted`, not `receiverAnswer`. |

Wire trace, C++ client → Swift server (frame-logging proxy, each frame
decoded with `capnp decode rpc.capnp Message`; trimmed):

```
997.638 ms C->S chunk 736 bytes
            bootstrap (questionId = 0)
            call q1 mint      target = promisedAnswer(0)
            call q2 check     capTable = [receiverAnswer(questionId = 1, [getPointerField 0])]
            call q3 mintFail  target = promisedAnswer(0)
            call q4 check     capTable = [receiverAnswer(questionId = 3, [getPointerField 0])]
999.181 ms S->C return answerId 0 (bootstrap)
1000.922 ms S->C return answerId 2 exception "PromisedCapUnsupported"
             return answerId 4 exception "PromisedCapUnsupported"
             return answerId 3 exception "pipelined_params: deliberate mint failure"
             return answerId 1 results [senderHosted 1]
```

The C++ client sends Bootstrap and all four calls in one write. The core
reads them in one push. Every handler of a native-ABI host is deferred (the
host answers through `capnp_return_results` later), so q1 and q3 are still
pending when q2 and q4 dispatch. This is case one of the limit in
`docs/supported-surface.md` ("when the answer is still pending (a deferred
handler or a forwarded call)"). The Zig client writes each call on its own,
about 0.3 ms apart, and the Swift host answers mint() in about 0.2 ms, so
the answer usually returns first.

The native core refuses a `.promised` entry with `PromisedCapUnsupported`
(`src/native/cap_remap.zig`, `copyInbound`). capnp-swift keeps that, and
records the two C++ lines as an expected failure
(`scripts/e2e-known-limits.sh`).

## Why capnp-zig's own matrix does not show it

In `tests/e2e/zig/main_server.zig`, `mint` is a direct handler
(`.mint = onTokenHostMint`), so its answer has returned before the Peer
reads the next frame. `mintFail` is deferred, but it sends its exception
inside the handler, before the Peer reads on. So every reference client
passes against the Zig server, and `docs/supported-surface.md` says the
scenarios run "in both directions against all four reference
implementations, with no SKIP". That is true for a synchronous server only.
A server whose `mint()` is deferred (any native-ABI host, or a Zig app that
answers later) fails when the pipelined call arrives before the answer
returns. The C++ client always sends it that way. Your CHANGELOG (v0.23.0)
says the Go and Rust clients also send `receiverAnswer`; capnp-swift did
not test them.

## Asks

1. **A test that shows the limit.** Add a variant of the e2e TokenHost whose
   `mint()` and `mintFail()` answer on a later loop turn (for example
   `--schema pipelined_params_deferred`, using `mint_deferred` and holding
   the `ReturnSender` until the next tick). Run it against the reference
   clients. Expected today: both `check()` lines fail, because the entry
   stays `.promised` and the generated `resolveToken` returns
   `error.UnexpectedCapabilityType`. Record it as a known limit (not a
   SKIP), so the matrix shows the gap that embedders hit, and turns green
   when the deferred H9 work lands.
2. **One sentence in the docs.** In `docs/supported-surface.md` (the limit
   above) and `docs/native-abi.md`: a native-ABI host answers every call
   deferred, so a client that pipelines a param (the C++, Go and Rust
   references always do) gets this case whenever the named call and the
   pipelined call arrive in one read.
3. **No change to the deferred row.** The local promise capability (or a
   queued call) stays your design decision. This evidence is only for its
   priority.

## Not verified

- The Go, Rust and Python clients against the Swift server (capnp-swift's
  matrix has only the Zig and C++ peers).
- Case three of the limit (Finish before a parked call replays) did not
  show up in these runs.
