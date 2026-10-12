@0xe38e51cb9140bcdf;
struct Box(T) { value @0 :T; }
interface Parent(Outer) {
  echo @0 [T] (scope :Outer, value :T) -> (value :T, scope :Outer);
}
interface Child extends(Parent(Text)) {}
interface Named { echo @0 [T] Box(T) -> Box(T); }
interface Swap { swap @0 [A, B] (first :A, second :B) -> (first :B, second :A); }
interface Batch { gather @0 [T] (values :List(Box(T))) -> (values :List(Box(T))); }
struct Root {
  text @0 :Text;
  data @1 :Data;
  numbers @2 :List(UInt16);
  boxed @3 :Box(Text);
  boxes @4 :List(Box(Text));
  child @5 :Child;
  named @6 :Named;
  swap @7 :Swap;
  batch @8 :Batch;
}
struct UnusedRoot { value @0 :Text; }
struct InvalidArgumentRoot { value @0 :AnyPointer; }
