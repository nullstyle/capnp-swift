# capnp-swift

Cap'n Proto RPC for Swift apps on Apple platforms.

- The RPC core is [capnp-zig](https://github.com/nullstyle/capnp-zig), built as a static XCFramework.
- Networking is Apple's Network.framework (TCP, TLS, Unix sockets; QUIC on macOS/iOS 26).
- Status: pre-alpha. Milestone M1 (the MVP slice) is done: the C ABI v1 subset, a TCP transport, the `RPCConnection` actor, hand-written bindings for `interop/schemas/mvp.capnp`, and `just mvp-e2e` (a Swift client talking to a capnp-zig server both ways). The pin is capnp-zig v0.21.0 with fd passing compiled out, so the strict symbol gate passes (D7 closed). M2 (RPC complete + hardening) is next. See `docs/plan-2026-10-06.md` §8.

Platforms: macOS 15+ (QUIC needs 26+). iOS 18+ comes with milestone M5; until then only the macOS slice ships and CapnpRPC refuses to build for other platforms.
