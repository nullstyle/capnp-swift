@0xbfc78d8e9145fd39;
using Swift = import "/swift.capnp";
$Swift.module("WorkbenchRPC");

interface Observer {
  event @0 (message :Text, sequence :UInt32) -> ();
}

interface Session(T) {
  echo @0 (value :T) -> (value :T);
  exchange @1 [U] (value :U) -> (value :U);
  push @2 (value :T, sequence :UInt32) -> stream;
  receipt @3 () -> (count :UInt32, last :T, sequence :UInt32);
  slow @4 (delayMillis :UInt32) -> (completed :Bool);
}

interface Workbench {
  open @0 (observer :Observer, delayMillis :UInt32) -> (session :Session(Text));
}
