@0xe655d4e339a631ca;
using External = import "external.capnp";
struct UsesExternal {
  box @0 :External.Box(Text);
  nested @1 :External.Outer(Data).Inner(Text);
}
