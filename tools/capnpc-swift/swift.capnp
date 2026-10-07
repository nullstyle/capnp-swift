@0x8e1a98d38bbb48b5;
# capnpc-swift's annotations (plan §6). Compile this file alongside your
# schemas (add its directory to the import path) and annotate a schema file:
#
#   using Swift = import "/swift.capnp";
#   $Swift.module("MyModule") file mySchema.capnp;
#
# annotation module @0 :Text;
#   The Swift module the file's types belong to. Files that share a module
#   see each other's types without imports. Default: the file stem in
#   PascalCase (addressbook.capnp -> Addressbook).
#
# annotation prefix @1 :Text;
#   Reserved: a name prefix for the file's types. Not yet emitted.

annotation module @0x87972259171bec98 (file) :Text;
annotation prefix @0x9692d33e395c3989 (file, struct, enum, interface, const, annotation) :Text;
