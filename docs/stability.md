# Stability in 0.1.0

What 0.1.0 promises, and what it does not. "Stable" below means: breaking
changes only in a new minor version (pre-1.0 SemVer: a breaking change
bumps the minor, not the patch).

## Stable

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

- **`CapnpNW` QUIC** (`QUICTransport`, `QUICListener`): needs
  macOS 26 / iOS 26 (Network.framework's modern QUIC API) and is
  Experimental in capnp-zig as well. The WIRE shape is frozen (above);
  the Swift surface may change.
- **The pinned capnp-zig Peer** (v0.21.0, `-Dfd-passing=false`): its
  sans-IO surface is Experimental upstream, which is why the pin is
  exact and each release reports it in `capnp_core_version()`.

## Not in 0.1.0

FD passing, three-party vats, persistence, WebSocket transport, QUIC
native mode, Mac Catalyst / visionOS slices.

## Notes

- **Generated code is a build artifact.** `capnpc-swift` output may look
  different across compiler releases; regenerate rather than hand-edit
  (`just generate`). The API SHAPE the generated code uses (readers,
  builders, `Client`/`Server`/`Export`) is stable.
- **Errors are sanitized at the boundary**: a remote never sees local
  failure detail, only the generic reason (M2 gate).
- **iOS**: add `NSLocalNetworkUsageDescription` to any app that listens
  (clients dialing loopback do not need it); `PrivacyInfo.xcprivacy` ships
  in `CapnpRPC` and the XCFramework.
