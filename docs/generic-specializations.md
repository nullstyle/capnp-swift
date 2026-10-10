# Concrete Swift generic specializations

Status: **EXECUTED PROTOTYPE 2026-10-10**. The separate tool in
`tools/type-resolver-spike/` generates typed Swift for concrete struct
applications using capnp-zig v0.23.0's public Experimental resolver.
The shipping generator remains on v0.21.0, and release 0.1.1 is unchanged.

## Interface exercised

Run `just type-resolver-specializations`. The tool reads a compiler request
and a concrete root, builds the reachable application graph, and returns
one Swift source file. Generated readers and builders use existing public
`Capnp` operations; no new runtime protocol or erased pointer codec is
required for this experiment.
The combined gate is also part of the core CI job. C++ checks run when the
reference compiler is installed and otherwise report their skip explicitly.

The synthetic root contains Box(Text), Box(Data), Box(Box(Text)),
Box(List(UInt16)), List(Box(Text)), Link(Text) with recursive next and
children, and both Outer(Text).Inner(Data) and Outer(Data).Inner(Text).
These produce eight applications with typed field operations. Text reads
return String, Data reads return [UInt8], and typed struct-list elements
retain their application's reader/builder type.

The generator supports pointer-only structs with Text, Data, concrete
struct fields, integer lists and concrete struct lists. It rejects groups,
unions, data sections, nonempty explicit defaults, unconstrained pointers,
unbound parameters, capability fields, nested pointer lists and other
unimplemented shapes. Field names currently require ASCII identifiers
beginning with a letter. Unsupported inputs fail before returning source;
the executable writes only a completely generated result.

## Application identity

A schema node ID identifies a declaration, not an application. The planner
enters a named type using its resolver context, then resolves a parameter
expression for each parameter of the node and its lexical parents. Its
canonical key contains the node ID, declaring scope IDs, parameter indexes,
and recursively resolved binding shapes. Brand spelling and caller-frame
indexes are absent from the key, because they describe how an application
was reached rather than its effective meaning.

Consequently Box(Text) reached through a field, a list or a nested binding
uses one application; Box(Data) uses another. Both bindings of a nested
Inner declaration contribute to its identity. Link(Text) is registered
before its fields are followed, so next and children reuse it. A schema
such as Grow(T).next :Grow(Box(T)) continually changes its application;
the planner refuses expansion beyond a supplied budget (default 256).
Resolver depth is 64; keys are bounded to 16 KiB with a recursive depth
limit as well. These limits prevent an infinite or exponentially growing
generation graph.

Contexts and resolved types remain local to generation and borrow the
request. The returned source owns its storage. Every resolved type is
passed back through its originating Context. Full request-node contexts
avoid the [H12 lookup defect](handoffs/H12-type-resolver-lexical-lookup.md).
No resolver internals or altered wire scope IDs are used.

Generated names are `AppN`, with `SpecializedRoot` as the selected root.
The numbering is local to one output and may change with traversal order.
It proves specialization, not a stable cross-file Swift naming contract.
Builders have the existing runtime's lifetime rule: keep MessageBuilder
alive while its StructBuilder-derived wrappers are in use. Readers own
their Message-backed storage and are Sendable.

## Evidence

The five Swift cases compile in Swift 6 mode with complete concurrency
checking and pass through generated operations. C++ Cap'n Proto 1.5.0
independently encodes the literal fixture value; the Swift reader verifies
that input. C++ then decodes the Swift builder's message, and canonical
decoded values match the independent fixture. Wire bytes may differ while
representing the same value. This is local macOS verification, with no
device-runtime claim.

A negative typecheck proves that Box(Text)'s generated setter rejects
[UInt8]. The same Swift build accepts that value in Box(Data). Four Zig
cases verify errors for unbound parameters, unsupported pointer shapes,
nonempty defaults and expanding applications. All 11 new checks were
individually ablated and restored byte-for-byte; all 12 Zig tests and the
restored Swift gate pass. The [probe README](../tools/type-resolver-spike/README.md)
records fixture provenance, regeneration and ablation logs.

## Decisions still needed for adoption

Concrete specialization gives callers typed operations without first
freezing a runtime pointer-value codec. It duplicates wrappers for each
application, requires an application naming/module contract, and covers
only reachable concrete uses. It cannot replace an open generic Swift
declaration that callers instantiate with new types in another module.

Before shipping either approach, decide how generic declarations and
nested applications are named across files, how erased uses remain
compatible, and what support method-local generic parameters receive.
Generic interface ancestors need branded identity, equal-diamond
deduplication, conflicting-application policy and dispatch semantics;
this struct prototype does not exercise those behaviors. Capabilities
also need cap-table ownership integrated with the generated RPC types.
The [research](handoffs/type-resolver-research.md) maps the existing Swift
seams and upstream primary sources for that work.
