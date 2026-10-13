@0xe71122aabbcc0100;

struct ReaderHost(T) {
  payload @0 :T;
  child @1 :Reader;
  struct Reader @0xe71122aabbcc0101 { number @0 :UInt32; }
}

struct BuilderHost(T) {
  payload @0 :T;
  child @1 :Builder;
  struct Builder @0xe71122aabbcc0102 { number @0 :UInt32; }
}

struct ValueHost(T) {
  payload @0 :T;
  child @1 :Value;
  struct Value @0xe71122aabbcc0103 { number @0 :UInt32; }
}

struct PipelineHost(T) {
  payload @0 :T;
  child @1 :Pipeline;
  struct Pipeline @0xe71122aabbcc0104 { number @0 :UInt32; }
}

struct TypedHost(T) {
  payload @0 :T;
  child @1 :Typed;
  struct Typed @0xe71122aabbcc0105 { number @0 :UInt32; }
}

struct Groups {
  value :group { number @0 :UInt32; }
  pipeline :group { enabled @1 :Bool; }
}

interface RpcHost {
  struct Client @0xe71122aabbcc0106 { number @0 :UInt32; }
  struct Export @0xe71122aabbcc0107 { number @0 :UInt32; }
  inspect @0 Client -> Export;
}

struct PlainNames {
  client @0 :Client;
  exported @1 :Export;
  struct Client { number @0 :UInt32; }
  struct Export { number @0 :UInt32; }
}

struct Uses {
  reader @0 :ReaderHost(Text).Reader;
  builder @1 :BuilderHost(Data).Builder;
  value @2 :ValueHost(Text).Value;
  pipeline @3 :PipelineHost(Text).Pipeline;
  typed @4 :TypedHost(Text).Typed;
  rpcClient @5 :RpcHost.Client;
  rpcExport @6 :RpcHost.Export;
}
