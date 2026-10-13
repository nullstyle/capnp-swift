@0xa04c7aeafc621c70;

interface PSink { echo @0 (value :Text) -> (value :Text); }
struct PBox(T) { value @0 :T; }
struct PNested(T) { box @0 :PBox(T); }
struct PChoice { union { cap @0 :PSink; text @1 :Text; } }
interface PFactory {
  make @0 () -> (sink :PSink);
  nested @1 () -> (nested :PNested(PSink));
  nullable @2 () -> (sink :PSink);
  echo @3 [T] (value :T) -> (value :T);
  accept @4 (sink :PSink, value :Text) -> (value :Text);
  shapes @5 () -> (list :List(PSink), choice :PChoice);
  stream @6 [T] (value :T) -> stream;
}
interface PGeneric(T) { push @0 (value :T) -> stream; }
interface PChild extends(PGeneric(Text)) {}
struct PNInput { value @0 :Text; }
struct PNOutput { value @0 :Text; }
interface PNamed { echo @0 PNInput -> PNOutput; sendEcho @1 PNInput -> PNOutput; }
struct PRoot { factory @0 :PFactory; child @1 :PChild; names @2 :PNamed; }
