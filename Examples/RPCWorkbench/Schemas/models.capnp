@0x962b412edf9f0313;
using Swift = import "/swift.capnp";
$Swift.module("WorkbenchModels");

struct Parcel(T) {
  value @0 :T;
  label @1 :Text;
}
