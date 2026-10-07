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
                == "core 0.1.0 / capnp-zig 0.21.0 / capnpc_zig-0.21.0-nUduFa7PRwBrWc9CyzM8u052LMqBhHzvA52R1s407iCg"
        )
        #expect(CapnpCoreInfo.features == 0)
    }
}
