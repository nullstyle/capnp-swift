# capnp-swift

Cap'n Proto RPC for Swift apps on Apple platforms.

- The RPC core is [capnp-zig](https://github.com/nullstyle/capnp-zig), built as a static XCFramework.
- Networking is Apple's Network.framework (TCP, TLS, Unix sockets; QUIC on macOS/iOS 26).
- Status: pre-alpha. Milestones M0-M2 are done: the C ABI v1 (calls, pipelining, cancel, promise exports, shutdown), the `RPCConnection` actor with `RemotePromise`, backpressure and in-order handlers, TCP client and server transports, hand-written bindings for `interop/schemas/mvp.capnp`, `just mvp-e2e` against a capnp-zig server, a C ABI fuzzer, and clean TSan/ASan runs. The pin is capnp-zig v0.21.0 with fd passing compiled out (strict symbol gate green). M3 (codegen) is next. See `docs/plan-2026-10-06.md` §8.

Platforms: macOS 15+ (QUIC needs 26+). iOS 18+ comes with milestone M5; until then only the macOS slice ships and CapnpRPC refuses to build for other platforms.

## iOS apps (M5)

The package builds for macOS 15+ and iOS 18+ (`CapnpCore.xcframework`
ships `ios-arm64` and `ios-arm64_x86_64-simulator` slices; build them with
`cd core && mise exec -- zig build xcframework -Dios=true`). The core is
compiled with fd passing off, so it starts no threads and imports no
Darwin SPI.

Apps that talk to peers on the local network **must** add this to their
`Info.plist` (iOS 14+ local-network privacy prompt), or every connection
is refused silently:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects to your Cap'n Proto RPC server on the local network.</string>
```

If the peer is addressed by multicast/Bonni name, also add
`NSBonjourServices` with the service type. Opt into background handling
with `RPCLifecyclePolicy` (`Sources/CapnpRPC/Lifecycle.swift`): background
suspends the connection (short drain), foreground reconnects through your
factory. `PrivacyInfo.xcprivacy` ships as a resource of `CapnpRPC` (and a
copy sits next to the XCFramework slices for manual embedding).
