# H3 — capnp-zig: fix the TCP framing sentence, publish the QUIC baseline wire spec, export its constants

- **To:** capnp-zig (the owner lands it on `main` and cuts the tag)
- **From:** capnp-swift
- **Date:** 2026-10-06
- **Status:** DRAFT (the owner sends it)
- **Needed by:** M6 (QUIC baseline). The doc fix can land any time.

This is a document, not an issue. Nothing here was filed anywhere.

Base: v0.20.0 (`01eaebe`); every cited file is identical at `1ee6d18` and at `main` `5fabb36`. Line numbers are v0.20.0's.

## Summary

1. `docs/quic-transport.md:85-88` says baseline mode keeps "the same" 32-bit length prefix as TCP. TCP has no length prefix. Replace the sentence.
2. capnp-swift will implement the baseline wire from Swift (`NetworkConnection<QUIC>`). The rules live only in code today. Section 3 below is spec text to paste into `docs/quic-transport.md`, with every constant checked against `src/rpc/transport/quic/*`.
3. A build without `-Dquic=true` exports the ALPN, the stream id, the prefix size and the framer, but not the close codes, the refusal code or the idle timeout. Move every wire constant into one std-only file and export it in both builds.
4. A test pins the constants to the spec. It was ablated.

## 1. The TCP sentence

`docs/quic-transport.md:85-88`:

> Baseline mode is the compatibility baseline. It preserves the TCP transport's single ordered byte stream above the QUIC handshake, so every RPC frame is still delimited by the same 32-bit little-endian length prefix before being handed to `Peer`.

What is true:

- TCP sends standard Cap'n Proto stream framing and nothing else: the segment table, then the segments. `rpc.transport.tcp.Connection` reads with `wire.framing.Framer` (`src/rpc/transport/tcp/connection.zig:47`), which parses the segment table (limits at `src/rpc/wire/framing.zig:8-10`: 8 Mi words, 512 segments).
- QUIC baseline adds a u32 little-endian length in front of that same framed message (`src/rpc/transport/quic/outbound_queue.zig:47-58` writes it; `length_framer.zig:77` reads it).

Proposed text:

> Baseline mode is the compatibility baseline. It keeps the TCP transport's single ordered byte stream above the QUIC handshake. Each RPC message is the same framed Cap'n Proto message TCP sends (segment table, then segments), with a 32-bit little-endian byte length in front of it. TCP has no such length prefix. See [Baseline wire protocol](#baseline-wire-protocol-frozen).

`docs/rpc_runtime_design.md:70` describes the QUIC prefix correctly and needs no change. I found no other doc with the error (`grep -rn -i "length prefix\|32-bit little-endian" docs README.md`).

## 2. What exists today, without `-Dquic=true`

`capnpc-zig-core` exposes `rpc.transport.quic` as the stub `src/rpc/transport/quic_disabled.zig` (`src/rpc/mod_core.zig:12`). A test against the v0.20.0 core module (`zig test`, no `-Dquic`) confirmed:

| Name | Exported without `-Dquic` | Source |
|---|---|---|
| `alpn` | yes | `quic_disabled.zig:11` (a second literal copy of `quic/options.zig:13`) |
| `baseline_stream_id` | yes | `quic_disabled.zig:12` (a copy of `quic/options.zig:19`) |
| `length_prefix_bytes` | yes | `quic_disabled.zig:24` → `quic/length_framer.zig:4` |
| `LengthDelimitedFramer` | yes | `quic_disabled.zig:18` |
| close codes (`ApplicationCloseCode`) | **no** | `quic/close.zig:10-16` |
| stream refusal code | **no** | `quic/peer_streams.zig:31` (imports quic-zig) |
| idle timeout (30 s) | **no** | `quic/options.zig:239` (imports quic-zig) |
| default max message size | **no** | `quic/options.zig:40` |

Tests pin the two duplicated literals in both builds (`tests/docs/quic_transport_disabled_snippets_test.zig:17-18`, `tests/rpc/transport/quic/rpc_quic_transport_test.zig:161-162`). Nothing pins the close codes outside `close.zig`'s own test (`close.zig:197-201`), and that test runs only with `-Dquic=true`.

## 3. Spec text to paste into `docs/quic-transport.md`

Each line cites its source so the reviewer can check it. Drop the citations when pasting if the doc style prefers.

---

### Baseline wire protocol (frozen)

This section is the whole baseline wire. Another implementation can interoperate with capnp-zig from it alone. A change to any rule here needs a new ALPN (`capnp-rpc/2`).

**Connection.** QUIC with TLS 1.3. Both endpoints offer exactly one ALPN, `capnp-rpc/1` (`quic/options.zig:13`; the client and server defaults at `:259` and `:352`). The mode (baseline or native) is not negotiated; both sides must be configured for baseline (`docs/quic-transport.md:76-77`). One QUIC connection is one RPC session between two vats.

**Streams.**

1. The client opens client-initiated bidirectional stream **0** (`quic/options.zig:19`) and sends the RPC messages on it. The server answers on the same stream. Nothing else carries RPC traffic.
2. The server opens no streams.
3. Each endpoint refuses every stream the peer opens other than the client's stream 0. For a bidirectional stream it sends STOP_SENDING and RESET_STREAM; for a unidirectional stream it sends STOP_SENDING only. The application error code is `0x434e5002`. The connection stays up (`quic/peer_streams.zig:36-54`).
4. The client SHOULD send its first message (normally `Bootstrap`) as soon as the handshake completes. A capnp-zig server cannot send anything until stream 0 exists on its side (`quic/baseline_engine.zig:139-161`), and in QUIC a peer's stream exists for the receiver once a frame for it arrives.
5. Neither endpoint finishes (FIN) or resets stream 0 while the session lives. End a session with CONNECTION_CLOSE. capnp-zig never finishes stream 0 in baseline mode (`streamFinish` appears only in `quic/native_outbound_queue.zig:243` and `quic/embedded.zig:666`). What it does when the peer finishes or resets stream 0 is not specified.

**Framing.** Stream 0 carries a sequence of messages, both directions, and nothing else (no preface, no hello; those belong to native mode):

```
message = length:u32 (little-endian) || body:[length]u8
body    = one Cap'n Proto message in standard stream framing:
          (segment count - 1):u32 LE, segment sizes in words:u32 LE each,
          4 padding bytes if the segment count is even, then the segments
```

- `length` counts the body bytes only, not the 4 prefix bytes (`quic/length_framer.zig:61`, `quic/outbound_queue.zig:57`).
- `length` MUST be at least 1. Zero is a frame error (`quic/length_framer.zig:78`).
- `length` MUST NOT exceed the receiver's limit. capnp-zig's default is 67,108,864 bytes (8 Mi words × 8; `quic/options.zig:40`). Over the limit is a frame error (`quic/length_framer.zig:80`, `:84-87`).
- `body` is exactly one framed message, the same bytes a TCP peer writes. Send no bytes after the last segment. (capnp-zig v0.20.0 does not reject trailing bytes: `src/serialization/message.zig:697-709` never compares the end offset with the input length. This was read, not tested. Do not rely on it.)
- capnp-zig accepts up to 512 segments (`src/serialization/message.zig:513`). The C++ reference accepts at most 511, so senders SHOULD stay at or below 511.
- The message is a `rpc.capnp` `Message`, exactly as on TCP.

**Close codes.** QUIC application error codes, in CONNECTION_CLOSE (and, for `0x434e5002`, in STOP_SENDING and RESET_STREAM). Source: `quic/close.zig:10-16`; meanings from `close.zig:128-152`, `quic/termination.zig:17-33`, `quic/connection_dispatch.zig:62-69`.

| Code | Name | Reason phrase sent | When capnp-zig sends it |
|---|---|---|---|
| `0` | normal | empty | A clean close by either side (`quic/close_controller.zig:48`, `:140`). |
| `0x434e5001` | frame_error | `rpc frame error` | A bad length prefix: zero, over the limit, or more bytes buffered than allowed. |
| `0x434e5002` | protocol_error | `rpc protocol error` | As a stream code: a refused stream (rule 3). As a connection close: a framing error that is not a bad length (`close.zig:142`); baseline's framer produces none today (read, not tested). |
| `0x434e5003` | internal_error | `rpc transport error` | A local failure: out of memory, or a transport step error (`close.zig:141`, `:146-152`). |
| `0x434e5004` | peer_callback_failure | `rpc callback error` | The RPC layer rejected a well-framed message, for example a body that is not a valid Cap'n Proto message. The RPC layer sends an `Abort` first (`src/rpc/peer/mod.zig:4207-4234`). Read, not tested. |

- The reason phrase is at most 96 bytes of printable ASCII; other bytes become `?` (`close.zig:18`, `:160-194`). capnp-zig sends only the fixed text above, unless the operator turns on `reveal_close_reason_on_wire` (default `false`, `quic/connection_init.zig:39`); then it appends `": <ErrorName>"`.
- A receiver MUST treat the reason as untrusted display text, and any nonzero code it does not know as an error.

**Liveness.**

- capnp-zig advertises `max_idle_timeout` = 30,000 ms (`quic/options.zig:239`). The effective timeout is the smaller of the two sides' values (RFC 9000 §10.1).
- capnp-zig sends no keepalive PINGs (no ping or keepalive call in `src/rpc/transport/quic/*.zig`). quic-zig still sends its loss-recovery probes. An endpoint that wants an idle session to live longer than the timeout sends its own PINGs more often than every 30 s.
- Handshake timeouts are local policy, not wire: client 30 s (`quic/options.zig:269`), server 10 s (`:454`).

**Optional features.**

- 0-RTT is optional. capnp-zig servers turn early data off by default (`quic/options.zig:399`). When it is on, frames that arrive in 0-RTT are held until the handshake completes (`:410`, `quic/baseline_engine.zig:119-128`). A client that never sends early data needs nothing.
- QUIC DATAGRAM frames are not used (`docs/quic-transport.md:103-104`).

**Informative: capnp-zig's transport parameters** (`quic/options.zig:237-248`): `initial_max_data` 16 MiB; `initial_max_stream_data_*` 1 MiB; `initial_max_streams_bidi` 16; `initial_max_streams_uni` 8; `active_connection_id_limit` 4. These are defaults, not wire rules. A peer MUST NOT open more streams than rule 1 allows, whatever the limits say.

**Informative: TLS.** The client verifies the server certificate by default (`ca_pem`, `insecure_skip_verify = false`; `quic/options.zig:285`, `:288`) and sends `server_name` as SNI (`:258`).

---

## 4. Export the constants from a std-only file

New file `src/rpc/transport/quic/wire.zig`. It imports nothing, so every build can export it:

```zig
//! The QUIC baseline wire constants (docs/quic-transport.md, "Baseline wire
//! protocol"). No imports, so every build exports them, with or without
//! `-Dquic=true`. A change here is a wire change: it needs a new ALPN.

/// TLS ALPN protocol id. Both sides offer exactly this.
pub const alpn = "capnp-rpc/1";
/// The one bidirectional stream, opened by the client.
pub const baseline_stream_id: u64 = 0;
/// Each RPC message on stream 0 is preceded by its length as a u32,
/// little-endian.
pub const length_prefix_bytes: usize = 4;
/// QUIC application error codes. 0 is a normal close.
pub const ApplicationCloseCode = enum(u64) {
    normal = 0,
    frame_error = 0x434e_5001,
    protocol_error = 0x434e_5002,
    internal_error = 0x434e_5003,
    peer_callback_failure = 0x434e_5004,
};
/// STOP_SENDING / RESET_STREAM code for a peer stream the protocol has no
/// use for. The connection stays up.
pub const stream_refusal_code: u64 = @backingInt(ApplicationCloseCode.protocol_error);
/// The idle timeout capnp-zig advertises, in ms. The effective value is the
/// smaller of both sides'.
pub const default_max_idle_timeout_ms: u64 = 30_000;
/// The largest message body capnp-zig accepts by default (8 Mi words).
pub const default_max_message_bytes: usize = 8 * 1024 * 1024 * 8;
/// The longest close reason phrase capnp-zig sends.
pub const max_close_reason_bytes: usize = 96;
```

Then:

- `quic_disabled.zig`: `pub const wire = @import("quic/wire.zig");` and make `alpn` and `baseline_stream_id` (`:11-12`) aliases of it.
- `quic/mod.zig`: `pub const wire = @import("wire.zig");` (next to `:132`).
- `quic/options.zig:13`, `:19`, `:239`; `quic/close.zig:10-16`, `:18`; `quic/length_framer.zig:4`; `quic/peer_streams.zig:31`: read from `wire` instead of their own literals. `default_max_message_bytes` can keep its `framing.Framer.max_frame_words * 8` form if the test below pins the two equal.

All new declarations are Experimental (new decls default there), so regenerate `docs/api-snapshot-experimental.txt` and `docs/api-snapshot-experimental-quic.txt`. capnp-swift then reads the values from the core (`capnp_core_quic_alpn()` and friends), so they cannot drift from capnp-zig.

## 5. The test that proves it

`tests/docs/quic_wire_spec_test.zig`, registered twice: next to `build/build_impl.zig:416` with `addLibTest` (default root) and next to `:420` with `addQuicLibTest` (`-Dquic=true` root), so both re-exports are checked. Registering it matters: an unregistered test file runs nowhere.

```zig
//! The QUIC baseline wire spec (docs/quic-transport.md), pinned.
const std = @import("std");
const capnpc = @import("capnpc-zig");
const quic = capnpc.rpc.transport.quic;
const wire = quic.wire;

test "QUIC baseline wire constants match the published spec" {
    try std.testing.expectEqualStrings("capnp-rpc/1", wire.alpn);
    try std.testing.expectEqual(@as(u64, 0), wire.baseline_stream_id);
    try std.testing.expectEqual(@as(usize, 4), wire.length_prefix_bytes);
    try std.testing.expectEqual(@as(u64, 0), @backingInt(wire.ApplicationCloseCode.normal));
    try std.testing.expectEqual(@as(u64, 0x434e5001), @backingInt(wire.ApplicationCloseCode.frame_error));
    try std.testing.expectEqual(@as(u64, 0x434e5002), @backingInt(wire.ApplicationCloseCode.protocol_error));
    try std.testing.expectEqual(@as(u64, 0x434e5003), @backingInt(wire.ApplicationCloseCode.internal_error));
    try std.testing.expectEqual(@as(u64, 0x434e5004), @backingInt(wire.ApplicationCloseCode.peer_callback_failure));
    try std.testing.expectEqual(@as(u64, 0x434e5002), wire.stream_refusal_code);
    try std.testing.expectEqual(@as(u64, 30_000), wire.default_max_idle_timeout_ms);
    try std.testing.expectEqual(@as(usize, 67_108_864), wire.default_max_message_bytes);
    // The older names agree with `wire`.
    try std.testing.expectEqualStrings(wire.alpn, quic.alpn);
    try std.testing.expectEqual(wire.baseline_stream_id, quic.baseline_stream_id);
    try std.testing.expectEqual(wire.length_prefix_bytes, quic.length_prefix_bytes);
}

test "the baseline framer reads a u32 little-endian length" {
    var framer = quic.LengthDelimitedFramer.init(std.testing.allocator, 1024);
    defer framer.deinit();
    try framer.push(&[_]u8{ 3, 0, 0, 0, 'a', 'b', 'c' });
    const frame = (try framer.popFrame()).?;
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("abc", frame);
}

test "a zero length is a frame error" {
    var framer = quic.LengthDelimitedFramer.init(std.testing.allocator, 1024);
    defer framer.deinit();
    try framer.push(&[_]u8{ 0, 0, 0, 0 });
    try std.testing.expectError(error.InvalidFrame, framer.popFrame());
}
```

Under `-Dquic=true`, add one more check that the live values agree with `wire`: `quic.defaultTransportParams().max_idle_timeout_ms` and `quic.ClientOptions{...}.alpn_protocols[0]` (the existing `tests/docs/quic_transport_snippets_test.zig:82-83` already does the ALPN half).

**Measured on a scratch copy of v0.20.0** (the `wire.zig` and test text above, verbatim, plus the `quic_disabled.zig` re-export; `zig test` against the default `src/lib.zig` root and against `src/lib_core.zig`, Zig 0.17.0, macOS 27 arm64): 3 of 3 pass on each; both files are `zig fmt` clean. **Ablation:** `frame_error = 0x434e_5005` in `wire.zig` → the first test FAILS with `expected 1129205761, found 1129205765`; restored → 3 of 3 pass.

Optional, for third parties: add `tests/fixtures/framing/quic_baseline_fixtures.json` in the format of `tests/fixtures/framing/framing_fixtures.json` (split prefix, two messages in one push, zero length, over the limit, buffered-bytes ceiling), run by a sibling of `tests/rpc/wire/framing_fixtures_test.zig`. Swift's `U32_LE` framing mode would run the same file.

## Not verified

- The `-Dquic=true` half: the edits to `options.zig`, `close.zig`, `peer_streams.zig` and `quic/mod.zig`, and the second registration. quic-zig v0.28.1 is in no local cache and I did not fetch it.
- Rows marked "read, not tested" above: the trailing-bytes behavior, `protocol_error` never being a baseline connection close, and the `Abort` before `0x434e5004`.
- Whether quic-zig puts a STREAM frame on the wire when the client opens stream 0 with no data (rule 4 is written so that it does not matter).
- Interop of the spec against a non-capnp-zig QUIC stack. capnp-swift's probes so far were Network.framework to Network.framework.

Scratch evidence (not in any repo):
`/private/tmp/claude-501/-Users-nullstyle-prj-zig-capnp-zig/d3e1b574-cf0b-4f76-a01c-9b84d5bc10a3/scratchpad/capnp-swift/h3-probe/` (what the v0.20.0 core exports) and `.../h3-proto/` (`wire.zig`, the test).
