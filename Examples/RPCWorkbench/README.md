# RPC Workbench

A native Mac/iPhone example for capnp-swift main. The Mac hosts TCP and
sample TLS listeners. Either app can make typed calls, receive capability
callbacks, stream updates, cancel a request and reconnect. The separate
Swift package keeps the same service/client code usable without a UI.

## Run the native apps

Open `RPCWorkbench.xcodeproj` in Xcode. Select **WorkbenchMac → My Mac**,
then Run. In the **RPC Workbench** window, press **Start server**, then
**Connect**. Press **Run all checks** to exercise seven RPC proofs.
**Send echo**, **Stream 12 updates**, **Slow request / Cancel request**, and
**Suspend and reconnect** can also be used individually.

For an iPhone, copy `Config/Signing.example.xcconfig` to the ignored
`Config/Signing.local.xcconfig` and set your Apple Developer team. Select
**WorkbenchIOS → your iPhone**, then Run. Keep the Mac server running.
Enter the Mac address shown in its window in the phone's **Mac host or
IP address** field. Allow the local-network prompt, then press **Connect**.
`127.0.0.1` is correct for the Mac/simulator; on a physical iPhone it means
that phone. The interactive controls are in the native app.

TCP uses port 41011; **Sample TLS** uses port 41012. Changing the transport
sets its port; reconnect to apply it. The app remembers a successful endpoint.
The TLS identity is a public test fixture, explicitly pinned by the client.
It is suitable only for this example. Supply your own identity/pins in a real app.

On iOS, background suspends the connection and foreground creates a new
session. **Suspend and reconnect** drives that same app path without leaving
the window. Canceling a slow request wakes the caller and cancels the
remote handler's `Task` (its `Task.sleep` ends early): the core reports the
caller's Finish, since capnp-zig v0.28.0.

## Generation and verification

From the repository root:

```sh
just workbench-generate
just workbench-check
just workbench-archive-check
just workbench-ablations
just workbench-mac
```

These commands never rebuild the XCFramework. The sample depends on the
local main package, whose core is the published release binary URL/checksum
named in the root `Package.swift` (0.1.2 since 2026-10-18).
Generated Swift is committed and must pass regeneration with `--check`.
The script builds the matching local driver and Zig plugin (through mise),
or uses an explicitly supplied standalone `CAPNPC_SWIFT_DRIVER`.

`workbench-check` requires two Swift Testing functions with three network
cases, and 21 CLI proofs: ten each over TCP/TLS, plus rejection of a wrong
TLS pin. The eleven distinct assertions were individually inverted, rebuilt,
failed by name and exactly restored. Logs go to a printed temporary path.

The archive gate builds and runs the committed sample from a clean checkout
named `source`, with the released remote core. The local dependency has an
explicit name so a renamed repository still resolves its products correctly.

The test schemas use an observer capability, `Session(Text)`, streaming input,
a delayed factory result, and a method-generic exchange. The client chooses
`Parcel.Typed<CapnpList<CapnpData>>` in a different Swift module; the server
keeps the deliberate erased method-generic handler. Calls and callbacks run
through public capnp-swift interfaces and actual Network.framework sockets.

See [validation](VALIDATION.md) for the precise Mac, simulator and physical
iPhone evidence, and [the sprint record](../../docs/sprint-real-app-2026-10-12.md).
