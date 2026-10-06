internal import CapnpCore

/// Facts about the linked Zig core (`CapnpCore.xcframework`).
public enum CapnpCoreInfo {
    /// The C ABI version the linked core implements (`capnp_core_abi_version()`).
    public static var abiVersion: UInt32 {
        capnp_core_abi_version()
    }

    /// The C ABI version this module was compiled against
    /// (`CAPNP_CORE_ABI_VERSION` in `capnp_core.h`).
    public static var headerABIVersion: UInt32 {
        UInt32(CAPNP_CORE_ABI_VERSION)
    }

    /// `"core <version> / capnp-zig <pinned version> / <pinned package hash>"`.
    public static var version: String {
        String(cString: capnp_core_version())
    }

    /// Feature bits of the linked core. None are defined yet.
    public static var features: UInt64 {
        capnp_core_features()
    }
}
