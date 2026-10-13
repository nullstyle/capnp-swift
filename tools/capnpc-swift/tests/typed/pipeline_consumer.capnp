@0x87b48adef92d5fc1;
using Producer = import "pipeline_producer.capnp";
interface PBridgeSink { echo @0 (value :Text) -> (value :Text); }
interface PConsumer {
  echo @0 [T] (value :Producer.PForeign(T)) -> (value :Producer.PForeign(T));
  named @1 [T] Producer.PForeign(T) -> Producer.PForeign(T);
}
