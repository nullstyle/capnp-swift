@0xd98a62b81f4c6aab;

struct Box(T) { value @0 :T; }
interface Base(T) { echo @0 (value :T) -> (value :T); }
interface Left(T) extends(Base(T)) { left @0 (value :T) -> (value :T); }
interface Right(T) extends(Base(T)) { right @0 (value :T) -> (value :T); }
interface Diamond(T) extends(Left(T), Right(T)) {
  local @0 (value :T) -> (value :T);
}
interface Other(T) { echo @0 (value :T) -> (value :T); }
interface Joined(T) extends(Base(T), Other(T)) {}
interface Named(T) { echo @0 Box(T) -> Box(T); }
struct Outer(T) {
  interface Inner { echo @0 (value :T) -> (value :T); }
}
interface Sink(T) { push @0 (value :T) -> (value :T); }
interface Factory(T) {
  relay @0 (value :T, callback :Sink(T)) -> (value :T);
  make @1 () -> (sink :Sink(T));
  nested @2 () -> (boxed :Box(Sink(T)), direct :Sink(T), many :List(Box(Sink(T))));
}
struct Root {
  textDiamond @0 :Diamond(Text);
  dataBase @1 :Base(Data);
  collision @2 :Joined(Text);
  named @3 :Named(Text);
  lexical @4 :Outer(Text).Inner;
  factory @5 :Factory(Text);
}

interface Mixed extends(Base(Text), Base(Data)) {}
struct ConflictingRoot { service @0 :Mixed; }
interface MethodGeneric { echo @0 [T] (value :T) -> (value :T); }
struct MethodRoot { service @0 :MethodGeneric; }
interface CycleSeed {}
struct CycleRoot { service @0 :CycleSeed; }
