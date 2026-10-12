@0xbedfd713ed2c3e41;
using Swift = import "/swift.capnp";
$Swift.module("TypedCollisions");
struct Box @0xac190116ba71f8d7 (T) {
  value @0 :T;
  marker @1 :UInt32 = 101;
}
