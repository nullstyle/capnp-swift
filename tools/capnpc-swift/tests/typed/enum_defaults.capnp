@0xe31d502d3e0c9b7a;
enum EnumChoice { zero @0; first @1; second @2; }
struct EnumDefaults {
  value @0 :EnumChoice = first;
  union {
    flag @1 :Void;
    choice @2 :EnumChoice = second;
    alternate @3 :EnumChoice;
  }
}
