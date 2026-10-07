# H3: freeze the QUIC baseline wire spec; one doc line still misdescribes TCP

Status update (capnp-swift M6, 2026-10-07). Most of H3 has landed upstream
in the pinned v0.21.0 — thank you. What remains is one doc line plus the
freeze note this handoff originally asked for.

## What landed (verified against v0.21.0)

- The constants are exported even with QUIC compiled out
  (`src/rpc/transport/quic_disabled.zig`): `alpn = "capnp-rpc/1"`,
  `baseline_stream_id = 0`. capnp-swift's C ABI now reads them from there
  (`capnp_core_quic_alpn()`).
- The close-code table (`close.zig` `ApplicationCloseCode`: normal = 0,
  frame_error = 0x434e5001, protocol_error = 0x434e5002, internal_error =
  0x434e5003, peer_callback_failure = 0x434e5004) matches the capnp-swift
  plan exactly, and `peer_streams.zig` refuses unexpected streams with
  `protocol_error` (0x434e5002) while the connection stays up.
- Baseline mode (stream 0, u32 little-endian length-delimited frames) is
  implemented and documented, with `LengthDelimitedFramer` importable
  without quic-zig.

## What is still open

1. **`docs/quic-transport.md` lines 97-99** still say baseline mode
   "preserves the TCP transport's single ordered byte stream … every RPC
   frame is still delimited by the same 32-bit little-endian length
   prefix". TCP does NOT use a u32 length prefix: on TCP/Unix/TLS every
   message is a standalone segment-table-framed blob. The sentence should
   say that baseline preserves the TCP transport's *message-level
   compatibility* (each length-prefixed payload is the same standalone
   segment-table message TCP would have delivered), not the byte framing.
2. **Freeze note**: a short "Wire constants (frozen)" section in
   `docs/quic-transport.md` stating that the ALPN string, the baseline
   stream id, the u32-LE prefix, and the five application-close codes are
   frozen and any change needs a new ALPN. capnp-swift's core now encodes
   the u32-LE baseline independently (`CAPNP_FRAMING_U32_LE`), so a silent
   change on either side breaks interop.

## Why capnp-swift needs it

capnp-swift drives the same wire from Network.framework's
`NetworkConnection<QUIC>` and re-implements the baseline framing in its
core (`core/src/conn.zig` `LengthCodec`). The frozen constants are the
contract both sides code against; the doc line above is the last place a
reader would be misled about what TCP framing actually is.
