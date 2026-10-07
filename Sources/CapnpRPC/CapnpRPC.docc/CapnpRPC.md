# ``CapnpRPC``

Cap'n Proto RPC for Swift: a sans-IO connection core (linked from
`CapnpCore`) driven by an actor-based Swift runtime.

## Overview

An `RPCConnection` pairs a `Transport` (from `CapnpNW`: TCP, Unix
sockets, TLS, QUIC) with the core. Calls flow through
`RemotePromise`s; capabilities cross the wire as `CapRef`s; servers
export `ExportHandler`s (generated `Server` conformances wrap them).

- Version and pin: `CapnpCoreInfo.version` (`capnp_core_version()`).
- Stability: see `docs/stability.md` in the repository.

## Topics

### Connections
- ``RPCConnection``
- ``RPCError``

### Capabilities
- ``CapRef``
- ``RemotePromise``
