import CapnpRPC
import Testing

@Suite("CapnpCoreInfo")
struct CapnpCoreInfoTests {
    @Test("the linked core matches the header's ABI version")
    func abiVersionMatchesHeader() {
        #expect(CapnpCoreInfo.abiVersion == 1)
        #expect(CapnpCoreInfo.abiVersion == CapnpCoreInfo.headerABIVersion)
    }

    @Test("the version string names the core and the capnp-zig pin")
    func versionString() {
        #expect(CapnpCoreInfo.version == "core 0.0.1 / capnp-zig 0.20.0")
        #expect(CapnpCoreInfo.features == 0)
    }
}
