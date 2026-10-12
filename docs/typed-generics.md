# Open typed generics and RPC

The production generator's opt-in `--typed` mode adds open Swift schema
applications beside the existing erased declarations. This interface is
Experimental on main; release 0.1.1 does not contain it. Generated code and
the `Capnp`/`CapnpRPC` runtime must come from the same revision.

## Generate and check

In this checkout, build the native generator and driver first:

```sh
just codegen-build
just driver-build
CAPNPC_SWIFT_PLUGIN="$PWD/tools/capnpc-swift/zig-out/bin/capnpc-swift" \
  swift package --allow-writing-to-package-directory capnp-generate \
  --typed --output-dir Sources/Generated schema.capnp
```

Repeat that command with `--check` to verify committed output. A matching
artifactbundle supports the same flags through its `capnpc-driver` executable.
The default generator output remains erased; `--typed` adds declarations.
The older specialization spike and its JSON profiles are documented separately
in [generic-specializations.md](generic-specializations.md).

## Schema applications

For `struct Box(T) { value @0 :T; }`:

```swift
import Capnp

let value = try Box.Typed<CapnpText>.Value { try $0.setValue("hello") }
let reader = try Box.Typed<CapnpText>.read(from: value.pointer)
let text: String = try reader.value()
```

`CapnpText` maps to `String`, `CapnpData` to `[UInt8]`, and
`CapnpList<Element>` to an array of element readers or values. Integer,
floating-point, Bool, Void and enum schemas are supported as list elements;
`CapnpEnum<MyEnum>` wraps a UInt16-backed enum. Generated struct and interface
codecs can be used directly as generic arguments. A new application can be
written in another Swift module without a schema root or a profile listing
it. Nested declarations preserve each lexical parameter:
`Outer.Typed<CapnpText>.Inner<CapnpData>`.

Readers and values retain their message storage and are Sendable. Builders
retain allocation storage and are mutable, so they are not Sendable. Struct
values support `Value(copying: reader)`; copies preserve unknown fields and
remap capability indexes. Pointer copying bounds traversal depth and words.
Groups, unions, scalar and pointer defaults, recursive applications, and
nested lists use the same typed declarations.

Every generated top-level declaration has a stable `Name_Node<hexID>` alias.
Generated cross-file references use that alias, including when producers are
generated in a different request order. The shorter schema name remains
convenient when it is unique within its Swift module.

## Generic RPC and inheritance

For `Child extends(Parent(Text))`, where Parent declares
`echo @0 [T] (scope :Outer, value :T) -> (value :T, scope :Outer)`:

```swift
let child = try Child.Typed.Client(
    cap: try await connection.bootstrap(), connection: connection)
let result = try await child.parent.echo(as: CapnpData.self) {
    try $0.setScope("bytes")
    try $0.setValue([0, 1, 255])
}
let bytes: [UInt8] = try result.value()
```

`as:` selects the method argument. Methods with multiple arguments also use
`as1:`, `as2:`, and so on. Text/Data convenience overloads infer these two
common codecs from values; use explicit metatypes for other codecs or
ambiguous values. Parent views carry the ancestor's wire ID and effective
bindings. Equal diamond ancestors deduplicate. Conflicting bindings of one
inherited wire ID are rejected before any source is written, because an RPC
call carries no application brand.

Servers implement one erased method handler while retaining typed enclosing
bindings:

```swift
struct EchoServer: Child.TypedServer {
    func echo(
        params: Parent.Typed<CapnpText>.EchoParams<CapnpAnyPointer>.Reader,
        on connection: isolated RPCConnection
    ) async throws -> Parent.Typed<CapnpText>.EchoResults<CapnpAnyPointer>.Value {
        let value = try params.value()
        let scope = try params.scope()
        return try .init {
            try $0.setValue(value)
            try $0.setScope("ack:" + scope)
        }
    }
}
```

Export this with `Child.Typed.Export(EchoServer())`. The wire carries an
interface ID and method ordinal, with no runtime type discriminator for T.
The handler can copy an unknown pointer value without guessing its schema.
Handlers retain the connection actor's E-order semantics. Nested server
protocols live in the existing physical namespace, for example
`IOuter.IOuter_Inner.TypedServer`.

Client build closures run on the caller's actor, including MainActor, before
the owned payload is sent to the connection actor. The generated default
isolation argument preserves this context; ordinary call sites need no actor
annotation or Sendable builder closure.

Interface fields return optional typed clients. Null pointers and capability
table holes return nil; invalid indexes throw. Imported, returned local and
pipelined clients retain their capability lifetime. A local server can be
wrapped using `Client(server:connection:)`. Foreign connection capabilities
are rejected before sending. Serialization keeps opaque capability tokens;
only CapnpRPC interprets them.

At this milestone, typed streaming schemas fail with
`UnsupportedTypedStreaming`; typed result-pipeline wrappers are still pending.
Existing erased streaming and low-level `RemotePromise` APIs remain available.

## Verification

`just typed-structs`, `just typed-rpc`, `just typed-driver` and
`just typed-rpc-cpp` exercise these paths. The C++ gate runs both RPC
directions against the independent reference implementation and explicitly
skips if the compiler is absent; its nightly invocation requires C++.
The plan records gate counts, provenance and deliberate failure checks.
