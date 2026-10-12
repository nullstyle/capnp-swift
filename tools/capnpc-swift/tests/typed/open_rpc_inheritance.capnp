@0xdadb8090d41a84e7;

struct IBox(T) { value @0 :T; }
interface IBase(T) { echo @0 (value :T) -> (value :T); }
interface ILeft(T) extends(IBase(T)) { left @0 (value :T) -> (value :T); }
interface IRight(T) extends(IBase(T)) { right @0 (value :T) -> (value :T); }
interface IDiamond(T) extends(ILeft(T), IRight(T)) { local @0 (value :T) -> (value :T); }
interface IOther(T) { echo @0 (value :T) -> (value :T); }
interface IJoined(T) extends(IBase(T), IOther(T)) {}
struct IOuter(T) { interface Inner { echo @0 (value :T) -> (value :T); } }
interface ISink(T) { push @0 (value :T) -> (value :T); }
interface IFactory(T) {
  relay @0 (value :T, callback :ISink(T)) -> (value :T);
  make @1 () -> (sink :ISink(T));
  nested @2 () -> (boxed :IBox(ISink(T)), direct :ISink(T), many :List(IBox(ISink(T))));
}

interface Connection { ping @0 () -> (value :Text); }
interface Capability { pong @0 () -> (value :Text); }
struct IUnboundPayload { fixedText @0 :Text; fixedData @1 :Data; }
interface IReserved extends(Connection, Capability) {
  unused @0 [T] IUnboundPayload -> IUnboundPayload;
}

struct IRoot {
  textDiamond @0 :IDiamond(Text);
  dataBase @1 :IBase(Data);
  joined @2 :IJoined(Text);
  lexical @3 :IOuter(Text).Inner;
  factory @4 :IFactory(Text);
  reserved @5 :IReserved;
}
