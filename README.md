# capnp-swift

Cap'n Proto RPC for Swift apps on Apple platforms.

- The RPC core is [capnp-zig](https://github.com/nullstyle/capnp-zig), built as a static XCFramework.
- Networking is Apple's Network.framework (TCP, TLS, Unix sockets; QUIC on macOS/iOS 26).
- Status: pre-alpha. Milestones M0-M2 are done: the C ABI v1 (calls, pipelining, cancel, promise exports, shutdown), the `RPCConnection` actor with `RemotePromise`, backpressure and in-order handlers, TCP client and server transports, hand-written bindings for `interop/schemas/mvp.capnp`, `just mvp-e2e` against a capnp-zig server, a C ABI fuzzer, and clean TSan/ASan runs. The pin is capnp-zig v0.21.0 with fd passing compiled out (strict symbol gate green). M3 (codegen) is next. See `docs/plan-2026-10-06.md` §8.

Platforms: macOS 15+ (QUIC needs 26+). iOS 18+ comes with milestone M5; until then only the macOS slice ships and CapnpRPC refuses to build for other platforms.
