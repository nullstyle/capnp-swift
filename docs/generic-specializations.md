# Concrete Swift generic specializations

Status: **EXECUTED PROTOTYPE 2026-10-12**. The separate tool in
`tools/type-resolver-spike/` generates typed Swift for concrete struct and
interface applications using capnp-zig v0.23.0's public Experimental resolver.
The production generator now also uses v0.23.0, with byte-identical legacy
output; typed output remains in this optional tool. Release 0.1.1 is unchanged.

## Interface exercised

Run `just type-resolver-methods` for the complete prototype gate.
`just type-resolver-rpc` selects the struct and concrete RPC slices;
`just type-resolver-specializations` selects the serialization slice. The tool reads a
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
unimplemented error. Method-local generics require explicit method profiles,
as described below; streaming methods are rejected. Typed promise/result
pipelines and local capability views remain adoption work.

## Method-local arguments and erased servers

Method-local generics now have an opt-in concrete client path and an erased
server path. Run the tool with `--methods <profiles.json>`. Each profile selects
an interface declaration and method by name, then lists named call-site cases
whose arguments refer to fields of the selected root. For example:

```json
[
  {"interface": ":Parent", "method": "echo", "cases": [
    {"name": "Text", "arguments": ["text"]},
    {"name": "Data", "arguments": ["data"]}
  ]}
]
```

The root's text and data fields supply schema type expressions. The generator
materializes their effective lexical bindings into closed brands through the
public resolver before entering a method payload; a Context token is never
moved between unrelated contexts. Cases generate `echoAsText`, `echoAsData`,
etc. with concrete builders and readers. Both call the original interface ID
and method ordinal. Case labels and bindings are code-generation input only;
the RPC envelope carries no private type discriminator.

The server implements one `echo` using erased method fields represented by
`SpecializedPointer`. Its declared structure and any enclosing interface
bindings remain typed. Anonymous payload parameters are recognized only on
zero-scope method payload nodes. Named payload brands refer to implicit method
indexes. Both identities include owner interface ID, ordinal, and argument
index, so parameter/result views agree without conflating unrelated unbound
node parameters. For concrete cases, the consumer constructs a scoped payload
brand or substitutes implicit references in the method brand, then validates
and resolves it through the public facade. The request graph and wire scope
IDs are never rewritten.

The inherited `Parent(Outer).echo[T]` fixture keeps Outer = Text while T varies
across Text, Data, List(UInt16), Box(Text), and List(Box(Text)). Its params and
results use different pointer positions, proving field copying rather than
whole-payload reuse. Named Box(T) payloads substitute implicit arguments;
Swap[A,B] keeps two arguments distinct in reversed results. `List(Box(T))`
payloads let the erased server traverse the declared Box structure and copy
its unknown values. The pinned compiler rejects bare List(T), which becomes
unsupported List(AnyPointer); the fixture uses the legal Box wrapper.

`swift/ProbePointer.swift` is compiled only into the probe's temporary Capnp
module. It is not part of the package's runtime interface. It borrows immutable
message storage, follows far/double-far pointers, and copies reachable structs
and lists while remapping capability indexes. It preserves raw byte lists
without guessing Text versus Data, bounds-checks contents, and applies depth
and copy budgets. The generated erased value also retains its received cap
table. Imported entries can be forwarded; locally exported entries currently
throw an explicit unimplemented error. This is an experiment in server erasure,
not a published pointer codec or open Swift generic declaration.

Invalid case arity, duplicate names, missing root fields, erased arguments,
unreachable profiles, and generated-name collisions fail before writing
source. Profiles have a total budget of 64 cases, in addition to the existing
application/depth/key limits. A method with implicit arguments and no selected
profile retains the default `UnsupportedMethodGenerics` error. No inference
or new upstream method-binding interface is assumed.

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

The method slice adds 14 named Swift runtime checks: same-capability Text/Data,
outer binding and changed payload layout, null defaults, integer lists, nested
structs, struct lists, named brands, two reversed arguments, generic values in
Box lists, and private copier budget/extent/cycle/capability/double-far checks.
Two shell gates verify a wrong-binding typecheck and atomic CLI rejection.
Seven new Zig cases validate profiles and parameter scope isolation, bringing
the suite to 22/22. All 23 new gates were individually ablated with named
failures, restored byte-for-byte, and rerun successfully. The original
struct-only and concrete RPC generated files remain byte-identical. C++ 1.5.0
code generation independently shows erased AnyPointer method server contexts;
this slice's transport proof is Swift loopback RPC, not a C++ peer pairing.

## Decisions still needed for adoption

Concrete specialization gives callers typed operations without first freezing
a runtime pointer-value codec. It duplicates wrappers for each application,
requires an application naming/module contract, and covers only reachable
concrete uses. It cannot replace an open generic Swift declaration that
callers instantiate with new types in another module.

Before shipping either approach, decide how generic declarations and nested
applications are named across files, how erased uses remain compatible, and
how method cases and erased server values become a stable interface. The prototype exercises
branded ancestor identity, equal-diamond deduplication, conflict rejection,
dispatch and capability ownership. Shipping these choices still requires a
stable application/module naming contract and an explicit compatibility policy
for erased generic uses, open method call-site types, local capability views, streaming
and typed pipelines. The [research](handoffs/type-resolver-research.md) maps
the existing Swift seams and upstream primary sources for that work.
