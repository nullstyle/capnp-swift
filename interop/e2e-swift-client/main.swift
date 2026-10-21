// e2e-swift-client: the capnp-swift side of the M4 interop matrix (plan
// §8), following capnp-zig's e2e CLI contract:
//
//   e2e-swift-client --host 127.0.0.1 --port 4700 --schema <name>
//
// Runs the scenario's call choreography against the server, printing one
// TAP line per assertion (`ok N - desc` / `not ok N - desc`), the plan
// `1..N` at the end, and exiting 0 iff every assertion passed. The
// assertions mirror the Zig client's (tests/e2e/zig/main_client.zig).

import Capnp
import CapnpE2E
import CapnpNW
import CapnpRPC
import Foundation

nonisolated(unsafe) var tapCount = 0
nonisolated(unsafe) var tapFailures = 0

func tap(_ ok: Bool, _ name: String) {
    tapCount += 1
    if ok {
        print("ok \(tapCount) - \(name)")
    } else {
        tapFailures += 1
        print("not ok \(tapCount) - \(name)")
    }
}

var host = "127.0.0.1"
var port: UInt16 = 4000
var schema = "game_world"
var useQuic = false
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--host": host = args.removeFirst()
    case "--port": port = UInt16(args.removeFirst()) ?? 4000
    case "--schema": schema = args.removeFirst()
    case "--transport":
        let v = args.removeFirst()
        if v == "quic" { useQuic = true } else if v != "tcp" {
            FileHandle.standardError.write(Data("e2e-swift-client: unknown transport \(v)\n".utf8))
            exit(2)
        }
    case "--help", "-h":
        print("Usage: e2e-swift-client [--host 127.0.0.1] [--port 4000] [--schema game_world|chat|inventory|matchmaking|resolve_disembargo|pass_back|pipelined_params|pipelined_params_deferred] [--transport tcp|quic]")
        exit(0)
    default: break
    }
}

do {
    let transport: any Transport
    var options = RPCConnection.Options()
    if useQuic {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            FileHandle.standardError.write(Data("e2e-swift-client: --transport quic needs macOS 26\n".utf8))
            exit(2)
        }
        // The harness's zig QUIC peer serves the test fixture certificate
        // (Tests/fixtures/tls); pin it. The Swift QUIC transport has no
        // skip-verification mode by design.
        let der = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/fixtures/tls/test-cert.der")
        transport = QUICTransport(host: host, port: port, trust: .testOnlyTrustThisCertificate(try! Data(contentsOf: der)), connectTimeout: .seconds(10))
        options.framing = .u32LE
    } else if let unixPath = host.hasPrefix("unix:") ? String(host.dropFirst("unix:".count)) : nil {
        transport = UnixTransport(path: unixPath, connectTimeout: .seconds(10))
    } else {
        transport = TCPTransport(host: host, port: port, connectTimeout: .seconds(10))
    }
    let connection = try await RPCConnection.connect(transport: transport, options: options)

    switch schema {
    case "game_world": try await gameWorld(connection)
    case "chat": try await chat(connection)
    case "inventory": try await inventory(connection)
    case "matchmaking": try await matchmaking(connection)
    case "resolve_disembargo": try await resolveDisembargo(connection)
    case "pass_back": try await passBack(connection)
    case "pipelined_params", "pipelined_params_deferred": try await pipelinedParams(connection)
    default:
        FileHandle.standardError.write(Data("e2e-swift-client: unknown schema \(schema)\n".utf8))
        exit(2)
    }
    await connection.close()
} catch {
    // A scenario-level abort records one failed assertion so the run is
    // never silent.
    tap(false, "scenario aborted: \(error)")
}

print("1..\(tapCount)")
exit(tapFailures == 0 && tapCount > 0 ? 0 : 1)

// MARK: - game_world

func gameWorld(_ connection: RPCConnection) async throws {
    let world = GameWorld.Client(cap: try await connection.bootstrap(), connection: connection)

    let spawned = try await world.spawnEntity { p in
        var request = p.initRequest()
        request.kind = .player
        request.setName("ZigClientHero")
        var pos = request.initPosition()
        pos.x = 10; pos.y = 20; pos.z = 30
        request.faction = .alliance
        request.maxHealth = 100
    }
    let entity = spawned.entity
    tap(spawned.status == .ok, "spawnEntity returns ok status")
    tap((try? entity.name()) == "ZigClientHero", "spawnEntity returns expected name")
    tap(entity.id.id != 0, "spawnEntity returns non-zero entity id")
    let spawnedId = entity.id.id

    let fetched = try await world.getEntity { p in
        var id = p.initId()
        id.id = spawnedId
    }
    tap(fetched.status == .ok, "getEntity finds the spawned entity")
    tap((try? fetched.entity.name()) == "ZigClientHero", "getEntity returns the spawned entity name")
    tap(fetched.entity.alive, "getEntity reports the entity alive")

    let damaged = try await world.damageEntity { p in
        var id = p.initId()
        id.id = spawnedId
        p.amount = 150
    }
    tap(damaged.status == .ok, "damageEntity returns ok status")
    tap(damaged.killed, "damageEntity reports the entity killed")
    tap(damaged.entity.health == 0 && !damaged.entity.alive, "damageEntity leaves the entity dead at zero health")
}

// MARK: - chat

func chat(_ connection: RPCConnection) async throws {
    let service = ChatService.Client(cap: try await connection.bootstrap(), connection: connection)

    var createCall = try await service.sendCreateRoom { p in
        p.setName("general")
        p.setTopic("General chat from the Swift e2e client")
    }
    let created = try await createCall.value()
    tap(created.status == .ok, "createRoom returns ok status")
    tap((try? created.info.name()) == "general", "createRoom returns expected room info name")
    let room = created.room(createCall.resultCaps, on: connection)
    tap(room != nil, "createRoom returns imported ChatRoom capability")
        guard let roomValue = room else { return }
    var roomHandle: ChatRoom.Client? = roomValue

    let sent = try await roomHandle!.sendMessage { p in
        p.setContent("Hello from the Swift e2e client")
    }
    tap(sent.status == .ok, "room sendMessage returns ok status")
    tap((try? sent.message.content()) == "Hello from the Swift e2e client", "room sendMessage echoes the message content")

    let info = try await roomHandle!.getInfo()
    tap((try? info.info.name()) == "general", "room getInfo returns expected room name")

    let left = try await roomHandle!.leave()
    tap(left.status == .ok, "room leave returns ok status")

    // Drop the only handle on the room capability: its CapRef deinits, the
    // Release goes out, and the service cap must keep working.
    roomHandle = nil
    try await Task.sleep(for: .milliseconds(100))

    let rooms = try await service.listRooms()
    let list = try rooms.rooms()
    tap(list != nil && list!.count >= 1, "listRooms still lists the room after room release")
}

// MARK: - inventory

func inventory(_ connection: RPCConnection) async throws {
    let service = InventoryService.Client(cap: try await connection.bootstrap(), connection: connection)

    let inv = try await service.getInventory { p in
        var id = p.initPlayer()
        id.id = 42
    }
    tap(inv.status == .ok, "getInventory returns ok status")
    tap(inv.inventory.usedSlots == 0, "new inventory has zero used slots")

    var tradeCall = try await service.sendStartTrade { p in
        var initiator = p.initInitiator()
        initiator.id = 42
        var target = p.initTarget()
        target.id = 99
    }
    let trade = try await tradeCall.value()
    tap(trade.status == .ok, "startTrade returns ok status")
    let session = trade.session(tradeCall.resultCaps, on: connection)
    tap(session != nil, "startTrade returns imported TradeSession capability")
    guard let session else { return }

    let state = try await session.getState()
    tap(state.state == .proposing, "trade session starts in proposing state")

    let accepted = try await session.accept()
    tap(accepted.status == .ok, "trade accept returns ok status")

    let cancelled = try await session.cancel()
    tap(cancelled.state == .cancelled, "trade cancel reports cancelled state")
}

// MARK: - matchmaking (pipelining)

func matchmaking(_ connection: RPCConnection) async throws {
    let service = MatchmakingService.Client(cap: try await connection.bootstrap(), connection: connection)

    let enqueued = try await service.enqueue { p in
        var player = p.initPlayer()
        var id = player.initId()
        id.id = 1
        player.setName("ZigQueuePlayer")
        player.faction = .alliance
        player.level = 60
        p.mode = .duel
    }
    tap(enqueued.status == .ok, "enqueue returns ok status")
    tap(enqueued.ticket.ticketId != 0, "enqueue returns a non-zero ticket id")

    // The key exercise: issue calls on the PROMISED controller before
    // findMatch's Return arrives.
    var findCall = try await service.sendFindMatch { p in
        var player = p.initPlayer()
        var id = player.initId()
        id.id = 1
        player.setName("ZigQueuePlayer")
        player.faction = .alliance
        player.level = 60
        p.mode = .duel
    }
    // Copy the pipelined client out of the call wrapper before spawning:
    // value() mutates findCall, which would trip region isolation.
    let pipelinedController = findCall.controller
    let signalReadyTask = Task { try await pipelinedController.signalReady { p in
        var id = p.initPlayer()
        id.id = 1
    } }
    let getInfoTask = Task { try await pipelinedController.getInfo() }
    try await Task.sleep(for: .milliseconds(100)) // both go out while unresolved
    tap(true, "pipelined calls issued before findMatch resolved")

    let found = try await findCall.value()
    tap(found.matchId.id != 0, "findMatch returns a non-zero match id")
    let controller = found.controller(findCall.resultCaps, on: connection)
    tap(controller != nil, "findMatch returns imported MatchController capability")

    let signaled = try await signalReadyTask.value
    tap(signaled.status == .ok, "pipelined signalReady returns ok status")

    let info = try await getInfoTask.value
    let teamA = try info.info.teamA()
    tap(teamA != nil && teamA!.count >= 1, "pipelined getInfo returns populated match info")
    tap(info.info.id.id == found.matchId.id, "pipelined getInfo observed the same match as findMatch")

    guard let controller else { return }
    let cancelled = try await controller.cancelMatch()
    tap(cancelled.status == .ok, "cancelMatch on resolved controller returns ok status")
}

// MARK: - resolve_disembargo (promise export + embargo)

final class CallSequenceCounter: CallSequence.Server, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt32 = 0
    private(set) var invocations: [UInt32] = []

    func getNumber(params: CallSequence.GetNumberParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> CallSequence.GetNumberResults {
        lock.withLock {
            let n = next
            next += 1
            invocations.append(n)
        }
        return CallSequence.GetNumberResults { r in r.n = lock.withLock { invocations.last ?? 0 } }
    }
}

func resolveDisembargo(_ connection: RPCConnection) async throws {
    let reflector = Reflector.Client(cap: try await connection.bootstrap(), connection: connection)

    // Host a CallSequence and pass it as reflect's target.
    let counter = CallSequenceCounter()
    var reflectCall = try await reflector.sendReflect { p in
        p.setTarget(counter)
    }

    // Pipeline getNumber on the still-unresolved promise: it parks at the
    // reflector until resolveNow resolves the promise back to our cap.
    let promisedCap = reflectCall.promise
    let pipelinedGet = Task { try await promisedCap.getNumber() }
    try await Task.sleep(for: .milliseconds(50))
    tap(true, "pipelined getNumber issued before resolution (parked)")

    let reflectResults = try await reflectCall.value()
    tap(reflectResults.promise(reflectCall.resultCaps, on: connection) != nil, "reflect returns imported promise capability")

    _ = try await reflector.resolveNow()

    let pipelined = try await pipelinedGet.value
    tap(pipelined.n == 0, "pipelined getNumber reached CallSequence with n==0")
    tap(true, "resolveNow completed")

    // Direct call on the resolved import.
    guard let resolved = reflectResults.promise(reflectCall.resultCaps, on: connection) else { return }
    let direct = try await resolved.getNumber()
    tap(direct.n == 1, "direct getNumber returned n==1")

    // The pipelined call arrived before the direct one (the embargo held).
    let seen = counter.invocations
    tap(seen.count >= 2 && seen[0] == 0 && seen[1] == 1, "pipelined getNumber reached CallSequence before the direct call")

    // invokeCap: the server calls our second cap once.
    let cbCounter = CallSequenceCounter()
    let invoked = try await reflector.invokeCap { p in
        p.setCb(cbCounter)
    }
    tap(cbCounter.invocations.count == 1, "server invoked the client-supplied cap exactly once")
    tap(invoked.observed == (cbCounter.invocations.first ?? 99), "server-observed invokeCap value matches the client cap's returned value")

    // disconnectNow: the server closes its transport; this open call must
    // fail with a disconnect-class error.
    var disconnectClass = false
    do {
        _ = try await reflector.disconnectNow()
    } catch let error as RPCError {
        if case .disconnected = error { disconnectClass = true }
    }
    tap(disconnectClass, "disconnectNow observes a disconnect-class error")
}

// MARK: - pass_back and pipelined_params (cap_passing.capnp)
//
// The generated setters can only export a NEW server into a capability
// field. To pass a capability the client already holds (an import, or a
// pipelined result), these calls build the params by hand: pointer field 0
// is capability 0, and the one cap slot names the capability.

enum CapPassing {
    /// Every TokenHost's mintFail() reason contains this text.
    static let mintFailMarker = "deliberate mint failure"
}

/// A params struct (no data, one pointer) whose field 0 is capability 0.
func tokenParams() -> [UInt8] {
    let mb = MessageBuilder()
    mb.initRoot(dataWords: 0, pointerWords: 1).setCapability(0, capIndex: 0)
    return mb.toBytes()
}

func hasMintFailMarker(_ error: any Error) -> Bool {
    guard case .failed(let reason) = error as? RPCError else { return false }
    return reason.contains(CapPassing.mintFailMarker)
}

/// A Token this client hosts: tag() returns its tag and counts the call.
/// It serves both the legacy and the typed bindings.
final class ClientToken: Token.Server, Token.TypedServer, @unchecked Sendable {
    let tagValue: UInt32
    private let lock = NSLock()
    private var count: UInt32 = 0

    init(tag: UInt32) { tagValue = tag }

    var calls: UInt32 { lock.withLock { count } }

    func tag(params: Token.TagParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Token.TagResults {
        lock.withLock { count += 1 }
        return Token.TagResults { r in r.tag = tagValue }
    }

    func tag(params: Token.Typed.TagParams.Reader, on connection: isolated RPCConnection) async throws -> Token.Typed.TagResults.Value {
        lock.withLock { count += 1 }
        return try Token.Typed.TagResults.Value { r in r.tag = tagValue }
    }
}

// pass_back: pass two minted Tokens back to check(). Each is an import, so
// the core writes it as `receiverHosted`, and the server must call its own
// Token. Then hand the server one of our own Tokens in echo(): it must
// come back as our own export, and tag() on it must run our own object.
func passBack(_ connection: RPCConnection) async throws {
    let hostCap = try await connection.bootstrap()
    let host = TokenHost.Client(cap: hostCap, connection: connection)

    for tag: UInt32 in [7, 8] {
        var mintCall = try await host.sendMint { $0.tag = tag }
        let minted = try await mintCall.value()
        let imported = minted.tokenCapIndex().flatMap { i -> CapRef? in
            guard Int(i) < mintCall.resultCaps.count, case .imported(let ref) = mintCall.resultCaps[Int(i)] else { return nil }
            return ref
        }
        tap(imported != nil, "mint(\(tag)) returns an imported Token")
        guard let imported else { return }

        let result = try await connection.call(host.target, interface: TokenHost.interfaceID, method: TokenHost.Method.check.rawValue, params: tokenParams(), caps: [.imported(imported)])
        let checked = try TokenHost.CheckResults.Reader(Message(bytes: result.message).rootStruct())
        tap(checked.tag == tag && checked.local, "check(minted Token \(tag)) called the server's own Token")
    }

    // echo(), legacy API: the Token must come back as one of our exports.
    let echoOnly = ClientToken(tag: 901)
    var echoCall = try await host.sendEcho { $0.setToken(echoOnly) }
    let echoed = try await echoCall.value()
    var cameHome = false
    if let i = echoed.tokenCapIndex(), Int(i) < echoCall.resultCaps.count, case .exported = echoCall.resultCaps[Int(i)] {
        cameHome = true
    }
    tap(cameHome, "echo returns the client's own Token")

    // echo(), typed API, to call the Token that came home. The legacy
    // reader returns no Client for one of our exports, and the server's
    // Release of echo()'s param can drop the export before this task runs,
    // so `connection.localHandler(forExport:)` can be nil here. A legacy
    // caller uses `CallResult.localHandler(forExport:)` (since M9) instead;
    // the typed reader keeps the handler it captured with the RETURN.
    let own = ClientToken(tag: 900)
    let typedHost = try TokenHost.Typed.Client(cap: hostCap, connection: connection)
    let ownClient = Token.Typed.Client(server: own, connection: connection)
    let typedEcho = try await typedHost.echo { try $0.setToken(ownClient) }
    var ranOwn = false
    if let home = try typedEcho.token() {
        let tagged = try await home.tag()
        ranOwn = tagged.tag == own.tagValue && own.calls == 1 && echoOnly.calls == 0
    }
    tap(ranOwn, "tag() on the echoed Token ran the client's own object")
}

// pipelined_params: pass the `token` of an unanswered mint() as check()'s
// param, then the same for mintFail(). The Swift runtime does not send that
// as `receiverAnswer`: it waits for the producing Return and passes the
// resolved capability (the H9 wait, plan §8 M2 item 4), because the native
// core, and so a Swift server, refuses a receiverAnswer for a pending
// answer. So check(mint().token) leaves one round trip later as
// `receiverHosted`, and check(mintFail().token) ends locally with
// mintFail()'s exception. The receiverAnswer wire shape is covered by the
// Zig and C++ clients.
//
// pipelined_params_deferred (capnp-zig v0.28.0): the same client against a
// Zig server that answers mint() and mintFail() on a later loop turn. The
// C++, Go, Python and Rust clients fail its two check() lines there (H9
// pending, an XFAIL row upstream); the H9 wait makes every line pass here.
func pipelinedParams(_ connection: RPCConnection) async throws {
    let host = TokenHost.Client(cap: try await connection.bootstrap(), connection: connection)

    var mintCall = try await host.sendMint { $0.tag = 11 }
    let mintToken = mintCall.question.pipeline([0])
    let check = Task { try await connection.call(host.target, interface: TokenHost.interfaceID, method: TokenHost.Method.check.rawValue, params: tokenParams(), caps: [.pipelined(mintToken)]) }
    var failCall = try await host.sendMintFail { $0.tag = 12 }
    let failToken = failCall.question.pipeline([0])
    let checkFail = Task { try await connection.call(host.target, interface: TokenHost.interfaceID, method: TokenHost.Method.check.rawValue, params: tokenParams(), caps: [.pipelined(failToken)]) }

    do {
        let result = try await check.value
        let checked = try TokenHost.CheckResults.Reader(Message(bytes: result.message).rootStruct())
        tap(checked.tag == 11 && checked.local, "check(pipelined mint().token) called the server's own Token")
    } catch {
        print("# check exception: \(error)")
        tap(false, "check(pipelined mint().token) called the server's own Token")
    }

    let minted = try? await mintCall.value()
    var imported = false
    if let i = minted?.tokenCapIndex(), Int(i) < mintCall.resultCaps.count, case .imported = mintCall.resultCaps[Int(i)] {
        imported = true
    }
    tap(imported, "mint() returns an imported Token")

    do {
        _ = try await failCall.value()
        tap(false, "mintFail() fails with its exception")
    } catch {
        tap(hasMintFailMarker(error), "mintFail() fails with its exception")
    }

    do {
        _ = try await checkFail.value
        tap(false, "check(pipelined mintFail().token) fails with mintFail()'s exception")
    } catch {
        print("# check(pipelined mintFail().token) exception: \(error)")
        tap(hasMintFailMarker(error), "check(pipelined mintFail().token) fails with mintFail()'s exception")
    }
}
