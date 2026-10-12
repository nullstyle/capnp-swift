@0x91f4578a42e7135d;
using Source = import "open_rpc_inheritance.capnp";
interface Mixed extends(Source.IBase(Text), Source.IBase(Data)) {}
struct Root { service @0 :Mixed; }
