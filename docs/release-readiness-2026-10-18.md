# Release 0.1.2 — proposal and publication, 2026-10-18

> **Published 2026-10-18** as [0.1.2](https://github.com/nullstyle/capnp-swift/releases/tag/0.1.2)
> at `69e392e342fd4fa9ed741c68327fc31c5148e632` (owner approved: tag and
> both assets, unsigned). Both downloaded assets match the SHA-256 values
> below. Post-publish smoke: a fresh consumer with an isolated SwiftPM
> cache resolved tag 0.1.2 at `69e392e`, downloaded the release core by
> URL and checksum, built for macOS, iOS device (unsigned) and iOS
> simulator, printed `core 0.1.0 / capnp-zig 0.27.0 / capnpc_zig-0.27.0-nUduFW1…`,
> and completed a TCP bootstrap and close against the v0.21.0 zig-peer.
> The downloaded codegen bundle passes `scripts/check-codegen-bundle.sh`.
> Release-commit CI: [39195835543](https://github.com/nullstyle/capnp-swift/actions/runs/39195835543): core, sanitizers and ios passed; swift passed its 73 tests and the workbench check, then failed the workbench archive gate, which hard-coded the 0.1.1 core URL. The gate now reads the released core from the archived `Package.swift` (`67eb725`, on main after the tag); [CI 39197265828](https://github.com/nullstyle/capnp-swift/actions/runs/39197265828) passed all four lanes, incl. the archive gate on the 0.1.2 core. The text below is the proposal as approved.

**Proposed version: 0.1.2, pending owner approval of the tag and the
uploads.** On 2026-10-18 the owner chose to fold the capnp-zig v0.27.0 core
into 0.1.2. This sheet replaces the [2026-10-13 sheet](release-readiness-2026-10-13.md),
which proposed 0.1.2 on the v0.23.0 core. Published 0.1.1 stays immutable.
Typed generation and QUIC stay Experimental.

**What would ship:** everything the 2026-10-13 sheet lists (typed generics,
pipelines and streaming; the serialization/codegen repairs; the QUIC client
single-start and TLS graceful-shutdown fixes; the native RPC Workbench and
its consumer gates), plus:

- the capnp-zig v0.27.0 core: tail calls from the C++ reference work, and a
  QUIC session ends when the peer ends stream 0 (H11 check 9);
- QUIC transports that send frames, and the end of stream 0, in order.

**Release commit:** current main (`fdb1be4` plus this documentation) with
`dist/0.1.2-Package.swift.patch` applied (the url + checksum flip,
release.md step 3). Do not commit the patch before the upload: until then
the URL does not exist. After `79e733e`, `ab99623` and `fdb1be4` change only
a test, CI scripts and the CHANGELOG; `core/` is identical, so the staged
core asset stays valid.

| Asset | SHA-256 | Source |
|---|---|---|
| `CapnpCore.xcframework.zip` (new) | `203fbdd4ef00554f278e9730431b09d1d0a117cc731e29a7e496b73fe6fbd98b` | main `79e733e`, `scripts/make-release-xcframework.sh --verify`: neutral paths, two builds with identical public surfaces. Every slice reports `core 0.1.0 / capnp-zig 0.27.0 / capnpc_zig-0.27.0-nUduFW1…`. |
| `capnpc-swift.artifactbundle.zip` (unchanged candidate) | `8c241efe29b2e6df29ad02e6c7209687de08d5d439bb632f9ecadecd72eac10a` | clean `75f2bb5`. |

Slice SHA-256 (the `.a` files in the zip): macOS
`af412245a51f903bcfacc5688ebe32ed6650e3a7bc678ed1061e36d1685b9a60`,
ios-arm64 `007f061b8661b06921efd0e82e62bb40fda72de4d0b9a8c921cf821396a5cab6`,
simulator `fe190ce201b178b5e47f45d179c0baae7067dbcacc11ecfeea3b98ddb3c1bb53`.

Staged copies (gitignored): the worktree
`.claude/worktrees/capnp-zig-0-27-61005f/dist/` holds both zips, the patch
and the draft notes (`0.1.2-release-notes.txt`). The main checkout's
`dist/` holds identical copies of the core zip
(`0.1.2-CapnpCore.xcframework.zip`) and the patch. Its older
`0.1.2-release-notes.txt` is the superseded 2026-10-13 draft. Zig 0.17
builds are not bit-reproducible: upload exactly this zip, or rebuild and
recompute the checksum and the patch.

**Codegen candidate:** the 147-entry source manifest
(`tools`, `Plugins`, `core`, `Package.*`, `mise.toml`, the two bundle
scripts) differs from `75f2bb5` in one entry only, `core/build.zig.zon` (the
core pin). No bundle build step reads it: the driver links only WasmKit, and
the plugin keeps its own v0.23.0 pin. `scripts/check-codegen-bundle.sh` on
the unzipped candidate passes on `79e733e` (MVP regeneration identical;
typed module imports checked). No codegen rebuild is needed.

| Evidence | Scope |
|---|---|
| Local gates on `79e733e` | Plan §8 "capnp-zig v0.27.0 adoption": core 18/18 + test-abi 18/18; swift test, TSan, ASan 64 + 9 each; iOS simulator 62 + 9 and device build; Zig, Swift/Swift and C++ matrices on TCP and Unix (C++ all five schemas both ways); QUIC lanes, 90 s idle gate and the H11 matrix 10/10; strict symbols; dSYM; typed C++ checks; fuzz 1800 s, 0 live. |
| The release framework itself | The unzipped release XCFramework in place of the dev build: swift test 64 + 9, mvp 4/4, QUIC Swift→Zig 6/6, C++ 42 and 117 checks, H11 10/10, `check-symbols --strict` OK. |
| Hosted CI | All four lanes passed on `79e733e` ([39189292648](https://github.com/nullstyle/capnp-swift/actions/runs/39189292648); normal, TSan and ASan 73 tests each), `ab99623` ([39191043354](https://github.com/nullstyle/capnp-swift/actions/runs/39191043354)) and `fdb1be4` ([39192848274](https://github.com/nullstyle/capnp-swift/actions/runs/39192848274)). |
| First nightly, `79e733e` | [39189320930](https://github.com/nullstyle/capnp-swift/actions/runs/39189320930): fuzz, matrix and C++ passed (C++ all five schemas both ways: 117 and 42 checks). Two lanes failed, both test-harness faults: `ios-sim` (the new QUIC E-order load starved one QUIC round trip; fixed in `ab99623`) and `quic` (the QUIC pair script called `timeout`, which runners lack; every pairing exited 127; fixed in `fdb1be4`). |
| Simulator-only nightly, `ab99623` | [39191061887](https://github.com/nullstyle/capnp-swift/actions/runs/39191061887): passed; the checker counts 71 tests across all selections. |
| Full nightly, `fdb1be4` | [39192848295](https://github.com/nullstyle/capnp-swift/actions/runs/39192848295): all five lanes passed. 1800 s fuzz: 4,070,931 sessions, 356,128,459 ops, 0 live. QUIC lanes incl. the 90 s idle gate and the H11 matrix 10/10 (check 9 passes); simulator 71 tests; C++ all five schemas both ways. |
| Native apps | Unchanged since the 2026-10-13 sheet; they use the released 0.1.1 core and were not rerun against the new core. |

**Known boundaries:** QUIC's hosted SDK teardown trap is unfixed,
unreported and closed by owner decision. Native H9 for pending answers and
lookup-only H12 remain documented limits (deferred upstream). Tail-call
results that carry capabilities end with an `unimplemented` exception.
Physical OS background/foreground and Wi-Fi-only routing are unverified.

**Before publication:** the owner approves the tag and the two uploads and
picks the signing policy (0.1.0 and 0.1.1 shipped unsigned). The core version
string stays `core 0.1.0`, as for 0.1.1 (only the pin changed); say so if
you want a core version bump instead. Then: apply the patch, commit, tag
that commit `0.1.2`, upload both assets, and run the post-publish consumer
smoke (release.md step 6). No tag, release asset or publication exists yet.
