// swift-tools-version: 6.0
//
// capnp-swift: Cap'n Proto RPC for Swift apps on Apple platforms.
//
// The RPC core is capnp-zig (hash-pinned in core/build.zig.zon), built into
// the static CapnpCore.xcframework by `cd core && mise exec -- zig build
// xcframework`. Build that first; SwiftPM only links it.
//
// Packaging rules (plan §10): the XCFramework is static and ships no dynamic
// product; never bundle compiler-rt; never strip its DWARF.
import PackageDescription

let package = Package(
    name: "capnp-swift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        // Pure-Swift message reader/builder (no Zig). Placeholder until M3.
        .library(name: "Capnp", targets: ["Capnp"]),
        // RPC runtime over the C ABI in CapnpCore.
        .library(name: "CapnpRPC", targets: ["CapnpRPC"]),
        // Network.framework transports. Placeholder until M1.
        .library(name: "CapnpNW", targets: ["CapnpNW"]),
    ],
    targets: [
        // Local path for development. Releases switch to
        // .binaryTarget(url:checksum:) (plan §10 release ceremony, M7).
        .binaryTarget(
            name: "CapnpCore",
            path: "CapnpCore.xcframework"
        ),
        .target(
            name: "Capnp"
        ),
        .target(
            name: "CapnpRPC",
            dependencies: ["CapnpCore"]
        ),
        .target(
            name: "CapnpNW",
            dependencies: ["CapnpRPC"]
        ),
        .testTarget(
            name: "CapnpRPCTests",
            // CapnpCore directly too: CoreSelftestTests calls a core test hook.
            dependencies: ["CapnpRPC", "CapnpCore"]
        ),
        // Crash-symbolication probe for scripts/check-dsym.sh: traps inside a
        // known Zig frame. Not a product; never shipped.
        .executableTarget(
            name: "TrapProbe",
            dependencies: ["CapnpCore"],
            path: "Examples/TrapProbe"
        ),
    ],
    swiftLanguageModes: [.v6]
)
