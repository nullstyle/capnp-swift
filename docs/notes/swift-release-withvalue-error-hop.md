# Swift -O: code resumes off its actor after an error leaves TaskLocal.withValue

Status: local reference, 2026-10-21. **Not reported.** Whether to report it
to the Swift project is the owner's call; a draft is at the end.
capnp-swift works around it since 0.1.4 (below).

## Summary

In an optimized build, code that is isolated to an actor can continue
**off** that actor after an error propagates out of `TaskLocal.withValue`.
The next isolation check fails: `preconditionIsolated` aborts with
"Incorrect actor executor assumption", and a custom executor's
`checkIsolated` traps. Debug builds behave correctly.

It needs all four of these (removing any one avoids it):

1. The error leaves `TaskLocal.withValue` (the operation throws).
2. The operation calls a **protocol requirement** (through an existential
   or a generic) that takes an `isolated` actor parameter.
3. That requirement's implementation awaits a **nonisolated** async
   function, and that function throws.
4. Optimization (`-O`, `swift build -c release`).

Not needed: a custom executor (a default actor fails too) or a `Task` (an
async actor method fails too).

## Toolchain

- Xcode 27.0 (27A266a).
- Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1),
  swift-driver 1.168.6, target arm64-apple-macosx27.0.0.
- macOS 27.0.1 (26A434), arm64.

Not checked on other toolchains. The hosted CI runs `just release-test`
with the capnp-swift fix in place, so it does not show whether its
toolchain has the defect.

## Reproducer

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hop",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "hop")]
)
```

`Sources/hop/main.swift`:

```swift
// swift build -c release && .build/release/hop   traps: the catch runs off the actor
// swift build && .build/debug/hop                prints OK

enum Context {
    @TaskLocal static var value: Int?
}

struct Failure: Error {}

nonisolated func fail() async throws {
    throw Failure()
}

protocol Handler: Sendable {
    func handle(on worker: isolated Worker) async throws
}

struct ThrowingHandler: Handler {
    func handle(on worker: isolated Worker) async throws {
        try await fail()
    }
}

actor Worker {
    func run(_ handler: any Handler) async {
        do {
            try await Context.$value.withValue(1) {
                try await handler.handle(on: self)
            }
        } catch {
            preconditionIsolated("the catch ran off the actor")
        }
        print("OK")
    }
}

await Worker().run(ThrowingHandler())
```

Debug prints `OK`. Release prints `Incorrect actor executor assumption;
expected 'hop.Worker' executor.` and aborts (SIGABRT, exit 134).

## Reduction

A larger harness ran each variant as its own process. Every variant passes
in Debug. Release results:

| Variant | What changes | Release |
|---|---|---|
| existential | withValue; `any Handler` requirement with an `isolated` parameter; it awaits a nonisolated function that throws (custom executor, in a `Task`) | **off the actor** (trap) |
| generic-handler | the same through `H: Handler` | **off the actor** (trap) |
| method-not-task | the same in an async actor method, no `Task` | **off the actor** (trap) |
| default-actor-existential | the same on a default actor | **off the actor** (abort) |
| existential-no-withValue | no withValue | on the actor |
| existential-direct-throw | the requirement throws directly (no nonisolated await) | on the actor |
| concrete-handler | a direct call on the concrete type, not through the protocol | on the actor |
| full | a free function with an `isolated` parameter, not a requirement | on the actor |
| nonisolated-in-op | the operation awaits the nonisolated function itself | on the actor |
| existential-own-isolation-fn | a look-alike `func f<R>(_ op: () async throws -> R, isolation: isolated (any Actor)? = #isolation) async rethrows -> R` instead of withValue | on the actor |
| existential-own-isolation-defer | the look-alike plus `defer { opaque() }` | on the actor |
| result-inside | the operation catches and returns a `Result` (the capnp-swift fix) | on the actor |

The off-actor variants print `com.apple.root.default-qos.cooperative` as
the current dispatch queue at the `catch` (`__dispatch_queue_get_label`),
where the custom executor's queue was expected.

## In capnp-swift

0.1.3 added a task-local around each inbound call
(`RPCConnection.handleInboundCall`, for own-export lookups), with the shape
above: `ExportHandler.handle(_:on: isolated RPCConnection)` is a protocol
requirement, and every generated server's `handle` awaits a nonisolated
server method. When that method threw, `complete` ran off the actor, and
the isolation check inside `sendException` trapped (SIGTRAP) in Release
builds. 0.1.4 catches the error inside the task-local operation, and
`completeOnQueue` moves `complete` onto the connection's queue if a task
resumes elsewhere. `Tests/CapnpRPCTests/ReleaseIsolationTests.swift` holds
3 cases, run in Release by `just release-test` (CI). See `CHANGELOG.md`
("Fixed") and plan §8 "capnp-zig v0.28.0 adoption and a 0.1.3 Release crash".

## Draft issue text (not filed)

> **Title:** `-O`: actor-isolated code resumes off its actor after an error
> propagates out of `TaskLocal.withValue` through a protocol requirement
> with an `isolated` parameter
>
> In an optimized build, after an error propagates out of
> `TaskLocal.withValue`, the code after it (here the `catch`) does not run
> on the actor it is isolated to. `preconditionIsolated` then fails with
> "Incorrect actor executor assumption" (a custom executor's
> `checkIsolated` traps instead). With `-Onone` it runs on the actor.
>
> It needs: the operation calls a protocol requirement (existential or
> generic) that takes an `isolated` parameter of that actor; the
> implementation awaits a nonisolated async function that throws. A direct
> call on the concrete type, a free function with an `isolated` parameter,
> an implementation that throws without awaiting, no `withValue`, or a
> look-alike function with the same `isolation: isolated (any Actor)? =
> #isolation` parameter all avoid it. A default actor and an async actor
> method are enough (no custom executor, no `Task`).
>
> Reproducer: the 35-line package above. Expected: `OK` in both
> configurations. Actual: `swift build -c release && .build/release/hop`
> aborts with "Incorrect actor executor assumption; expected 'hop.Worker'
> executor."
>
> Environment: Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1),
> macOS 27.0.1, arm64.
