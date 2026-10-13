# Real app integration sprint — 2026-10-12

Owner selected the recommended sequence: real app integration, targeted
repairs/polish from its findings, then preparation of a new release.
Publication remains a separate owner decision. The closed Apple SDK
teardown investigation is outside this sequence.

## Current sprint

Build `Examples/RPCWorkbench`: a native SwiftUI Mac host/client and iPhone
client, plus a shared Swift package, checked generated schemas and reusable
network verification. The consumer links the unchanged released core URL
and checksum. No upstream checkout or core rebuild is required.

- Typed calls and an open generic application across separate Swift modules.
- A capability pipeline sent before the factory result returns.
- A server call back into a client-owned capability.
- Streaming acknowledgement and a final receipt proving count/content.
- Local request cancellation followed by a successful call on the same connection.
- Background suspension, foreground reconnect, disconnect and manual reconnect.
- TCP and explicitly pinned sample TLS; wrong pins must fail.
- Native Mac launch and iPhone simulator install/run; physical iPhone check
  when the paired device becomes available.

New gate assertions must be independently failed by name and restored.
Record actual build, simulator and device evidence separately. A build or
simulator run does not close the physical-device check.

## Follow-up sprints

Repair only demonstrated defects; record each diagnosis, meaningful change
and appropriate regression/sanitizer evidence separately. Then choose a new
release version with the owner, prepare matching runtime/generator artifacts,
run the final release gates, and present the release for publication approval.

## Status

Implementation complete. The [native example](../Examples/RPCWorkbench/README.md)
has an editable Xcode project, shared Mac/iOS sources, separate schema modules,
local signing configuration and a checked network gate. Both candidate-bundle
and locally built compiler paths pass generation/check mode. Two test functions
cover three network cases; CLI passes 21 assertions. All eleven distinct
assertions were individually failed by name, rebuilt and exactly restored.

The Mac app and iPhone simulator each passed seven native RPC checks. A
signed build installed and ran on physical iPhone `Oranga`; it passed seven
checks over TCP and seven over TLS against the Mac. Reports were retrieved
before the owner took the phone to bed. No further phone access is needed.
Physical OS background/foreground and Wi-Fi-only routing checks remain
explicitly unverified; the lifecycle path is tested over actual local sockets.
[Validation](../Examples/RPCWorkbench/VALIDATION.md) records exact scopes,
binary identity and the simulator image. Mac visual capture was unavailable;
native app runtime evidence is retained separately.

The sample exposed an actual TLS graceful-shutdown defect. Separate production
repair `d72c407` defers the TLS close callback until the borrowed core effect
commits. An idle connection reproduced the old trap twice. Both new regression
assertions were failed/restored; normal, TSan and ASan each pass all 72 tests.
The ordinary hosted CI run is recorded in the plan; no SDK reproduction loop
was dispatched. The sample setup also now supplies the standard streaming
schema include path when running a locally built compiler.

CI adds the 21-check sample gate and native Mac/iOS app builds. Release
preparation follows these gates. Candidate codegen bytes and the published
0.1.1 core remain unchanged; a new package version and publication still need
the owner.

The scheduled [nightly 38359897878](https://github.com/nullstyle/capnp-swift/actions/runs/38359897878)
passed all five lanes at `d72c407`: 70 simulator tests and 1800 seconds of
ABI fuzz (3,851,980 sessions, 337,258,277 operations, zero live bytes at exit).
The later sample commits preserve every runtime/core/generator/test/interop
and nightly-script input plus the existing Just recipes. This is recorded
source equivalence, with the nightly's actual revision retained.

The renamed clean-archive consumer passes all 21 checks at `c5fdf1d` using
the released remote core. The [proposed 0.1.2 readiness sheet](release-readiness-2026-10-13.md)
assembles artifacts, exact validation scope and remaining owner choices.
No publication was performed.

[Final CI 38363670703](https://github.com/nullstyle/capnp-swift/actions/runs/38363670703)
passed all four lanes at `c5fdf1d`. Logs retain 72 Swift tests and 84 typed
checks per normal/TSan/ASan mode, both 21-check consumer gates and successful
native Mac/iOS builds. The following evidence update changes documentation
and JSON records only.
