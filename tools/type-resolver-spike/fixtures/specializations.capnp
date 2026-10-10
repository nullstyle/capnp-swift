@0xf8ccef7319cb73c4;

struct Box(T) { value @0 :T; }
struct Link(T) {
  value @0 :T;
  next @1 :Link(T);
  children @2 :List(Link(T));
}
struct Outer(T) {
  struct Inner(U) {
    outer @0 :T;
    inner @1 :U;
  }
}
struct Root {
  textBox @0 :Box(Text);
  dataBox @1 :Box(Data);
  nestedBox @2 :Box(Box(Text));
  listBox @3 :Box(List(UInt16));
  boxes @4 :List(Box(Text));
  head @5 :Link(Text);
  lexical @6 :Outer(Text).Inner(Data);
  otherLexical @7 :Outer(Data).Inner(Text);
}

# Negative inputs for the public concrete-specialization contract.
struct UnboundRoot { box @0 :Box; }
struct DefaultRoot { value @0 :Text = "default"; }
struct UnsupportedRoot { value @0 :AnyPointer; }
struct Grow(T) { next @0 :Grow(Box(T)); }
struct ExpandingRoot { head @0 :Grow(Text); }
