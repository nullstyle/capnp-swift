# Next release proposal — 2026-10-19

**Proposed version: 0.1.3, pending owner approval of the tag and the
uploads.** The owner asked for this proposal on 2026-10-19 (option "prepare
0.1.3 now", before capnp-zig ships the cancel signal of H13). Published
0.1.2 stays immutable. Typed generation and QUIC stay Experimental.

**What would ship** (everything on main after the 0.1.2 tag; plan §8
"M8 status" and "M9 status"):

- A Stable API fix, with additive API: a capability of ours that comes
  back (`CapTableEntry.exported`) stays callable after the remote releases
  it. New `CallResult.localHandler(forExport:)` and
  `InboundCall.localHandler(forExport:)`; inside a handler,
  `RPCConnection.localHandler(forExport:)` also resolves the current
  call's own exports, so generated servers need no new code.
- Interop coverage: the `pass_back` and `pipelined_params` scenarios on
  every lane (M8), the regenerated `game_world` e2e bindings, and a
  pair-script retry for the port race.
- Guardrails: a Stable Swift API gate in CI, a manual iOS 18 floor
  workflow, and the documented toolchain floor (Swift 6.3).
- No core change: the core is the 0.1.2 binary (`core 0.1.0 / capnp-zig
  0.27.0`). No generator change.

**Release commit:** current main with `dist/0.1.3-Package.swift.patch`
applied (release.md step 3): the CapnpCore URL moves to the 0.1.3
download, the checksum stays. Commit the patch only with the upload:
until then the URL does not exist. That commit also moves the API gate's
baseline to 0.1.3; `scripts/api-breakage-allowlist.txt` is empty.

| Asset | SHA-256 | Source |
|---|---|---|
| `CapnpCore.xcframework.zip` | `203fbdd4ef00554f278e9730431b09d1d0a117cc731e29a7e496b73fe6fbd98b` | The 0.1.2 core asset, byte-identical (compared with the live 0.1.2 download). `core/` is unchanged since `79e733e`, its source. |
| `capnpc-swift.artifactbundle.zip` | `8c241efe29b2e6df29ad02e6c7209687de08d5d439bb632f9ecadecd72eac10a` | The 0.1.2 codegen asset, byte-identical (live download compared); built from clean `75f2bb5`. |

Staged (gitignored) in the worktree `.claude/worktrees/capnp-zig-0-27-61005f/dist/`:
`0.1.3-CapnpCore.xcframework.zip`, `0.1.3-capnpc-swift.artifactbundle.zip`,
`0.1.3-Package.swift.patch` and the notes draft `0.1.3-release-notes.txt`.

**Codegen candidate:** its 147-entry source manifest differs from
`75f2bb5` in two entries: `core/build.zig.zon` (the core pin) and
`Package.swift` (only the CapnpCore URL/checksum lines and their comment).
No bundle build step reads either: the driver links only WasmKit, and the
plugin has its own v0.23.0 pin. `scripts/check-codegen-bundle.sh` on the
unzipped staged bundle passes on current main.

| Evidence | Scope |
|---|---|
| [CI 39206924110](https://github.com/nullstyle/capnp-swift/actions/runs/39206924110), `631b94b` | All four jobs: normal, TSan and ASan 75 tests each; the API gate (no breaking change against 0.1.2); the Workbench gate and the renamed-archive gate, 21 checks each; the native Mac app build; the unsigned iOS device build. |
| [Nightly 39213688224](https://github.com/nullstyle/capnp-swift/actions/runs/39213688224), `631b94b` | All five lanes: 1800 s fuzz (3,790,032 sessions, 0 live); the Zig matrix over TCP and Unix; the C++ reference on seven schemas both ways (52, and 122 + 2 known); the QUIC lanes with the 90 s idle gate and the QUIC matrix 14/14 pairings; the simulator, 73 tests across the selections. |
| [Floor 39206940367](https://github.com/nullstyle/capnp-swift/actions/runs/39206940367), `631b94b` | iOS 18.6 simulator: network 9, QUIC 3 (two skip: "Requires iOS 26.0"), runtime 51, conformance 9, the 64 x 10k stress test. |
| The exact core zip on current main (`b18d807`, local) | Unzipped in place of the development build: `swift test` 66 + 9, mvp 4/4, QUIC Swift→Zig 6/6, C++ 52 and 122 + 2 known, Zig 52 and 55, QUIC matrix 14/14, API gate clean, `check-symbols --strict`. |
| Native apps (M9 G8) | Mac 7/7 over TCP and TLS; iPhone 17 Pro simulator (iOS 27.0) 7/7 over each, on the same core binary (`Examples/RPCWorkbench/VALIDATION.md`). |

`b18d807` and this proposal change documentation only after `631b94b`.

**Known boundaries:** a caller's cancel does not stop a Swift handler yet
(handoff H13, waiting for capnp-zig). Native H9 for pending answers and
lookup-only H12 stay deferred upstream; `pipelined_params` lines are
listed known limits. Tail-call results that carry capabilities end with an
`unimplemented` exception. QUIC's hosted SDK teardown trap is unfixed by
owner decision. The toolchain floor is Swift 6.3; the macOS 15 runtime is
not run (GitHub has no Swift 6.3 on macOS 15). Physical OS
background/foreground and Wi-Fi-only routing stay unverified; no physical
iPhone run on this core.

**Before publication:** the owner approves the tag `0.1.3` and the two
uploads, and the signing policy (0.1.0 to 0.1.2 shipped unsigned). The
core version string stays `core 0.1.0` (the binary is unchanged). Then:
apply the patch, commit, push the tag, upload both assets, compare the
downloads with the SHA-256 values above, move main, and run the
post-publish consumer smoke (release.md step 6). No tag, release asset or
publication exists yet.
