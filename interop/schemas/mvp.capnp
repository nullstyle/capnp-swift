# mvp.capnp -- the M1 "MVP slice" interop schema (plan §8, M1).
#
# A Swift client talks to a capnp-zig server both ways:
#   - Greeter.greet: client -> server, with a Listener capability in the params;
#   - Listener.notify: server -> client, served by Swift.
#
# Rules the Zig peer follows (interop/zig-peer/src/main.zig):
#   - greet replies "Hello, <name>!" and calls listener.notify("greeted <name>")
#     before it replies;
#   - greet with an empty name fails with the exception reason "EmptyName"
#     (the e2e "remote exception" check).
#
# The Zig bindings (interop/zig-peer/gen/mvp.zig) are generated from this file
# by capnp-zig's own compiler and plugin, both at the pinned capnp-zig tag; the
# Swift side is written by hand until M3 ships capnpc-swift.

@0xd3a6f1c0b2e94a70;

interface Listener {
  # Called by the server while it serves greet.
  notify @0 (msg :Text) -> ();
}

interface Greeter {
  # Replies "Hello, <name>!" and notifies `listener` once.
  greet @0 (name :Text, listener :Listener) -> (reply :Text);
}
