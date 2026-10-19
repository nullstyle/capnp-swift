# The QUIC server-close residual (disconnectNow) — findings and the two fix paths

Status: CLOSED (2026-10-18). Fix path B landed upstream: capnp-zig
v0.27.0 (`1fdc029`) ends the RPC session when stream 0 ends. A clean FIN
closes it with cause `peer_close`; a RESET or a stop closes it with
`transport_error`. capnp-swift pins v0.27.0 for the core and the e2e peers
since 2026-10-18. Evidence: `scripts/e2e-pair-quic.sh` passes 10/10
pairings (84 checks); the Zig client's whole `resolve_disembargo` run takes about 60 ms. Ablation: with both
the server's FIN and its receive cancel removed, check 9 fails
(`not ok 9` after the 30 s deadline); each signal alone passes. No Swift
code change was needed (plan §8 "capnp-zig v0.27.0 adoption").

Original status (2026-10-08): open, precisely characterized. The failing check:
zig e2e client, `resolve_disembargo` check 9 — "disconnectNow observes a
disconnect-class error". Everything else in the 5-schema QUIC matrix
passes (9/10 pairings, 84/85 checks).

## The mechanism

The scenario: the Swift server's `disconnectNow` handler closes its RPC
connection; the client asserts its outstanding question ends with
`error.Disconnected` (their peer's `forceCancelAllQuestions(disconnected)`
path, reached when the transport reports the connection gone).

What happens instead: the question ends as `error.CallTimedOut` (the
30 s question deadline), because the QUIC connection stays open — the
client sees nothing for 30 s.

## What was ruled out (all four tried against the live zig client, 2026-10-08)

The modern `NetworkConnection<QUIC>`/`QUIC.Stream` API has NO
connection-level close — every `cancel()` in Network.framework belongs to
the legacy classes (NWBrowser/NWListener/NWConnection/NWGroup...). Tried
on the serving side, each with the FIN:

1. plain FIN on stream 0 (`send(Data(), endOfStream: true)`) +
   cancelling the pending receive;
2. `stream.streamApplicationErrorCode = 0` + FIN;
3. `stream.parent.applicationError = .init(code: 0)` + FIN;
4. `stream.streamApplicationErrorCode = 0` with no FIN (hoping teardown
   becomes a RESET).

All four: `CallTimedOut`. capnp-zig's baseline engine deliberately treats
a stream-0 FIN as "bytes buffered, ended" (`embedded.zig`
`onStreamEnd` → `buf.ended = true`), not a session end — only a
RESET triggers control-stream loss, only a connection close disconnects.
The SDK also keeps its own references to the connection (the suspended
receive, the listener's session table), so ref-dropping never deinits it
while the session lives.

## Fix path A (capnp-swift): a legacy-API QUIC server

Serve QUIC through the legacy listener — `NWListener` with
`NWProtocolQUIC.Options(alpn:)` and per-stream `NWConnection`s — which
HAS `cancel()` (and `forceCancel()`). The serving model mirrors what
`RPCListener`/`TLSTransport` already do on the legacy API for TCP/TLS.
Cost: a parallel listener implementation (~the size of QUICListener) and
re-validating the M6 wire gates (second-stream reset, clean close
`peer_close`, 90 s idle, both mvp lanes) against it. Do this if the
residual matters before capnp-zig's QUIC work resumes.

## Fix path B (capnp-zig): a session-end semantic for stream 0

Treat a stream-0 FIN with no pending bytes as session end (or add a
baseline close envelope). That is a wire-semantic change on an
Experimental transport the owner has deliberately set aside for now —
hence this file rather than a branch.

## Either way

The Swift-side characterization stands on its own: the modern Network
QUIC API cannot serve a protocol whose server ever closes the connection
first. That fact is worth having in the open even if fix path B wins.
