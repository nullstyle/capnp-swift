# Validation — RPC Workbench

## Verified

- Local Xcode 27.0 / Swift 6.4, macOS SDK 27.0; released core 0.1.0 / ABI 1,
  capnp-zig v0.23.0. Core URL/checksum unchanged; no local core substitution.
- Generation and `--check` passed for both separate schema modules.
- Two Swift Testing functions with three actual network cases passed.
- CLI passed 21 checks: ten over TCP, ten over explicitly pinned sample TLS,
  and one wrong-pin rejection. This includes lifecycle suspension/reconnect.
- Eleven distinct RPC/network assertions were independently inverted, rebuilt,
  failed by name and byte-restored; each restored run passed all 21 checks.
- Five selection/count guards failed with their intended names; both generated
  modules rejected deliberately drifted scratch outputs and passed after restoration.
- Signed macOS app built, launched and hosted both listeners. Its native
  client passed seven RPC checks over TCP. Mac visual inspection was unavailable
  because the computer-use bridge closed before returning UI state.
- iPhone 18 Pro simulator on iOS 27 passed seven native app checks over TCP
  and seven over sample TLS. The final restored source was rebuilt before
  installation. Its [screen](evidence/simulator.png) visibly shows the native
  controls and seven passing checks.
- Signed iOS device build installed and launched on **Oranga**, a physical
  iPhone 17 Pro running iOS 27.0.1 with Developer Mode enabled. The phone
  app passed all seven checks over TCP and all seven over pinned sample TLS,
  using host `m5roscoe.local`. Each report was copied from this app's own
  data container before the phone was released to the owner.

Phone executable SHA-256:
`c611cdbb34124539907c342514cb8c2236fd3061ce276da7d2d7172ad891d9f7`.
The recorded device run predates small app preference/reporting polish;
no further phone access is needed for this sprint. No physical background /
foreground or Wi-Fi-only routing claim is made. Background/reconnect is
verified through the same lifecycle policy on actual TCP/TLS sockets locally.

## Integration finding

TLS `shutdown()` originally trapped at `RPCConnection.drain()` with
`capnp_conn_next_effect returned -3`. An idle TLS connection alone reproduced
it twice. LLDB showed an inline close notification reentering the drain
before its `CLOSE_REQUESTED` effect committed. Production repair `d72c407`
queues that notification on the existing connection queue.

The focused regression passes; both new assertion guards failed by name and
passed after restoration. Full normal, TSan and ASan each passed 63 RPC +
9 conformance tests. Both sanitizer bundles' actual linkage was verified.
This finding is independent of the closed QUIC SDK defect.

[Hosted CI 38357935250](https://github.com/nullstyle/capnp-swift/actions/runs/38357935250)
passed all four lanes at `d72c407`; normal/TSan/ASan each passed 72 tests.
The native sample's expanded CI gates are a subsequent commit.

[Expanded CI 38360495998](https://github.com/nullstyle/capnp-swift/actions/runs/38360495998)
passed all four lanes at `53aac84`, including the sample's network gate and
native Mac/iOS builds. A clean archive check then found a dependence on the
checkout directory's name. Naming the local package explicitly makes the
renamed archive compile and pass all 21 checks with the released remote core.
Both archive selection and core-source guards failed by name and restored.

[Final CI 38363670703](https://github.com/nullstyle/capnp-swift/actions/runs/38363670703)
passed all four lanes at `c5fdf1d`: each full Swift mode passes 72 tests,
each typed mode passes 84 checks, both sample and renamed-archive gates pass
21 checks, and native Mac/iOS builds succeed. The scheduled
[nightly 38359897878](https://github.com/nullstyle/capnp-swift/actions/runs/38359897878)
passed five lanes at `d72c407`, including 70 simulator tests and 1800 seconds
of ABI fuzz with zero live bytes at exit. Runtime and existing nightly gate
sources are byte-identical across the subsequent sample commits; the actual
nightly revision remains recorded.

## Evidence

Local files may expire. The checked-in [evidence manifest](evidence/results.json)
retains result contents, binary/log identities and source provenance.

- `/tmp/capnp-workbench-phone-{tcp,tls}-result.json`: seven checks in each mode.
- `/tmp/capnp-workbench-phone-{install,tcp-launch,tls-launch}.json`:
  successful app installation and launches; no other phone data was read.
- `/tmp/capnp-workbench-check.aEEKXO/{tests,smoke}.log`: network gate.
- `/tmp/capnp-workbench-ablations-5lv9khkx/results.json`: eleven ablations.
- `/tmp/capnp-tls-shutdown-{full-normal,tsan,asan}.log`: full repair suites.

Simulator runtime results and the final macOS build are recorded in the
manifest. The default local-tool setup path also passes the full network gate;
it explicitly supplies the standard compiler include tree for streaming schemas.
