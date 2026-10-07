# H11 — The 5-schema QUIC matrix (M6 remainder, filed 2026-10-07)

## Status

Filed, not started. The M6 gate row reads "Swift↔Zig both ways pass `mvp`
+ the 5 schemas"; the `mvp` half is done (both directions, TAP-gated —
plan §8 "M6 status"). This file is what the 5-schema half needs.

## Why it is blocked here

The M4 matrix pairs `e2e-swift-server`/`e2e-swift-client` with capnp-zig's
own `e2e-zig-server`/`e2e-zig-client` over TCP
(`just e2e-matrix` → `scripts/e2e-pair.sh`). Those zig drivers live in
capnp-zig at `tests/e2e/zig/main_{server,client}.zig` (2093 + 1216 lines)
and speak TCP only. capnp-swift's working rules forbid editing capnp-zig —
changes there become handoff files, like this one.

## Options, in preference order

1. **Upstream (preferred): a `--transport quic` mode on capnp-zig's e2e
   drivers.** The work is exactly what interop/zig-peer now does:
   `rpc.transport.quic.PeerServer` behind the existing per-schema handler
   tables (`ServerOptions{listen_addr, tls_cert_pem, tls_key_pem}`, idle
   raised for the 90 s gate), and `Connection.initClient` + hand-wired
   `Peer` on the client (NOT `ClientSession.connect`: it `peer.start()`s
   on the calling thread and the peer stays thread-affine to it — the
   bench's `disableThreadAffinity()` must come BEFORE `start`, which
   ClientSession does not allow; see interop/zig-peer/src/main.zig
   `runQuicClient` for the working shape). A `quic` server/client pair of
   e2e drivers upstream would also serve capnp-zig's own matrix.
2. **Local: copy the drivers.** Vendor the two main files into
   interop/ (they import their generated bindings from
   `tests/e2e/zig/generated/`, which must come too) and add QUIC modes in
   the copies. ~3.3k lines of duplicated driver code to keep in sync with
   the pinned tag — acceptable only if upstream declines.
3. **Defer past 0.1.0.** The mvp matrix already exercises every wire
   behavior the 5-schema set would (calls both ways, capabilities,
   exceptions, three-level payload trees); the schemas add coverage, not
   new transport semantics.

## What the Swift side already has

`e2e-swift-server` serves over TCP only today; adding a QUIC front door is
mechanical once a zig 5-schema QUIC peer exists:
`QUICListener(port:identity:bootstrap:)` + the same schema dispatch
(`Options.framing = .u32LE`, the fixture identity from
`TLSIdentity(certificateDER:keyDER:)`; see `mvp-e2e --serve-quic`).

## Wire facts the drivers must honor (frozen, H3)

ALPN "capnp-rpc/1"; client stream 0 carries every frame as u32 LE length
prefix + standalone segment-table bytes; a second stream is reset with
0x434e5002 and the connection stays up; close code 0 is normal; idle
timeouts must exceed the 90 s gate on both ends (zig:
`max_idle_timeout_ms` in `transport_params`; Swift:
`QUICTransport(idleTimeout:)`).
