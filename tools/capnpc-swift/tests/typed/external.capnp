@0xb9e38af4d22b9370;
using Swift = import "/swift.capnp";
$Swift.module("TypedExternal");
struct Box(T) { value @0 :T; }
struct Outer(T) {
  struct Inner(U) { outer @0 :T; inner @1 :U; }
}
