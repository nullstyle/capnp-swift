# 0.1.1 baseline and main candidate readiness — 2026-10-12

**Ready for owner review.** [0.1.1 is already published](https://github.com/nullstyle/capnp-swift/releases/tag/0.1.1)
at `808a904` (2026-10-10); its tag and assets remain immutable. This newer
candidate includes Experimental open typed generation, pipelines and streaming
for main `b19b7fe1c076624384ffcf14747592f96f6033a9` and a future release.

**Candidate:** `dist/capnpc-swift-main-75f2bb5.artifactbundle.zip`, built from
a clean archive of `75f2bb58a45b4994ca6472dbd56e5ba22b645c12`, arm64/x86_64.
SHA-256: `8c241efe29b2e6df29ad02e6c7209687de08d5d439bb632f9ecadecd72eac10a`.
[Provenance](../dist/capnpc-swift-main-75f2bb5.provenance.json) records 147
identical build-input entries at `75f2bb5`, `49b2a32` and `b19b7fe`, excluding
one CI-verified test-harness change. Later production changes affect only
QUIC client startup. The generator candidate needs no rebuild.

| Evidence | Result and source |
|---|---|
| Core, generated APIs, header, strict symbols, dSYM | [CI 38342150160](https://github.com/nullstyle/capnp-swift/actions/runs/38342150160), `bb83c7c`: pass; `b19b7fe` adds docs only. |
| Swift / TSan / ASan | Same CI: 71 Swift tests + 84 typed RPC checks in each mode; no sanitizer findings. |
| iOS device build | Same CI: unsigned build passed; no physical-device runtime claim. |
| Simulator / TCP / Unix / C++ / QUIC / idle | [Nightly 38331434192](https://github.com/nullstyle/capnp-swift/actions/runs/38331434192), `75f2bb5`: all five lanes passed; simulator 69 tests. This precedes the QUIC startup fix. |
| ABI fuzz | Same nightly: 1800 s, 4,334,929 sessions, 379,375,573 operations; zero live bytes at exit. |
| Exact candidate / fresh HEAD consumer | ZIP hashes, universal architectures and extracted smoke pass. Two generated modules checked; four public runtime assertions pass with the released core URL/checksum. Original four assertion ablations remain recorded. |

**What's left:** H7 native move, v0.23.0 core pin, header/version/URL update,
artifact builds, publication and published consumer smoke are done. Typed
adoption is complete on main. Core stays 0.1.0 / ABI 1; generator/core pin
v0.23.0; independent interop peer stays v0.21.0. Native H9 uses awaited
materialization; H12 uses full-node contexts. C++ resolve/tail-call and QUIC
server-close/H11 residuals remain documented limits; further native effects
stay future ABI work. Signing stays with the owner.

**Known defect:** QUIC remains Experimental. Hosted Xcode 26.6 / SDK 26.5
has an intermittent Network.framework teardown trap. It is unfixed, was not
reported, and is closed on our side by owner decision (2026-10-12).
[Evidence is local reference only](handoffs/apple-network-quic-teardown-race.md).
Manual reproduction failures are expected; local Xcode 27 passes do not prove
older SDK behavior.

**Owner choices:** keep the candidate staged, or select a new version and
authorize its release ceremony (including signing choice and final gates on
that release commit). This review performs no tagging, asset upload or publication.
