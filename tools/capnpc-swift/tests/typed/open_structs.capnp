@0xe51d3394cf8b12a6;
enum Choice { none @0; first @1; }
struct Envelope(T) {
  value @0 :T;
  count @1 :UInt32 = 42;
  names @2 :List(Text) = ["default"];
  metadata :group {
    flag @3 :Bool = true;
    entry @4 :T;
  }
  union {
    text @5 :Text;
    payload @6 :T;
    number @7 :Int32 = -13;
    choice @8 :Choice = first;
    choices @9 :List(Choice) = [first, none];
  }
  numbers @10 :List(UInt16) = [2, 3];
  voids @11 :List(Void) = [void, void];
  struct Inner(U) {
    outer @0 :T;
    inner @1 :U;
  }
}
struct Root {
  envelope @0 :Envelope(Text);
  inner @1 :Envelope(Data).Inner(Text);
}
