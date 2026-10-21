import CapnpRPC
import Testing

@Suite("CapnpCoreInfo")
struct CapnpCoreInfoTests {
    @Test("the linked core matches the header's ABI version")
    func abiVersionMatchesHeader() {
        #expect(CapnpCoreInfo.abiVersion == 1)
        #expect(CapnpCoreInfo.abiVersion == CapnpCoreInfo.headerABIVersion)
    }

    @Test("the version string names the core and the exact capnp-zig pin")
    func versionString() {
        // core/build.zig.zon: bump this together with the pin.
        #expect(
            CapnpCoreInfo.version
                == "core 0.1.0 / capnp-zig 0.28.0 / capnpc_zig-0.28.0-nUduFX-xUQD3zoI5en-lnfY679kQQg3OfT9MV5vOrfpP"
        )
        // Bit 0: CAPNP_FEATURE_ANSWER_FINISHED (capnp-zig v0.28.0, handoff H13).
        #expect(CapnpCoreInfo.features == 1)
    }
}
