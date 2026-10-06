// CoreSelftest (M0): the capnp-zig Peer runs inside a Swift process.
//
// `capnp_core_debug_selftest` (a test hook in core/src/abi.zig) runs a
// bootstrap + call round trip between two in-process connections of the
// linked CapnpCore.xcframework: the real conn.zig + capnp-zig Peer, built with
// apple_root.zig's overrides (C allocator, `std.Io.failing` debug Io, trap
// panic). This proves the slice links into a Swift binary and the Peer works
// there, before M1 adds the capnp_conn_* C ABI.

import CapnpCore
import Testing

@Suite("CoreSelftest")
struct CoreSelftestTests {
    @Test("a bootstrap + call round trip runs inside the linked core")
    func roundTrip() {
        var failure: UnsafePointer<CChar>? = nil
        let status = capnp_core_debug_selftest(&failure)
        let reason = failure.map { String(cString: $0) } ?? "none"
        #expect(status == 0, "selftest failed: \(reason)")
        #expect(failure == nil)
    }
}
