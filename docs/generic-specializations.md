# Concrete Swift generic specializations

Status: **EXECUTED PROTOTYPE 2026-10-10**. The separate tool in
`tools/type-resolver-spike/` generates typed Swift for concrete struct and
interface applications using capnp-zig v0.23.0's public Experimental resolver.
The shipping generator remains on v0.21.0, and release 0.1.1 is unchanged.

## Interface exercised

Run `just type-resolver-rpc` for the combined struct and RPC gate, or `just
type-resolver-specializations` for the serialization slice. The tool reads a
compiler request and a concrete root, builds the reachable application graph,
and returns one Swift source file. Generated readers and builders use existing
public `Capnp` operations; no new runtime protocol or erased pointer codec is
required for this experiment. The combined gate is also part of the core CI
job. C++ checks run when the reference compiler is installed and otherwise
report their skip explicitly.

The synthetic root contains Box(Text), Box(Data), Box(Box(Text)),
Box(List(UInt16)), List(Box(Text)), Link(Text) with recursive next and
children, and both Outer(Text).Inner(Data) and Outer(Data).Inner(Text). These
produce eight applications with typed field operations. Text reads return
String, Data reads return [UInt8], and typed struct-list elements retain their
application's reader/builder type.

The generator supports pointer-only structs with Text, Data, concrete struct
and capability fields, integer lists and concrete struct lists. It rejects
groups, unions, data sections, nonempty explicit defaults, unconstrained
pointers, unbound parameters, nested pointer lists and other unimplemented
shapes. Field names currently require ASCII identifiers beginning with a
letter, with generated member names reserved. Unsupported inputs fail before
returning source; the executable writes only a completely generated result.

## Application identity

A schema node ID identifies a declaration, not an application. The planner
enters a named type using its resolver context, then resolves a parameter
expression for each parameter of the node and its lexical parents. Its
canonical key contains the node ID, declaring scope IDs, parameter indexes,
and recursively resolved binding shapes. Brand spelling and caller-frame
indexes are absent from the key, because they describe how an application was
reached rather than its effective meaning.

Consequently Box(Text) reached through a field, a list or a nested binding
uses one application; Box(Data) uses another. Both bindings of a nested Inner
declaration contribute to its identity. Link(Text) is registered before its
fields are followed, so next and children reuse it. A schema such as
Grow(T).next :Grow(Box(T)) continually changes its application; the planner
refuses expansion beyond a supplied budget (default 256). Resolver depth is
64; keys are bounded to 16 KiB with a recursive depth limit as well. These
limits prevent an infinite or exponentially growing generation graph.

Contexts and resolved types remain local to generation and borrow the request.
The returned source owns its storage. Every resolved type is passed back
through its originating Context. Full request-node contexts avoid the [H12
lookup defect](handoffs/H12-type-resolver-lexical-lookup.md). No resolver
internals or altered wire scope IDs are used.

Generated names are `AppN`, with `SpecializedRoot` as the selected root. The
numbering is local to one output and may change with traversal order. It
proves specialization, not a stable cross-file Swift naming contract. Builders
have the existing runtime's lifetime rule: keep MessageBuilder alive while its
StructBuilder-derived wrappers are in use. Readers own their Message-backed
storage and are Sendable. RPC readers also retain their payload capability
table, including when descending into a struct or list. RPC builders share a
capability collector across those same descendants.

## Concrete RPC and inheritance

The RPC fixture generates a typed `Server`, `Client`, and `Export` for
reachable interface applications. Clients expose `super0`, `super1`, etc. as
typed direct-parent views. Calls through those views use the ancestor's wire
interface ID and method ordinal. Server protocols inherit the same specialized
ancestor protocols; exports dispatch over the transitive closure. Unknown
interface IDs and ordinals throw `RPCError.unimplemented`.

Anonymous method payloads have wire `scope_id = 0`. Their application key must
nevertheless include the owning interface's effective lexical bindings. The
planner discovers that owner from the complete request's method table, then
uses public resolver operations to obtain bindings. Otherwise Base(Text) and
Base(Data) would collide on their shared payload node IDs. Named payloads such
as Box(T) enter with the method's parameter/result brand. Nested
Outer(Text).Inner payloads retain Outer's Text binding through the H12
full-node workaround.

Equal branded diamond ancestors share one application and one export switch
case. A Diamond(Text) server implements Base(Text) once. Unrelated interfaces
with the same method name use separate typed payload overloads and wire IDs. A
closure containing Base(Text) and Base(Data) is rejected with
`ConflictingInheritedApplication`: the wire call has an interface ID and
ordinal, but no application brand to distinguish those two interpretations.
Separate capabilities may each export one of those applications. Malformed
inheritance cycles are rejected before application reuse.

Payload `Value` wrappers own bytes and outgoing `CapSlot`s. Capability setters
accept the corresponding specialized server or client; nested builders append
to one shared table and write global table indexes. A received capability
getter creates a typed client on the supplied connection, retaining its
`CapRef` independently of the result reader. The runtime still checks
connection ownership. Null entries return nil; invalid table indexes throw.
Local capabilities returned as `.exported` entries currently throw an explicit
unimplemented error. Method-local generics and streaming methods are rejected;
typed promise/result pipelines and local capability views remain adoption
work.

## Evidence

The five Swift cases compile in Swift 6 mode with complete concurrency
checking and pass through generated operations. C++ Cap'n Proto 1.5.0
independently encodes the literal fixture value; the Swift reader verifies
that input. C++ then decodes the Swift builder's message, and canonical
decoded values match the independent fixture. Wire bytes may differ while
representing the same value. This is local macOS verification, with no
device-runtime claim.

A negative typecheck proves that Box(Text)'s generated setter rejects [UInt8].
The same Swift build accepts that value in Box(Data). Four Zig cases verify
errors for unbound parameters, unsupported pointer shapes, nonempty defaults
and expanding applications. All 11 new checks were individually ablated and
restored byte-for-byte; all 12 Zig tests and the restored Swift gate pass. The
[probe README](../tools/type-resolver-spike/README.md) records fixture
provenance, regeneration and ablation logs.

The RPC harness passes twelve named runtime checks over real LoopbackTransport
connections and the current macOS core archive, in Swift 6 complete
concurrency mode. It covers diamond/ancestor dispatch, Text and Data
applications sharing one declaration ID, same-name ancestors, named payloads,
nested lexical scope, callbacks, returned capability lifetime, nested and
struct-list capability tables, foreign connection rejection, and unknown
interface/method rejection. Two negative Swift typechecks reject an inherited
wrong binding and a missing ancestor method. Three new Zig checks reject
conflicting inherited applications, method-local generics and malformed
inheritance cycles, bringing the suite to 15/15. The RPC request is generated
with the pinned WasmKit compiler and compares byte-identically on
regeneration. The README records reproducible gates and individual ablation
evidence: all 17 new checks caught their intended named failures, every source
was restored byte-for-byte, and the restored combined gate passes.

The struct-list RPC case caught an existing builder bug: its list pointer
counted the tag word, which could exceed the native clone's segment bounds.
The builder now follows the [encoding
spec](https://capnproto.org/encoding.html#lists) and excludes the tag. A
shipping runtime test compares exact independent C++ bytes; reintroducing the
old formula reproduces the RPC refusal.

## Decisions still needed for adoption

Concrete specialization gives callers typed operations without first freezing
a runtime pointer-value codec. It duplicates wrappers for each application,
requires an application naming/module contract, and covers only reachable
concrete uses. It cannot replace an open generic Swift declaration that
callers instantiate with new types in another module.

Before shipping either approach, decide how generic declarations and nested
applications are named across files, how erased uses remain compatible, and
what support method-local generic parameters receive. The prototype exercises
branded ancestor identity, equal-diamond deduplication, conflict rejection,
dispatch and capability ownership. Shipping these choices still requires a
stable application/module naming contract and an explicit compatibility policy
for erased generic uses, method generics, local capability views, streaming
and typed pipelines. The [research](handoffs/type-resolver-research.md) maps
the existing Swift seams and upstream primary sources for that work.
