@0xbda34a5c818f6ccb;
struct EmptyItem { value @0 :Text; }
struct EmptyRecord {}
struct EmptyContainer {
  items @0 :List(EmptyItem) = [(value = "schema default")];
  zeros @1 :List(EmptyRecord) = [(), ()];
}
