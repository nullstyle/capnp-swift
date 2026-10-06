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
                == "core 0.0.1 / capnp-zig 0.20.0 / capnpc_zig-0.20.0-nUduFXM1RwDO9CsVGFgZowhDNaDZ5V5-10qgILp63pqV"
        )
        #expect(CapnpCoreInfo.features == 0)
    }
}
