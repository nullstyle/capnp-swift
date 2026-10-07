// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "wasmkit-probe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/swiftwasm/WasmKit", from: "0.2.0")],
    targets: [.executableTarget(
        name: "probe",
        dependencies: [
            .product(name: "WasmKit", package: "WasmKit"),
            .product(name: "WasmKitWASI", package: "WasmKit"),
            .product(name: "WASI", package: "WasmKit"),
        ]
    )]
)
