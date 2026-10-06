# capnp-swift

Cap'n Proto RPC for Swift apps on Apple platforms.

- The RPC core is [capnp-zig](https://github.com/nullstyle/capnp-zig), built as a static XCFramework.
- Networking is Apple's Network.framework (TCP, TLS, Unix sockets; QUIC on macOS/iOS 26).
- Status: pre-alpha. Milestone M0 (packaging + seam spikes) is done except its symbol gate, which waits on an owner decision (D7); M1 (MVP slice) is next. See `docs/plan-2026-10-06.md` §8.

Platforms: macOS 15+ (QUIC needs 26+). iOS 18+ comes with milestone M5; until then only the macOS slice ships and CapnpRPC refuses to build for other platforms.
