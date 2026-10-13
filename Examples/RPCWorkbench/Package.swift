// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RPCWorkbench",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "WorkbenchKit", targets: ["WorkbenchKit"]),
        .executable(name: "workbench-smoke", targets: ["WorkbenchSmoke"]),
    ],
    dependencies: [.package(name: "capnp-swift", path: "../..")],
    targets: [
        .target(name: "WorkbenchModels", dependencies: [
            .product(name: "Capnp", package: "capnp-swift"),
            .product(name: "CapnpRPC", package: "capnp-swift"),
        ]),
        .target(name: "WorkbenchRPC", dependencies: [
            "WorkbenchModels",
            .product(name: "Capnp", package: "capnp-swift"),
            .product(name: "CapnpRPC", package: "capnp-swift"),
        ]),
        .target(name: "WorkbenchKit", dependencies: [
            "WorkbenchModels", "WorkbenchRPC",
            .product(name: "Capnp", package: "capnp-swift"),
            .product(name: "CapnpRPC", package: "capnp-swift"),
            .product(name: "CapnpNW", package: "capnp-swift"),
        ], resources: [.copy("Certificates")]),
        .executableTarget(name: "WorkbenchSmoke", dependencies: ["WorkbenchKit"]),
        .testTarget(name: "WorkbenchTests", dependencies: ["WorkbenchKit"]),
    ],
    swiftLanguageModes: [.v6]
)
