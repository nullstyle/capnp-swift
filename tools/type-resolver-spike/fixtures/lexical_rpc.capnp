@0xd8d53a771adf5a1d;

struct Outer(T) {
  interface Inner {
    echo @0 (value :T) -> (value :T);
  }
}

struct Root {
  service @0 :Outer(Text).Inner;
}
