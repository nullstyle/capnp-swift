# Stability in 0.1.x

What the 0.1 releases promise, and what they do not. "Stable" below means: breaking
changes only in a new minor version (pre-1.0 SemVer: a breaking change
bumps the minor, not the patch).

## Stable

CI enforces the Swift part of this list: `scripts/check-api-breakage.sh`
fails on a breaking change to `Capnp`, `CapnpRPC` or `CapnpNW` since the
last release. A change to Experimental API there is allowed only by its
exact message in `scripts/api-breakage-allowlist.txt`.

- **The wire protocol.** Standard Cap'n Proto RPC (two-party vat
  protocol) on every transport. The TCP/Unix framing is the standalone
  segment table; the QUIC baseline framing is frozen (ALPN
  `capnp-rpc/1`, client stream 0, u32 little-endian length prefix per
  frame, application close codes 0 and `0x434e5001..04`).
- **The C ABI** (`core/include/capnp_core.h`, ABI version 1). Additive
  changes only: option and effect structs are `struct_size`-versioned, so
  a newer core reads an older host's prefix and an older header works
  against a newer core. Nothing already exported is removed or re-shaped.
- **The `Capnp` module** — message decoding/encoding (multi-segment,
  packed), struct/list/text readers and builders, XOR'd defaults. The
  in-memory layout rules follow the Cap'n Proto spec.
- **The `CapnpRPC` runtime** — `RPCConnection` (connect, bootstrap, call,
  pipeline, finish/release, shutdown, events, limits, backpressure),
  `Transport`, `CapRef`, `RemotePromise`, the export model
  (`ExportHandler`), streaming wrappers, the lifecycle policy.
- **The `CapnpNW` transports** — TCP, Unix sockets, TLS
  (`TLSIdentity`, including the raw-DER initializer; DER pinning through
  `TLSTrust`), `RPCListener`/`RPCListener`-shaped accept loops.
- **Schema compatibility** — schemas evolve per the Cap'n Proto rules
  (new fields, ordinals); old readers see defaults.

## Experimental

- **Open typed generation** (`--typed` on main): `CapnpPointerSchema`,
  `PointerReader`/`PointerBuilder`, `RPCPointerCapability`, and the generated
  `.Typed`/`.TypedServer` interface, pending result pipelines and typed streams.
  Use a matching generator and runtime;
  its Swift surface may change before stabilization. Existing erased
  generation stays available. See [typed-generics.md](typed-generics.md).
- **`CapnpNW` QUIC** (`QUICTransport`, `QUICListener`): needs
  macOS 26 / iOS 26 (Network.framework's modern QUIC API) and is
  Experimental in capnp-zig as well. The WIRE shape is frozen (above);
  the Swift surface may change. Hosted Xcode 26.6 / macOS SDK 26.5 runs
  intermittently trap during Network.framework teardown with
  `Neither nw nor nwGroup is initialized`. The client single-start fix
  does not cure this SDK race. It remains unfixed and was not reported to
  Apple, by owner decision on 2026-10-12. The investigation is closed;
  [the evidence](handoffs/apple-network-quic-teardown-race.md) is local
  reference only. Local Xcode 27 passes do not establish older SDK behavior.
  Since the v0.27.0 core, the end of stream 0 ends the RPC session in
  both directions: a clean FIN (cause `peer_close`) or a reset
  (`transport_error`). The transports end stream 0 only when they close.
- **The pinned capnp-zig Peer** (`-Dfd-passing=false`): v0.28.0 since
  0.1.4 (0.1.2 and 0.1.3 carried v0.27.0, 0.1.1 v0.23.0). Its sans-IO surface is
  Experimental upstream, which is why the pin is exact and each release
  reports it in `capnp_core_version()`. Since v0.27.0 the core follows a
  tail call (`takeFromOtherQuestion`) to a call this side has not answered
  yet. Tail-call results that carry capabilities still end the question
  with an `unimplemented` exception.

## Not in 0.1.x

FD passing, three-party vats, persistence, WebSocket transport, QUIC
native mode, Mac Catalyst / visionOS slices.

## Notes

- **Toolchain and platform floor**: Swift 6.3 or later (the codegen
  plugin's WasmKit dependency declares tools version 6.3; Swift 6.2 cannot
  resolve the package). The iOS 18 floor runs in the manual `floor`
  workflow (iOS 18.6 simulator; first pass on 2026-10-18). The macOS 15
  runtime is not run: GitHub's macOS 15 runners have no Swift 6.3.

- **Generated code is a build artifact.** `capnpc-swift` output may look
  different across compiler releases; regenerate rather than hand-edit
  (`just generate`). The API SHAPE the generated code uses (readers,
  builders, `Client`/`Server`/`Export`) is stable.
- **Errors are sanitized at the boundary**: a remote never sees local
  failure detail, only the generic reason (M2 gate).
- **iOS**: add `NSLocalNetworkUsageDescription` to any app that listens
  (clients dialing loopback do not need it); `PrivacyInfo.xcprivacy` ships
  in `CapnpRPC` and the XCFramework.
