# M9 sprint proposal: guardrails and remote cancellation — 2026-10-18

Status: **OPTION A IN PROGRESS** (owner, 2026-10-18). Steps 1-6 are done
(step 5: the iOS 18.6 floor passes in CI; macOS 15 cannot be run on
GitHub, because its newest Xcode has Swift 6.2 and the package needs 6.3),
step 7 waits for capnp-zig, and step 8 is done except the 0.1.3 proposal.
Results: plan §8 "M9 status".

## Where the project is

- **Released:** 0.1.2 (2026-10-18, tag `69e392e`). It ships the capnp-zig
  v0.27.0 core, the Experimental typed generator, and the QUIC fixes.
- **Milestones:** M0 to M8 are done. M8 (the `pass_back` and
  `pipelined_params` scenarios) is merged into main after the 0.1.2 tag.
- **Stable:** the wire protocol, the C ABI v1, `Capnp`, `CapnpRPC`, and the
  TCP, Unix and TLS transports.
- **Experimental:** typed generation (`--typed`), QUIC (macOS/iOS 26), and
  the pinned capnp-zig Peer.
- **Interop:** seven schemas pass against capnp-zig and the C++ reference
  in both directions, over TCP, Unix sockets and QUIC. The only failures
  are four listed native-H9 lines (`scripts/e2e-known-limits.sh`).

## Known gaps (input to this sprint)

| # | Gap | Where it comes from | Owner of the fix |
|---|---|---|---|
| G1 | A Stable-API bug: the legacy generated client cannot call its own export that comes back in results after the remote released it. The typed API works. | M8 finding | capnp-swift |
| G2 | `interop/e2e/gen/*.swift` is not in `generate-check`. `game_world.swift` is stale: two union setters do not write the discriminant. | M8 finding | capnp-swift |
| G3 | The pair scripts sometimes fail with `Address already in use` (1 in 9 lane runs). | M8 finding | capnp-swift |
| G4 | No gate catches a breaking change to the Stable Swift API. | survey | capnp-swift |
| G5 | The platform floor (macOS 15, iOS 18) is never run. CI uses only macOS 26 runners and their newest iOS simulator. | survey | capnp-swift |
| G6 | When a caller cancels or finishes a call, the Swift handler keeps running. The C ABI v1 has no "answer finished" effect, and `capnp_core_features()` is always 0. | H5, plan §4 | capnp-zig, then capnp-swift |
| G7 | Old notes in docs: CLAUDE.md says the repo has no remote; `typed-generics.md` says 0.1.1 lacks `--typed`; `stability.md` is titled "0.1.0". | survey | capnp-swift |
| G8 | The native Workbench apps were not rerun on the 0.1.2 core. | 0.1.2 sheet | capnp-swift |

Still deferred upstream, not in this sprint: native H9 for pending answers,
lookup-only H12, and tail-call results that carry capabilities.

## Option A (recommended): M9 guardrails and remote cancellation, for 0.1.3

Size: M. The capnp-zig part runs in parallel; if its tag is late, step 7
moves to the next sprint and the rest still ships.

1. **Fix G1.** Give legacy clients the handler snapshot that the typed API
   keeps at the RETURN. Write the failing test first (Swift/Swift and
   against the Zig server).
2. **Close G2.** Add `interop/e2e/gen` to `just generate` and
   `generate-check`, and regenerate `game_world.swift`. Break the gate once
   on purpose.
3. **Fix G3.** Remove the gap between picking a free port and binding it
   (bind port 0 and report the port, or retry a failed bind). Prove it with
   a 50-run loop.
4. **Add the G4 gate.** Run `swift package diagnose-api-breaking-changes 0.1.2`
   for `Capnp`, `CapnpRPC` and `CapnpNW` in CI. List the Experimental
   surfaces as allowed. Break the gate once on purpose.
5. **Cover G5.** Add an iOS 18 simulator run to the nightly (the runtime is
   a large download; ask before the first one). Check whether a macOS 15
   runner can build the package; if it cannot, record macOS 15 as an
   untested floor.
6. **Ask capnp-zig for G6** (handoff `H13-answer-finished-native.md`): the
   first native feature bit, and an opt-in `ANSWER_FINISHED` effect when the
   remote finishes a call the host has not answered. Also ask that a late
   host answer can never reach a reused answer id (an answer generation,
   or an ordering rule with `ANSWER_FINISHED`), and that `capnp_finish` on
   an open question returns what the header says (BUSY; the tail-call
   work saw INVAL). All are additive in ABI v1.
7. **Adopt G6 when capnp-zig tags it.** Cancel the handler `Task` on
   `ANSWER_FINISHED`, so `Task.isCancelled` and streaming stops work. Run
   TSan, ASan, the fuzz and the full matrix.
8. **Fix G7, rerun G8,** then prepare a 0.1.3 proposal. The owner approves
   the version, the tag and the uploads.

Exit gate: every CLAUDE.md gate green; every new check broken once on
purpose; hosted CI and the nightly green.

## Option B: typed API to Stable, for 0.2.0

Size: L. Freeze the `--typed` generated surface and its runtime types
(`CapnpPointerSchema`, `PointerReader`/`PointerBuilder`,
`RPCPointerCapability`), add an API snapshot, write a migration guide, and
move them to Stable in `stability.md`. Lookup-only H12 stays deferred (the
generator uses full request-node contexts).

## Recommendation

**Option A.** It fixes a bug in the Stable API, closes two silent gate
gaps, and starts the upstream cancellation work early, because that work
has to wait for a capnp-zig tag. Option B needs the API breakage gate from
step 4, so it is easier after A.

## Later (not proposed now)

FD passing (D4), three-party vats, persistence, WebSocket, QUIC native
mode, Mac Catalyst and visionOS slices, Go/Python/Rust reference peers, and
an opt-in to send pipelined params as `receiverAnswer`.
