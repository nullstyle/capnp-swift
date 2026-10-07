@0xd1a2b3c4d5e6f708;
$Swift.module("CapnpImportLib");

using Swift = import "/swift.capnp";
# The two-target import gate (plan §8, M3): app.capnp imports this file from
# a SEPARATE SwiftPM target (CapnpImportLib) and CapnpImportApp references
# its types across the module boundary.
struct Boxed @0x8c1a3f0f2a5f4a5c { value @0 :UInt32 = 42; }
