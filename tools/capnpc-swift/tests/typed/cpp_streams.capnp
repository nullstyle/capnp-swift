@0xd7f62a3e7987ac8b;

interface CppStream(Outer) {
  push @0 (value :Outer) -> stream;
  seen @1 () -> (value :Outer, count :UInt32);
}
interface CppStreamChild extends(CppStream(Text)) {}
interface CppMethodStream {
  push @0 [T] (value :T) -> stream;
  seen @1 () -> (value :Data, count :UInt32);
}
