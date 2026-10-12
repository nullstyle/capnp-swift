@0xc359f31cc2bc6c73;
interface Target { ping @0 () -> (value :Text); }
interface Connection { pong @0 () -> (value :Text); }
interface Reserved extends(Target, Connection) {}
