# Release 0.2.0 — proposal and publication (2026-10-21)

> **Published 2026-10-21** as [0.2.0](https://github.com/nullstyle/capnp-swift/releases/tag/0.2.0)
> at `af2a983942250a951df15656519b5dc48c75a482` (owner approved: the version
> 0.2.0, the tag, both assets unsigned). The tag went first, then the
> uploads; both downloads match the SHA-256 values below; then main moved.
> Post-publish smoke: a fresh consumer with an isolated SwiftPM cache
> resolved tag 0.2.0 at `af2a983`, downloaded the 0.2.0 core URL, built for
> macOS (Release and Debug), iOS device (unsigned) and iOS simulator,
> printed `core 0.1.0 / capnp-zig 0.28.0 / capnpc_zig-0.28.0-nUduFX-…`, saw a
> caller's cancel reach the handler (a `Task.sleep` ended with
> cancellation) in Release and Debug, answered 20 of 20 calls of a throwing
> handler with the remote exception, and completed a TCP bootstrap and
> close against the v0.21.0 zig-peer. The downloaded codegen bundle passes
> `scripts/check-codegen-bundle.sh`. [CI 39644198336](https://github.com/nullstyle/capnp-swift/actions/runs/39644198336)
> on the release commit passed all four jobs: `swift test` and the Release run
> 83 tests each, TSan and ASan 83 each; the API gate, now against 0.2.0, found
> no breaking change; the renamed-archive gate passed 21 checks with the
> released 0.2.0 core. The text below is the proposal as approved.

**Proposed version: 0.2.0, pending owner approval of the version, the tag
and the uploads.** The owner asked for this proposal on 2026-10-21 (land
H13 with handler cancellation on by default, option A). Published 0.1.4
stays immutable. Typed generation and QUIC stay Experimental.

**Why 0.2.0, not 0.1.5:** by default a caller's cancel now cancels the
handler's `Task`, which changes what the Stable `CapnpRPC` runtime does
for existing handlers: a cancellation-aware await in a handler (for
example `Task.sleep` or an outbound call) now throws when the caller has
gone. `docs/stability.md` bumps the minor version for a breaking change.
The API itself only grows (`Options.cancelHandlersOnFinish`); the API gate
finds no breaking change. If you treat the change as a patch, the same
artifacts ship as 0.1.5.

**What would ship** (main at `b3933c4`; plan §3 H13, §8 "M9 status" G6):

- **Remote cancellation (M9 G6, handoff H13).** On
  `CAPNP_EFFECT_ANSWER_FINISHED` the runtime cancels the handler's `Task`
  and answers `capnp_return_canceled` at once; a closed connection cancels
  the handlers that still run; a per-answer token drops a late completion.
  `RPCConnection.Options.cancelHandlersOnFinish` (default true) turns both
  off.
- No core change and no generator change: both assets are the 0.1.4 files.

**Release commit:** main with `dist/0.2.0-Package.swift.patch` applied: the
CapnpCore URL moves to the 0.2.0 download, the checksum stays. Commit it
only with the upload. That commit also moves the API gate's baseline to
0.2.0.

| Asset | SHA-256 | Source |
|---|---|---|
| `CapnpCore.xcframework.zip` | `c1a0fa0d206c49f5db62d3ff0040d01f0bfb44a31b8615617b91f1266208a698` | The 0.1.4 core asset, byte-identical (its download was verified at the 0.1.4 publication). `core/` and `Package.swift` are unchanged since the 0.1.4 release commit `90f24f2`. |
| `capnpc-swift.artifactbundle.zip` | `8c241efe29b2e6df29ad02e6c7209687de08d5d439bb632f9ecadecd72eac10a` | The 0.1.2 to 0.1.4 asset, byte-identical; the 147 bundle inputs are unchanged since `90f24f2`. |

Staged (gitignored) in the worktree `.claude/worktrees/capnp-zig-0-27-61005f/dist/`:
`0.2.0-CapnpCore.xcframework.zip`, `0.2.0-capnpc-swift.artifactbundle.zip`,
`0.2.0-Package.swift.patch` and the notes draft `0.2.0-release-notes.txt`.

| Evidence | Scope |
|---|---|
| [CI 39634420608](https://github.com/nullstyle/capnp-swift/actions/runs/39634420608), `b3933c4` | All four jobs: core; swift (`swift test` and `release-test`, 83 tests each, no known issue; the API gate: no breaking change in `Capnp`, `CapnpRPC`, `CapnpNW`; mvp; the Workbench gate and the renamed-archive gate, 21 checks with the released 0.1.4 core; the native Mac build); sanitizers (TSan and ASan, 83 each); ios (the unsigned device build). |
| [Nightly 39634452470](https://github.com/nullstyle/capnp-swift/actions/runs/39634452470), `b3933c4` | All five lanes: 1800 s fuzz (3,246,760 sessions, 104,820 ANSWER_FINISHED: 7,357 stale, 63,456 canceled; 0 live); the Zig matrix 52, 55 and 4 and the Unix lane 52; the C++ reference 122 + 2 known and 52; the QUIC lanes with the 90 s idle gate and the QUIC matrix 14/14; the iOS simulator, 81 tests across the selections. |
| The shipped core, `b3933c4` | With the committed `Package.swift` (the released 0.1.4 core, the asset to ship): `swift test` and `release-test` 74 + 9; mvp 4/4 over TCP and 6/6 over QUIC, Zig-to-Swift QUIC 3/3; Zig 52, 55 and 4; C++ 122 + 2 known and 52; Unix 52; QUIC matrix 14/14. |
| H13 adoption (`f1f669b`) | `RemoteCancellationTests` (5): the cancel reaches the handler in about 8 ms; a handler that ignores it still gets `Return{canceled}` out at once and its late answer is dropped; 200 cancelled calls take both orders in each run; the opt-out keeps the handler; a close cancels handlers. Ablations: no opt-in fails 3, no `Task` cancel 1, no `capnp_return_canceled` 2. |

`b3933c4` changes documentation only after `f1f669b`.

**Known boundaries:** native H9 for pending answers and lookup-only H12
stay deferred upstream; `pipelined_params` lines are listed known limits.
Tail-call results that carry capabilities end with an `unimplemented`
exception. When the core cannot record a Finish (its finished-call records
are full, or out of memory), no cancel reaches the handler, which then
runs to the end. QUIC's hosted SDK teardown trap is unfixed by owner
decision. The toolchain floor is Swift 6.3; the macOS 15 runtime is not
run. No physical iPhone run on this core.

**Before publication:** the owner approves the version (0.2.0 or 0.1.5),
the tag, the two uploads, and the signing policy (0.1.0 to 0.1.4 shipped
unsigned). The core version string stays `core 0.1.0` (the core did not
change). With 0.2.0, `docs/stability.md` ("Stability in 0.1.x") moves to
0.x wording in the publication record. Then: apply the patch, commit, push
the tag, upload both assets,
compare the downloads with the SHA-256 values above, move main, and run
the post-publish consumer smoke (release.md step 6). No tag, release asset
or publication exists yet.
