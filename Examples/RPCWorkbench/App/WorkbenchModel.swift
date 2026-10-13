import CapnpRPC
import Foundation
import Observation
import SwiftUI
import WorkbenchKit

@MainActor @Observable final class WorkbenchModel {
    var host = "127.0.0.1"
    var port = "41011"
    var mode: WorkbenchMode = .tcp
    var message = "Hello from RPC Workbench"
    var status = "Disconnected"
    var serverStatus = "Server stopped"
    var log: [String] = []
    var checks: [WorkbenchCheck] = []
    var busy = false
    var canCancel = false
    var connected = false
    var hosting = false
    var error: String?
    private var server: WorkbenchHost?
    private var client: WorkbenchClient?
    private var policy: RPCLifecyclePolicy?
    private var watcher: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var wantsConnection = false
    private var launched = false
    private var currentEndpoint: WorkbenchEndpoint?
    private var generation = UUID()
    private var lastPhase: ScenePhase = .active

    init() {
        let preferences = UserDefaults.standard
        host = preferences.string(forKey: "workbench.host") ?? host
        port = preferences.string(forKey: "workbench.port") ?? port
        if let value = preferences.string(forKey: "workbench.mode"), let saved = WorkbenchMode(rawValue: value) { mode = saved }
    }
    var macAddress: String { ProcessInfo.processInfo.hostName }

    func selectMode() { port = String(mode.defaultPort) }
    func note(_ value: String) {
        log.append(value)
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }
    func startServer() async {
        guard !hosting else { return }
        do {
            let fresh = try await WorkbenchHost.start()
            server = fresh; hosting = true
            serverStatus = "TCP \(fresh.tcpPort) · Sample TLS \(fresh.tlsPort)"
            note("Server started. Enter this Mac’s LAN address on your iPhone.")
        } catch { self.error = String(describing: error); note("Server: \(error)") }
    }
    func stopServer() { server?.stop(); server = nil; hosting = false; serverStatus = "Server stopped" }
    private func endpoint() throws -> WorkbenchEndpoint {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let number = UInt16(port), number > 0 else {
            throw WorkbenchFailure("Enter a host and a port from 1 to 65535.")
        }
        return WorkbenchEndpoint(host: name, port: number, mode: mode)
    }
    func connect() async {
        guard !busy else { return }
        busy = true; error = nil
        await disconnect()
        busy = true; status = "Connecting…"
        var opening: RPCConnection?
        do {
            let endpoint = try endpoint()
            currentEndpoint = endpoint
            let peer = try await endpoint.connect()
            opening = peer.connection
            let fresh = try await WorkbenchClient.open(peer: peer, receive: eventReceiver())
            client = fresh; policy = RPCLifecyclePolicy(connection: peer.connection) { try await endpoint.connect().connection }
            await policy?.scenePhaseDidChange(.active)
            connected = true; wantsConnection = true; status = "Connected over \(mode.rawValue)"
            UserDefaults.standard.set(host, forKey: "workbench.host")
            UserDefaults.standard.set(port, forKey: "workbench.port")
            UserDefaults.standard.set(mode.rawValue, forKey: "workbench.mode")
            checks = fresh.openingChecks
            for check in checks { note("PASS · \(check.name)") }
            watch(peer.connection)
        } catch {
            await opening?.close()
            self.error = String(describing: error); status = "Connection failed"; note("Connect: \(error)")
            saveReport()
        }
        busy = false
    }
    private func eventReceiver() -> @Sendable (WorkbenchEvent) -> Void {
        let id = generation
        return { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.note("Callback · \(event.message)")
            }
        }
    }
    private func watch(_ connection: RPCConnection) {
        watcher?.cancel()
        let id = generation
        watcher = Task { [weak self] in
            let reason = await connection.waitClosed()
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.connected = false
            if self.lastPhase != .background { self.status = "Disconnected · \(reason)" }
            self.note("Connection closed · \(reason)")
        }
    }
    func disconnect() async {
        generation = UUID(); wantsConnection = false
        operation?.cancel(); watcher?.cancel(); canCancel = false
        let previous = client; client = nil; policy = nil
        connected = false; status = "Disconnected"
        await previous?.close()
    }
    func sendEcho() {
        let text = message
        perform { client in self.note(try await client.echo(text)) }
    }
    func sendStream() {
        perform { client in
            let receipt = try await client.stream()
            self.note("Receipt · \(receipt.count) updates · \(receipt.last)")
        }
    }
    func slowRequest() {
        canCancel = true
        perform { client in
            _ = try await client.slow()
            self.note("Slow request completed")
        }
    }
    func cancelRequest() { operation?.cancel() }
    func runChecks() {
        perform { client in
            self.checks = try await client.runChecks()
            for check in self.checks { self.note("PASS · \(check.name)") }
            self.note("\(self.checks.count) checks passed")
            self.saveReport()
        }
    }
    private func perform(_ action: @escaping @MainActor (WorkbenchClient) async throws -> Void) {
        guard !busy, let client else { return }
        busy = true; error = nil
        operation = Task {
            defer { busy = false; canCancel = false }
            do { try await action(client) }
            catch let error as RPCError where error == .canceled { note("Request canceled. The connection remains open.") }
            catch is CancellationError { note("Request canceled. The connection remains open.") }
            catch { self.error = String(describing: error); note("Request: \(error)"); saveReport() }
        }
    }
    func changePhase(_ next: ScenePhase) async {
        guard next != .inactive else { return }
        let previous = lastPhase; lastPhase = next
        guard wantsConnection, let policy else { return }
        if next == .background {
            operation?.cancel(); connected = false; status = "Suspended"
            await policy.scenePhaseDidChange(.background)
            client = nil
            note("Background · connection suspended")
        } else if next == .active && previous == .background {
            status = "Reconnecting…"
            await policy.scenePhaseDidChange(.active)
            guard let connection = policy.connection else { status = "Reconnect failed"; return }
            do {
                generation = UUID()
                client = try await WorkbenchClient.open(connection: connection, receive: eventReceiver())
                connected = true; status = "Connected after foreground"
                note("Foreground · new session ready"); watch(connection)
            } catch { self.error = String(describing: error); status = "Reconnect failed" }
        }
    }
    func simulateSuspend() async {
        await changePhase(.background)
        await changePhase(.active)
    }
    func handleLaunchArguments() async {
        guard !launched else { return }; launched = true
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let value = argument("--host") { host = value }
        if argument("--transport") == "tls" { mode = .tls; selectMode() }
        if let value = argument("--port") { port = value }
        guard args.contains("--run-checks") else { return }
        #if os(macOS)
        await startServer()
        #endif
        await connect()
        runChecks()
    }
    private func saveReport() {
        struct Report: Codable {
            var recordedAt: Date
            var transport: String
            var host: String
            var checks: [WorkbenchCheck]
            var error: String?
            var events: [String]
        }
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let url = directory.appendingPathComponent("RPCWorkbench-result.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Report(recordedAt: Date(), transport: mode.rawValue, host: host, checks: checks, error: error, events: log)).write(to: url, options: .atomic)
        } catch { note("Could not save check report: \(error)") }
    }
}
