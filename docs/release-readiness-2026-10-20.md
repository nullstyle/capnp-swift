# Release 0.1.4 — proposal and publication (2026-10-20)

> **Published 2026-10-20** as [0.1.4](https://github.com/nullstyle/capnp-swift/releases/tag/0.1.4)
> at `90f24f29300d88a770a5cea5eace69eab1d15153` (owner approved: the tag, both
> assets unsigned, and a warning on the 0.1.3 release page). The tag went
> first, then the uploads; both downloads match the SHA-256 values below;
> then main moved. The 0.1.3 page now starts with a warning that points to
> 0.1.4 (its tag and assets are unchanged). Post-publish smoke: a fresh
> consumer with an isolated SwiftPM cache resolved tag 0.1.4 at `90f24f2`,
> downloaded the 0.1.4 core URL, built for macOS (Release and Debug), iOS
> device (unsigned) and iOS simulator, printed `core 0.1.0 / capnp-zig 0.28.0
> / capnpc_zig-0.28.0-nUduFX-…`, answered 20 of 20 calls of a handler that
> awaits a throwing nonisolated method with the remote exception in the
> Release build (0.1.3 trapped there), and completed a TCP bootstrap and
> close against the v0.21.0 zig-peer. The downloaded codegen bundle passes
> `scripts/check-codegen-bundle.sh`. [CI 39554905168](https://github.com/nullstyle/capnp-swift/actions/runs/39554905168)
> on the release commit passed all four jobs: `swift test` and the Release run 79
> tests each, TSan and ASan 79 each; the API gate, now against 0.1.4, found no
> breaking change; the renamed-archive gate passed 21 checks with the released
> 0.1.4 core. The text below is the proposal as approved.

**Proposed version: 0.1.4, pending owner approval of the tag and the
uploads.** The owner chose this on 2026-10-20 (option A: ship the 0.1.3
Release-crash fix and the capnp-zig v0.28.0 core first; H13 after).
Published 0.1.3 stays immutable. Typed generation and QUIC stay
Experimental.

**What would ship** (main at `221da22`; plan §8 "capnp-zig v0.28.0
adoption and a 0.1.3 Release crash"):

- **A fix for a 0.1.3 regression, Release builds only.** A server handler
  whose awaited call throws (every generated server's `handle` awaits a
  nonisolated server method) resumed the inbound call off the connection's
  queue, and the runtime's next isolation check trapped (SIGTRAP). Debug
  builds and 0.1.2 were not affected. `just release-test` now runs the
  suite in Release in CI.
- **The capnp-zig v0.28.0 core** (`73416c7`): three Peer fixes that a
  remote reaches through the C ABI (one read freed memory), the opt-in
  ANSWER_FINISHED feature (H13; the runtime does not opt in yet), and
  `capnp_finish` BUSY (the runtime ignores the code).
- Test coverage: the fuzz checks ANSWER_FINISHED; the Zig matrix runs
  `pipelined_params_deferred`; the header and dSYM gates read the pinned
  package.
- No Stable API change (the API gate finds none against 0.1.3). No
  generator change.

**Not in it:** the H13 runtime adoption (branch `claude/h13-runtime`),
because the Workbench archive gate builds the tree against the last
released core, and that core must have `capnp_return_canceled` first.

**Release commit:** main with `dist/0.1.4-Package.swift.patch` applied
(release.md step 3): the CapnpCore URL moves to the 0.1.4 download, and the
checksum to the new core. Commit it only with the upload: until then the
URL does not exist. That commit also moves the API gate's baseline to
0.1.4.

| Asset | SHA-256 | Source |
|---|---|---|
| `CapnpCore.xcframework.zip` | `c1a0fa0d206c49f5db62d3ff0040d01f0bfb44a31b8615617b91f1266208a698` | `scripts/make-release-xcframework.sh --verify` on `221da22` (core/ as on `d0e1cf1`): two builds, identical public surfaces on all slices, neutral paths only. 17 entries, zipped as before. |
| `capnpc-swift.artifactbundle.zip` | `8c241efe29b2e6df29ad02e6c7209687de08d5d439bb632f9ecadecd72eac10a` | The 0.1.2 and 0.1.3 asset, byte-identical. |

Archived core libraries (SHA-256): `ios-arm64` `bc442535…3e49`,
`ios-arm64_x86_64-simulator` `9834a9fb…97f9`, `macos-arm64_x86_64`
`2902ea78…60fa` (full values in `dist/0.1.4-release-notes.txt`).

Staged (gitignored) in the worktree `.claude/worktrees/capnp-zig-0-27-61005f/dist/`:
`0.1.4-CapnpCore.xcframework.zip`, `0.1.4-capnpc-swift.artifactbundle.zip`,
`0.1.4-Package.swift.patch` and the notes draft `0.1.4-release-notes.txt`.

**Codegen candidate:** its 147-entry source manifest differs from
`75f2bb5` in 4 entries: `Package.swift` (only the CapnpCore URL, checksum
and comment), `core/build.zig.zon`, `core/include/capnp_core.h` and
`core/src/fuzz_abi.zig`. No bundle build step reads them: the driver links
only WasmKit, and the plugin has its own v0.23.0 pin.
`scripts/check-codegen-bundle.sh` on the unzipped staged bundle passes
(2 checks).

| Evidence | Scope |
|---|---|
| [CI 39548179744](https://github.com/nullstyle/capnp-swift/actions/runs/39548179744), `221da22` | All four jobs: core (core tests, strict symbols, header and dSYM gates, codegen lanes); swift (`swift test` and the new `just release-test`, 79 tests each with the H13 known issue; the API gate; mvp; the Workbench gate and the renamed-archive gate against the released 0.1.3 core; the native Mac build); sanitizers (TSan and ASan, 79 each); ios (the unsigned device build). |
| [Nightly 39548202954](https://github.com/nullstyle/capnp-swift/actions/runs/39548202954), `221da22` | All five lanes: 1800 s fuzz (3,167,845 sessions, 102,844 ANSWER_FINISHED: 7,218 stale, 62,144 canceled; 0 live); the Zig matrix 52, 55 and 4 (`pipelined_params_deferred`) and the Unix lane 52; the C++ reference 122 + 2 known and 52; the QUIC lanes with the 90 s idle gate and the QUIC matrix 14/14; the iOS simulator, 77 tests across the selections (Xcode 26.6). |
| Local gates, `d0e1cf1` (core/ and Sources/ as on `221da22`) | `just gates` (core tests 23/23, builds, `swift test`, TSan, ASan, `release-test` 70 + 9, symbols, header, dSYM debug and release, mvp, fuzz 60 s), `check-symbols --strict` (31 exports), the e2e matrices with Debug and with Release Swift peers (Zig 55, C++ 122 + 2 known, QUIC 14/14), the QUIC lanes, the API, Workbench and codegen gates, typed C++ checks, a 300 s fuzz (959,980 sessions, 0 live). |
| The exact core zip, `221da22` | Unzipped in place of the development build: `check-symbols --strict`; `swift test` and `release-test` 70 + 9 (the version string names v0.28.0); mvp 4/4 over TCP and 6/6 over QUIC, Zig-to-Swift QUIC 3/3; Zig 52, 55 and 4; C++ 122 + 2 known and 52; Unix 52; QUIC matrix 14/14. |
| The Release crash | `ReleaseIsolationTests` trap in Release on the 0.1.3 code and pass with the fix (either part alone also passes); the published 0.1.3 tag traps, 0.1.2 does not. |

`221da22` changes documentation only after `d0e1cf1`.

**Known boundaries:** a caller's cancel does not stop a Swift handler yet
(H13 adoption on its branch, for the next release). Native H9 for pending
answers and lookup-only H12 stay deferred upstream; `pipelined_params`
lines are listed known limits. Tail-call results that carry capabilities
end with an `unimplemented` exception. QUIC's hosted SDK teardown trap is
unfixed by owner decision. The toolchain floor is Swift 6.3; the macOS 15
runtime is not run. No physical iPhone run on this core.

**Before publication:** the owner approves the tag `0.1.4`, the two
uploads, and the signing policy (0.1.0 to 0.1.3 shipped unsigned). The core
version string stays `core 0.1.0` (the shipped pattern since 0.1.0; the
pin and hash in the same string name v0.28.0). Then: apply the patch,
commit, push the tag, upload both assets, compare the downloads with the
SHA-256 values above, move main, and run the post-publish consumer smoke
(release.md step 6). Recommended with it: a short warning on the 0.1.3
release page (Release builds can trap when a handler throws; use 0.1.4).
No tag, release asset or publication exists yet.
