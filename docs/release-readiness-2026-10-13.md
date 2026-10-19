# Next release proposal — 2026-10-13

> Superseded on 2026-10-18 by [release-readiness-2026-10-18.md](release-readiness-2026-10-18.md):
> the owner chose to fold the capnp-zig v0.27.0 core into 0.1.2. This sheet
> keeps its 2026-10-13 evidence unchanged.

**Proposed version: 0.1.2, pending owner approval.** The real app integration
sprint and its demonstrated TLS repair are complete. Published 0.1.1 remains
immutable. This proposal keeps typed generation and QUIC Experimental.

**What would ship:** main's additive typed generics, pipelines and streaming;
serialization/codegen repairs recorded in the changelog; QUIC client
single-start and TLS graceful-shutdown fixes; the native Mac/iPhone RPC
Workbench example and expanded consumer CI gates.

**Artifacts:** reuse the verified universal codegen candidate from `75f2bb5`
(SHA-256 `8c241efe29b2e6df29ad02e6c7209687de08d5d439bb632f9ecadecd72eac10a`).
Generator/driver/bundle inputs still match main; no codegen rebuild is needed.
Keep `Package.swift` on the existing 0.1.1 core URL/checksum
`750f53096f825ba211607b27adcbdd6216e487b1f6c03b0b11135427af975340`.
Core stays 0.1.0 / ABI 1; core/generator pin v0.23.0, interop peer v0.21.0.
The Swift-only changes require no new core binary or local XCFramework build.
The proposed codegen copy is staged locally at
`dist/0.1.2-capnpc-swift.artifactbundle.zip` with the same candidate hash;
`dist/0.1.2-release-notes.txt` is an unpublished draft. These ignored local
files do not replace either published asset.

| Evidence | Scope |
|---|---|
| TLS repair `d72c407` | [Hosted CI 38357935250](https://github.com/nullstyle/capnp-swift/actions/runs/38357935250): four lanes passed; normal/TSan/ASan each 72 tests. |
| Final sample source `c5fdf1d` | [CI 38363670703](https://github.com/nullstyle/capnp-swift/actions/runs/38363670703): all four lanes passed; normal/TSan/ASan each 72 Swift tests and 84 typed checks; sample and renamed-archive gates each 21 checks; native Mac/iOS builds passed. |
| Real consumer | 21 TCP/TLS checks, two test functions / three network cases; eleven semantic, five selection and two generation-drift failures checked and restored. |
| Renamed clean archive | `c5fdf1d`: all 21 TCP/TLS checks pass using the exact released remote core. Both archive count and remote-core guards were failed by name and restored. |
| Native apps | Mac and iPhone simulator passed seven RPC checks. Physical iPhone passed seven over TCP and seven over TLS against the Mac. [Exact scopes](../Examples/RPCWorkbench/VALIDATION.md). |
| Current runtime nightly | [38359897878](https://github.com/nullstyle/capnp-swift/actions/runs/38359897878), `d72c407`: all five lanes passed; simulator 70 tests; 1800 s fuzz, 3,851,980 sessions / 337,258,277 operations, zero live bytes. Runtime/core/generator/test/interop/script/nightly inputs match the subsequent sample commits. |

Exact source comparisons, hosted log identities and native results are
retained in `dist/capnpc-swift-main-75f2bb5.provenance.json` and
`Examples/RPCWorkbench/evidence/results.json`. The final documentation
follow-up changes only these records and Markdown; tested runtime, generator
and example sources remain identical to `c5fdf1d`.

**Known boundaries:** QUIC's hosted SDK teardown trap is unfixed, unreported
and closed by owner decision. Native H9, lookup-only H12, C++ promise/tail-call
and QUIC close/H11 residuals remain documented limits. Physical OS
background/foreground and Wi-Fi-only routing are unverified; lifecycle is
verified on local TCP/TLS sockets. No new promise of minimum-OS runtime testing.

**Before publication:** owner selects the version and signing policy. Gates
are verified on the exact source revisions above; later release-commit edits
must preserve that tested source or rerun affected gates. Publish only after
explicit approval, then verify a
fresh remote-tag consumer and announce. No tag, release asset or publication
has been created during these sprints.
