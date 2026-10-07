// Platform support (plan §8 M5): the XCFramework ships macOS (15+) and
// iOS (18+) slices — capnp-zig v0.21.0 landed handoff H1, and the core is
// built with `-Dfd-passing=false`, so the same static library links on
// both. QUIC (M6) needs macOS/iOS 26 and stays gated there.
#if !os(macOS) && !os(iOS)
#error("capnp-swift: CapnpRPC supports macOS and iOS only (plan §8, M5)")
#endif

import Foundation

/// The deployment floors this build supports ( informational; the authority
/// is Package.swift's `platforms` and the XCFramework slice versions).
public enum CapnpPlatform {
    public static let macOSMinimum = "15.0"
    public static let iOSMinimum = "18.0"
}
