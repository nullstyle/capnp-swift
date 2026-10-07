// e2e-swift-server: the capnp-swift side of the M4 interop matrix (plan
// §8), following capnp-zig's e2e CLI contract:
//
//   e2e-swift-server --host 0.0.0.0 --port 4700 --schema <name>
//
// Serves the scenario's bootstrap interface until killed. Prints READY to
// stderr once listening (the docker runner's unix lane greps it; the local
// harness only probes the port). Tolerates the harness's bare connect
// probe (a connection that closes before the first frame).

import Capnp
import CapnpE2E
import CapnpNW
import CapnpRPC
import Foundation
import Synchronization

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

let schemas = ["game_world", "chat", "inventory", "matchmaking", "resolve_disembargo"]

var host = "0.0.0.0"
var port: UInt16 = 4700
var schema = "game_world"
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--host": host = args.removeFirst()
    case "--port": port = UInt16(args.removeFirst()) ?? 4700
    case "--schema": schema = args.removeFirst()
    case "--help", "-h":
        print("Usage: e2e-swift-server [--host 0.0.0.0] [--port 4700] [--schema \(schemas.joined(separator: "|"))]")
        exit(0)
    default: break
    }
}
guard schemas.contains(schema) else {
    FileHandle.standardError.write(Data("e2e-swift-server: unknown schema \(schema)\n".utf8))
    exit(2)
}
let bootstrap: @Sendable () -> any ExportHandler
switch schema {
case "game_world": bootstrap = { GameWorld.Export(GameWorldService()) }
case "chat": bootstrap = { ChatService.Export(ChatServiceState()) }
case "inventory": bootstrap = { InventoryService.Export(InventoryServiceState()) }
case "matchmaking": bootstrap = { MatchmakingService.Export(MatchmakingServiceState()) }
case "resolve_disembargo": bootstrap = { Reflector.Export(ReflectorService()) }
default: fatalError("unreachable")
}

do {
    let listener: RPCListener
    var servingOn = "port \(port)"
    if let unixPath = host.hasPrefix("unix:") ? String(host.dropFirst("unix:".count)) : nil {
        listener = try RPCListener(unixPath: unixPath, bootstrap: bootstrap)
        servingOn = "unix:\(unixPath)"
    } else {
        listener = try RPCListener(port: port, bootstrap: bootstrap)
    }
    _ = try await listener.start()
    FileHandle.standardError.write(Data("READY\n".utf8))
    FileHandle.standardError.write(Data("e2e-swift-server: \(schema) on \(servingOn)\n".utf8))
    // Serve until killed.
    while true {
        try await Task.sleep(for: .seconds(3600))
    }
} catch {
    FileHandle.standardError.write(Data("e2e-swift-server: \(error)\n".utf8))
    exit(1)
}
exit(0)

// MARK: - game_world

/// Plain-value snapshots of the schema structs the service keeps around.
struct StoredEntity {
    var id: UInt64
    var kind: EntityKind
    var name: String
    var x: Float32, y: Float32, z: Float32
    var health: Int32
    var maxHealth: Int32
    var faction: Faction
    var alive: Bool
}

func writeEntity(_ e: StoredEntity, into b: inout Entity.Builder) {
    var id = b.initId()
    id.id = e.id
    b.kind = e.kind
    b.setName(e.name)
    var pos = b.initPosition()
    pos.x = e.x
    pos.y = e.y
    pos.z = e.z
    b.health = e.health
    b.maxHealth = e.maxHealth
    b.faction = e.faction
    b.alive = e.alive
}

final class GameWorldService: GameWorld.Server, @unchecked Sendable {
    private let lock = NSLock()
    private var entities: [UInt64: StoredEntity] = [:]
    private var nextId: UInt64 = 1

    private func withState<T>(_ body: (inout [UInt64: StoredEntity], inout UInt64) throws -> T) rethrows -> T {
        try lock.withLock {
            var entities = self.entities
            var next = self.nextId
            defer { self.entities = entities; self.nextId = next }
            return try body(&entities, &next)
        }
    }

    func spawnEntity(params: GameWorld.SpawnEntityParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> GameWorld.SpawnEntityResults {
        let request = params.request
        let id = withState { _, next in next }
        let entity = StoredEntity(
            id: id, kind: request.kind, name: (try? request.name()) ?? "",
            x: request.position.x, y: request.position.y, z: request.position.z,
            health: request.maxHealth, maxHealth: request.maxHealth,
            faction: request.faction, alive: true)
        _ = withState { entities, next in
            entities[id] = entity
            next += 1
        }
        return GameWorld.SpawnEntityResults { r in
            var out = r.initEntity()
            writeEntity(entity, into: &out)
            r.status = .ok
        }
    }

    func despawnEntity(params: GameWorld.DespawnEntityParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> GameWorld.DespawnEntityResults {
        let id = params.id.id
        let found = withState { entities, _ in entities.removeValue(forKey: id) != nil }
        return GameWorld.DespawnEntityResults { r in r.status = found ? .ok : .notFound }
    }

    func getEntity(params: GameWorld.GetEntityParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> GameWorld.GetEntityResults {
        let id = params.id.id
        let entity = withState { entities, _ in entities[id] }
        return GameWorld.GetEntityResults { r in
            if let entity {
                var out = r.initEntity()
                writeEntity(entity, into: &out)
                r.status = .ok
            } else {
                r.status = .notFound
            }
        }
    }

    func moveEntity(params: GameWorld.MoveEntityParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> GameWorld.MoveEntityResults {
        let id = params.id.id
        let p = params.newPosition
        let entity: StoredEntity? = withState { entities, _ in
            guard var e = entities[id] else { return nil }
            e.x = p.x; e.y = p.y; e.z = p.z
            entities[id] = e
            return e
        }
        return GameWorld.MoveEntityResults { r in
            if let entity {
                var out = r.initEntity()
                writeEntity(entity, into: &out)
                r.status = .ok
            } else {
                r.status = .notFound
            }
        }
    }

    func damageEntity(params: GameWorld.DamageEntityParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> GameWorld.DamageEntityResults {
        let id = params.id.id
        let amount = params.amount
        let outcome = withState { entities, _ -> (StoredEntity, Bool)? in
            guard var e = entities[id] else { return nil }
            e.health -= amount
            var killed = false
            if e.health <= 0 {
                e.health = 0
                e.alive = false
                killed = true
            }
            entities[id] = e
            return (e, killed)
        }
        return GameWorld.DamageEntityResults { r in
            if let (entity, killed) = outcome {
                var out = r.initEntity()
                writeEntity(entity, into: &out)
                r.killed = killed
                r.status = .ok
            } else {
                r.killed = false
                r.status = .notFound
            }
        }
    }

    func queryArea(params: GameWorld.QueryAreaParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> GameWorld.QueryAreaResults {
        let query = params.query
        let center = query.center
        let radius = query.radius
        let all = withState { entities, _ -> [StoredEntity] in
            entities.values.filter { e in
                let dx = e.x - center.x, dy = e.y - center.y, dz = e.z - center.z
                return dx * dx + dy * dy + dz * dz <= radius * radius
            }
        }
        return GameWorld.QueryAreaResults { r in
            let list = r.initEntities(all.count)
            for (i, e) in all.enumerated() {
                var out = Entity.Builder(list[i])
                writeEntity(e, into: &out)
            }
            r.count = UInt32(all.count)
        }
    }
}

// MARK: - chat

struct StoredPlayer {
    var id: UInt64
    var name: String
    var faction: Faction
    var level: UInt16
}

struct StoredRoom {
    var id: UInt64
    var name: String
    var topic: String
}

struct StoredMessage {
    var sender: StoredPlayer
    var content: String
    var kind: StoredKind
    enum StoredKind {
        case normal
        case emote
        case system
        case whisper(UInt64)
    }
}

final class ChatRoomSession: ChatRoom.Server, @unchecked Sendable {
    let state: ChatServiceState
    let room: StoredRoom
    let sender: StoredPlayer
    private let lock = NSLock()

    init(state: ChatServiceState, room: StoredRoom, sender: StoredPlayer) {
        self.state = state
        self.room = room
        self.sender = sender
    }

    private func writeMessage(_ stored: StoredMessage, into m: inout ChatMessage.Builder) {
        var senderB = m.initSender()
        var senderId = senderB.initId()
        senderId.id = stored.sender.id
        senderB.setName(stored.sender.name)
        senderB.faction = stored.sender.faction
        senderB.level = stored.sender.level
        m.setContent(stored.content)
        var ts = m.initTimestamp()
        ts.unixMillis = Int64(Date.now.timeIntervalSince1970 * 1000)
        switch stored.kind {
        case .normal: m.kind.setNormal()
        case .emote: m.kind.setEmote()
        case .system: m.kind.setSystem()
        case .whisper(let target):
            var targetB = m.kind.initWhisper()
            targetB.id = target
        }
    }

    private func record(_ message: StoredMessage) {
        state.record(room.name, message)
    }

    func sendMessage(params: ChatRoom.SendMessageParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatRoom.SendMessageResults {
        let content = (try? params.content()) ?? ""
        let message = StoredMessage(sender: sender, content: content, kind: .normal)
        record(message)
        return ChatRoom.SendMessageResults { r in
            var m = r.initMessage()
            writeMessage(message, into: &m)
            r.status = .ok
        }
    }

    func sendEmote(params: ChatRoom.SendEmoteParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatRoom.SendEmoteResults {
        let content = (try? params.content()) ?? ""
        let message = StoredMessage(sender: sender, content: content, kind: .emote)
        record(message)
        return ChatRoom.SendEmoteResults { r in
            var m = r.initMessage()
            writeMessage(message, into: &m)
            r.status = .ok
        }
    }

    func getHistory(params: ChatRoom.GetHistoryParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatRoom.GetHistoryResults {
        let history = state.history(room.name)
        return ChatRoom.GetHistoryResults { r in
            let list = r.initMessages(history.count)
            for (i, message) in history.enumerated() {
                var m = ChatMessage.Builder(list[i])
                writeMessage(message, into: &m)
            }
        }
    }

    func getInfo(params: ChatRoom.GetInfoParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatRoom.GetInfoResults {
        ChatRoom.GetInfoResults { r in
            var info = r.initInfo()
            var rid = info.initId()
            rid.id = room.id
            info.setName(room.name)
            info.memberCount = 1
            info.setTopic(room.topic)
        }
    }

    func leave(params: ChatRoom.LeaveParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatRoom.LeaveResults {
        ChatRoom.LeaveResults { r in r.status = .ok }
    }
}

final class ChatServiceState: ChatService.Server, @unchecked Sendable {
    private let lock = NSLock()
    private var rooms: [String: StoredRoom] = [:]
    private var histories: [String: [StoredMessage]] = [:]
    private var nextId: UInt64 = 1

    func record(_ room: String, _ message: StoredMessage) {
        lock.withLock { histories[room, default: []].append(message) }
    }

    func history(_ room: String) -> [StoredMessage] {
        lock.withLock { histories[room] ?? [] }
    }

    private static func readPlayer(_ p: PlayerInfo.Reader) -> StoredPlayer {
        StoredPlayer(
            id: p.id.id,
            name: (try? p.name()) ?? "",
            faction: p.faction,
            level: p.level)
    }

    private static func writeInfo(_ room: StoredRoom, into info: inout RoomInfo.Builder) {
        var rid = info.initId()
        rid.id = room.id
        info.setName(room.name)
        info.memberCount = 1
        info.setTopic(room.topic)
    }

    func createRoom(params: ChatService.CreateRoomParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatService.CreateRoomResults {
        let name = (try? params.name()) ?? ""
        let topic = (try? params.topic()) ?? ""
        let room: StoredRoom? = lock.withLock {
            guard rooms[name] == nil else { return nil }
            let room = StoredRoom(id: nextId, name: name, topic: topic)
            nextId += 1
            rooms[name] = room
            return room
        }
        return ChatService.CreateRoomResults { r in
            var info = r.initInfo()
            if let room {
                r.setRoom(ChatRoomSession(state: self, room: room, sender: StoredPlayer(id: 0, name: "system", faction: .neutral, level: 0)))
                ChatServiceState.writeInfo(room, into: &info)
                r.status = .ok
            } else {
                ChatServiceState.writeInfo(StoredRoom(id: 0, name: name, topic: topic), into: &info)
                r.status = .alreadyExists
            }
        }
    }

    func joinRoom(params: ChatService.JoinRoomParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatService.JoinRoomResults {
        let name = (try? params.name()) ?? ""
        let player = ChatServiceState.readPlayer(params.player)
        let room = lock.withLock { rooms[name] }
        return ChatService.JoinRoomResults { r in
            if let room {
                r.setRoom(ChatRoomSession(state: self, room: room, sender: player))
                r.status = .ok
            } else {
                r.status = .notFound
            }
        }
    }

    func listRooms(params: ChatService.ListRoomsParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatService.ListRoomsResults {
        let all = lock.withLock { rooms.values.sorted { $0.id < $1.id } }
        return ChatService.ListRoomsResults { r in
            let list = r.initRooms(all.count)
            for (i, room) in all.enumerated() {
                var info = RoomInfo.Builder(list[i])
                ChatServiceState.writeInfo(room, into: &info)
            }
        }
    }

    func whisper(params: ChatService.WhisperParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> ChatService.WhisperResults {
        let from = ChatServiceState.readPlayer(params.from)
        let to = params.to.id
        let content = (try? params.content()) ?? ""
        let message = StoredMessage(sender: from, content: content, kind: .whisper(to))
        return ChatService.WhisperResults { r in
            var m = r.initMessage()
            var mb2 = m
            writeW(&mb2, message)
            r.status = .ok
        }
    }

    private func writeW(_ m: inout ChatMessage.Builder, _ message: StoredMessage) {
        var senderB = m.initSender()
        var senderId = senderB.initId()
        senderId.id = message.sender.id
        senderB.setName(message.sender.name)
        senderB.faction = message.sender.faction
        senderB.level = message.sender.level
        m.setContent(message.content)
        var ts = m.initTimestamp()
        ts.unixMillis = 0
        switch message.kind {
        case .normal: m.kind.setNormal()
        case .emote: m.kind.setEmote()
        case .system: m.kind.setSystem()
        case .whisper(let target):
            var targetB = m.kind.initWhisper()
            targetB.id = target
        }
    }
}

// MARK: - inventory

struct StoredItem {
    var id: UInt64
    var name: String
    var rarity: Rarity
    var level: UInt16
    var stackSize: UInt32
    var attributes: [(String, Int32)]
}

struct StoredSlot {
    var slotIndex: UInt16
    var item: StoredItem
    var quantity: UInt32
}

func writeItem(_ item: StoredItem, into b: inout Item.Builder) {
    var id = b.initId()
    id.id = item.id
    b.setName(item.name)
    b.rarity = item.rarity
    b.level = item.level
    b.stackSize = item.stackSize
    let attrs = b.initAttributes(item.attributes.count)
    for (i, attr) in item.attributes.enumerated() {
        var a = Attribute.Builder(attrs[i])
        a.setName(attr.0)
        a.value = attr.1
    }
}

func writeSlot(_ slot: StoredSlot, into b: inout InventorySlot.Builder) {
    b.slotIndex = slot.slotIndex
    var item = b.initItem()
    writeItem(slot.item, into: &item)
    b.quantity = slot.quantity
}

func readItem(_ r: Item.Reader) -> StoredItem {
    var attributes: [(String, Int32)] = []
    if let list = (try? r.attributes()) {
        for i in list.indices {
            let a = list[i]
            attributes.append(((try? a.name()) ?? "", a.value))
        }
    }
    return StoredItem(
        id: r.id.id,
        name: (try? r.name()) ?? "",
        rarity: r.rarity,
        level: r.level,
        stackSize: r.stackSize,
        attributes: attributes)
}

final class TradeSessionService: TradeSession.Server, @unchecked Sendable {
    let state = Mutex<TradeInternal>(TradeInternal())
    let inventory: InventoryServiceState
    let initiator: UInt64

    init(inventory: InventoryServiceState, initiator: UInt64) {
        self.inventory = inventory
        self.initiator = initiator
    }

    struct TradeInternal {
        var tradeState: TradeState = .proposing
        var offered: [UInt16] = []
    }

    func offerItems(params: TradeSession.OfferItemsParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> TradeSession.OfferItemsResults {
        let offered = (try? params.slots())?.elements() ?? []
        state.withLock { $0.offered = offered }
        let owned = inventory.slots(initiator)
        let picked = offered.compactMap { index in owned.first { $0.slotIndex == index } }
        return TradeSession.OfferItemsResults { r in
            var offer = r.initOffer()
            let list = offer.initOfferedItems(picked.count)
            for (i, slot) in picked.enumerated() {
                var out = InventorySlot.Builder(list[i])
                writeSlot(slot, into: &out)
            }
            offer.accepted = false
            r.status = .ok
        }
    }

    func accept(params: TradeSession.AcceptParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> TradeSession.AcceptResults {
        state.withLock { $0.tradeState = .accepted }
        return TradeSession.AcceptResults { r in
            r.state = .accepted
            r.status = .ok
        }
    }

    func confirm(params: TradeSession.ConfirmParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> TradeSession.ConfirmResults {
        state.withLock { $0.tradeState = .confirmed }
        return TradeSession.ConfirmResults { r in
            r.state = .confirmed
            r.status = .ok
        }
    }

    func cancel(params: TradeSession.CancelParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> TradeSession.CancelResults {
        state.withLock { $0.tradeState = .cancelled }
        return TradeSession.CancelResults { r in r.state = .cancelled }
    }

    func removeItems(params: TradeSession.RemoveItemsParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> TradeSession.RemoveItemsResults {
        TradeSession.RemoveItemsResults { r in r.status = .ok }
    }

    func viewOtherOffer(params: TradeSession.ViewOtherOfferParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> TradeSession.ViewOtherOfferResults {
        TradeSession.ViewOtherOfferResults { _ in }
    }

    func getState(params: TradeSession.GetStateParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> TradeSession.GetStateResults {
        TradeSession.GetStateResults { r in r.state = state.withLock { $0.tradeState } }
    }
}

final class InventoryServiceState: InventoryService.Server, @unchecked Sendable {
    private let lock = NSLock()
    private var inventories: [UInt64: [StoredSlot]] = [:]

    func slots(_ player: UInt64) -> [StoredSlot] {
        lock.withLock { inventories[player] ?? [] }
    }

    func getInventory(params: InventoryService.GetInventoryParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> InventoryService.GetInventoryResults {
        let player = params.player.id
        let current = slots(player)
        return InventoryService.GetInventoryResults { r in
            var view = r.initInventory()
            var owner = view.initOwner()
            owner.id = player
            let list = view.initSlots(current.count)
            for (i, slot) in current.enumerated() {
                var out = InventorySlot.Builder(list[i])
                writeSlot(slot, into: &out)
            }
            view.capacity = 20
            view.usedSlots = UInt16(current.count)
            r.status = .ok
        }
    }

    func addItem(params: InventoryService.AddItemParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> InventoryService.AddItemResults {
        let player = params.player.id
        let item = readItem(params.item)
        let quantity = params.quantity
        let slot: StoredSlot = lock.withLock {
            var current = inventories[player] ?? []
            let index = UInt16(current.count)
            let slot = StoredSlot(slotIndex: index, item: item, quantity: quantity)
            current.append(slot)
            inventories[player] = current
            return slot
        }
        return InventoryService.AddItemResults { r in
            var out = r.initSlot()
            writeSlot(slot, into: &out)
            r.status = .ok
        }
    }

    func removeItem(params: InventoryService.RemoveItemParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> InventoryService.RemoveItemResults {
        let player = params.player.id
        let slotIndex = params.slotIndex
        let quantity = params.quantity
        lock.withLock {
            guard var current = inventories[player],
                  Int(slotIndex) < current.count,
                  current[Int(slotIndex)].quantity >= quantity else { return }
            current[Int(slotIndex)].quantity -= quantity
            if current[Int(slotIndex)].quantity == 0 {
                current.remove(at: Int(slotIndex))
            }
            inventories[player] = current
        }
        return InventoryService.RemoveItemResults { r in r.status = .ok }
    }

    func startTrade(params: InventoryService.StartTradeParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> InventoryService.StartTradeResults {
        InventoryService.StartTradeResults { r in
            r.setSession(TradeSessionService(inventory: self, initiator: params.initiator.id))
            r.status = .ok
        }
    }

    func filterByRarity(params: InventoryService.FilterByRarityParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> InventoryService.FilterByRarityResults {
        let player = params.player.id
        let minRarity = params.minRarity
        let matching = slots(player).filter { $0.item.rarity.rawValue >= minRarity.rawValue }
        return InventoryService.FilterByRarityResults { r in
            let list = r.initItems(matching.count)
            for (i, slot) in matching.enumerated() {
                var out = InventorySlot.Builder(list[i])
                writeSlot(slot, into: &out)
            }
        }
    }
}

// MARK: - matchmaking

struct StoredTicket {
    var ticketId: UInt64
    var player: StoredPlayer
    var mode: GameMode
}

struct StoredMatchStats {
    var player: StoredPlayer
    var kills: UInt32
    var deaths: UInt32
    var assists: UInt32
    var score: Int32
}

struct StoredMatchResult {
    var matchId: UInt64
    var winningTeam: UInt8
    var duration: UInt32
    var stats: [StoredMatchStats]
}

final class MatchControllerService: MatchController.Server, @unchecked Sendable {
    let state = Mutex<MatchInternal>(MatchInternal())
    let results: MatchmakingServiceState

    struct MatchInternal {
        var id: UInt64 = 0
        var mode: GameMode = .duel
        var matchState: MatchState = .waiting
        var teamA: [StoredPlayer] = []
        var teamB: [StoredPlayer] = []
        var result: StoredMatchResult?
    }

    init(results: MatchmakingServiceState) {
        self.results = results
    }

    func configure(_ id: UInt64, mode: GameMode, player: StoredPlayer) {
        state.withLock {
            $0.id = id
            $0.mode = mode
            $0.matchState = .waiting
            $0.teamA = [player]
            $0.teamB = [StoredPlayer(id: 999, name: "Opponent", faction: .neutral, level: 10)]
        }
    }

    private static func writeInfo(_ internal_: MatchInternal, into info: inout MatchInfo.Builder) {
        var mid = info.initId()
        mid.id = internal_.id
        info.mode = internal_.mode
        info.state = internal_.matchState
        let teamA = info.initTeamA(internal_.teamA.count)
        for (i, player) in internal_.teamA.enumerated() {
            var p = PlayerInfo.Builder(teamA[i])
            var pid = p.initId()
            pid.id = player.id
            p.setName(player.name)
            p.faction = player.faction
            p.level = player.level
        }
        let teamB = info.initTeamB(internal_.teamB.count)
        for (i, player) in internal_.teamB.enumerated() {
            var p = PlayerInfo.Builder(teamB[i])
            var pid = p.initId()
            pid.id = player.id
            p.setName(player.name)
            p.faction = player.faction
            p.level = player.level
        }
        var ts = info.initCreatedAt()
        ts.unixMillis = 0
    }

    func getInfo(params: MatchController.GetInfoParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchController.GetInfoResults {
        MatchController.GetInfoResults { r in
            var info = r.initInfo()
            MatchControllerService.writeInfo(state.withLock { $0 }, into: &info)
        }
    }

    func signalReady(params: MatchController.SignalReadyParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchController.SignalReadyResults {
        state.withLock { $0.matchState = .ready }
        return MatchController.SignalReadyResults { r in
            r.allReady = true
            r.status = .ok
        }
    }

    func reportResult(params: MatchController.ReportResultParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchController.ReportResultResults {
        let result = params.result
        var stats: [StoredMatchStats] = []
        if let list = try? result.playerStats() {
            for i in list.indices {
                let src = list[i]
                stats.append(StoredMatchStats(
                    player: StoredPlayer(
                        id: src.player.id.id,
                        name: (try? src.player.name()) ?? "",
                        faction: src.player.faction,
                        level: src.player.level),
                    kills: src.kills, deaths: src.deaths, assists: src.assists, score: src.score))
            }
        }
        let stored = StoredMatchResult(
            matchId: result.matchId.id,
            winningTeam: result.winningTeam,
            duration: result.duration,
            stats: stats)
        state.withLock { $0.result = stored }
        results.storeResult(stored.matchId, stored)
        return MatchController.ReportResultResults { r in r.status = .ok }
    }

    func cancelMatch(params: MatchController.CancelMatchParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchController.CancelMatchResults {
        let current = state.withLock { state -> MatchState in
            defer { state.matchState = .cancelled }
            return state.matchState
        }
        return MatchController.CancelMatchResults { r in
            r.status = (current == .inProgress || current == .completed) ? .invalidArgument : .ok
        }
    }
}

final class MatchmakingServiceState: MatchmakingService.Server, @unchecked Sendable {
    private let lock = NSLock()
    private var nextTicket: UInt64 = 1
    private var nextMatch: UInt64 = 1
    private var queue: [StoredTicket] = []
    private var results: [UInt64: StoredMatchResult] = [:]

    func storeResult(_ matchId: UInt64, _ result: StoredMatchResult) {
        lock.withLock { results[matchId] = result }
    }

    func enqueue(params: MatchmakingService.EnqueueParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchmakingService.EnqueueResults {
        let player = StoredPlayer(
            id: params.player.id.id,
            name: (try? params.player.name()) ?? "",
            faction: params.player.faction,
            level: params.player.level)
        let mode = params.mode
        let ticket: StoredTicket = lock.withLock {
            let ticket = StoredTicket(ticketId: nextTicket, player: player, mode: mode)
            nextTicket += 1
            queue.append(ticket)
            return ticket
        }
        return MatchmakingService.EnqueueResults { r in
            var t = r.initTicket()
            t.ticketId = ticket.ticketId
            var p = t.initPlayer()
            var pid = p.initId()
            pid.id = player.id
            p.setName(player.name)
            p.faction = player.faction
            p.level = player.level
            t.mode = mode
            t.estimatedWaitSecs = 30
            r.status = .ok
        }
    }

    func dequeue(params: MatchmakingService.DequeueParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchmakingService.DequeueResults {
        let ticketId = params.ticketId
        let found = lock.withLock {
            let before = queue.count
            queue.removeAll { $0.ticketId == ticketId }
            return queue.count != before
        }
        return MatchmakingService.DequeueResults { r in r.status = found ? .ok : .notFound }
    }

    func findMatch(params: MatchmakingService.FindMatchParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchmakingService.FindMatchResults {
        let player = StoredPlayer(
            id: params.player.id.id,
            name: (try? params.player.name()) ?? "",
            faction: params.player.faction,
            level: params.player.level)
        let mode = params.mode
        let match = lock.withLock { () -> UInt64 in
            defer { nextMatch += 1 }
            return nextMatch
        }
        let controller = MatchControllerService(results: self)
        controller.configure(match, mode: mode, player: player)
        return MatchmakingService.FindMatchResults { r in
            r.setController(controller)
            var mid = r.initMatchId()
            mid.id = match
        }
    }

    func getQueueStats(params: MatchmakingService.GetQueueStatsParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchmakingService.GetQueueStatsResults {
        let mode = params.mode
        let count = lock.withLock { queue.filter { $0.mode == mode }.count }
        return MatchmakingService.GetQueueStatsResults { r in
            r.playersInQueue = UInt32(count)
            r.avgWaitSecs = 0
        }
    }

    func getMatchResult(params: MatchmakingService.GetMatchResultParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> MatchmakingService.GetMatchResultResults {
        let id = params.id.id
        let stored = lock.withLock { results[id] }
        guard let stored else {
            return MatchmakingService.GetMatchResultResults { r in r.status = .notFound }
        }
        return MatchmakingService.GetMatchResultResults { r in
            var out = r.initResult()
            var mid = out.initMatchId()
            mid.id = stored.matchId
            out.winningTeam = stored.winningTeam
            out.duration = stored.duration
            let outs = out.initPlayerStats(stored.stats.count)
            for (i, stat) in stored.stats.enumerated() {
                var dst = PlayerMatchStats.Builder(outs[i])
                var player = dst.initPlayer()
                var pid = player.initId()
                pid.id = stat.player.id
                player.setName(stat.player.name)
                player.faction = stat.player.faction
                player.level = stat.player.level
                dst.kills = stat.kills
                dst.deaths = stat.deaths
                dst.assists = stat.assists
                dst.score = stat.score
            }
            r.status = .ok
        }
    }
}

// MARK: - resolve_disembargo

final class ReflectorService: Reflector.Server, @unchecked Sendable {
    private let lock = NSLock()
    private var promise: PromiseExport?
    private var target: CapRef?

    func reflect(params: Reflector.ReflectParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Reflector.ReflectResults {
        // Retain the caller's CallSequence import; export an unresolved
        // promise for it (resolved by resolveNow).
        guard let targetClient = params.target(caps, on: connection),
              case .cap(let ref) = targetClient.target else {
            throw RPCError.failed(reason: "reflect: target is not a capability")
        }
        let promise = try await connection.makePromise()
        lock.withLock {
            self.promise = promise
            self.target = ref
        }
        return Reflector.ReflectResults { r in
            r.setPromise(promise: promise)
        }
    }

    func resolveNow(params: Reflector.ResolveNowParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Reflector.ResolveNowResults {
        // The target stays retained for the connection's lifetime: the
        // resolved promise forwards later calls to it (the Zig server
        // retains it the same way).
        let pending = lock.withLock { () -> (PromiseExport, CapRef)? in
            guard let promise, let target else { return nil }
            self.promise = nil
            return (promise, target)
        }
        if let (promise, target) = pending {
            try await connection.resolve(promise, to: .imported(target))
        }
        return Reflector.ResolveNowResults()
    }

    func invokeCap(params: Reflector.InvokeCapParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Reflector.InvokeCapResults {
        guard let cb = params.cb(caps, on: connection) else {
            throw RPCError.failed(reason: "invokeCap: cb is not a capability")
        }
        let n = try await cb.getNumber().n
        return Reflector.InvokeCapResults { r in r.observed = n }
    }

    func disconnectNow(params: Reflector.DisconnectNowParams.Reader, caps: [CapTableEntry], on connection: RPCConnection) async throws -> Reflector.DisconnectNowResults {
        // Close this side's transport; the caller's open question ends
        // with a disconnect-class error. The Return is dropped (the core
        // produces no effects once the transport is closed).
        await connection.close()
        return Reflector.DisconnectNowResults { r in r.unused = 0 }
    }
}
