import SwiftUI
import WorkbenchKit

struct WorkbenchView: View {
    @Bindable var model: WorkbenchModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Explore typed calls, callbacks and streaming between this device and your Mac.")
                        .foregroundStyle(.secondary)
                    #if os(macOS)
                    GroupBox("Mac server") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.serverStatus)
                                Text("iPhone host: \(model.macAddress)")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button(model.hosting ? "Stop server" : "Start server") {
                                if model.hosting { model.stopServer() } else { Task { await model.startServer() } }
                            }.accessibilityIdentifier("server.toggle")
                        }.padding(6)
                    }
                    #endif
                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Transport", selection: $model.mode) {
                                ForEach(WorkbenchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).onChange(of: model.mode) { model.selectMode() }
                            HStack {
                                TextField("Mac host or IP address", text: $model.host)
                                    .accessibilityIdentifier("connection.host")
                                TextField("Port", text: $model.port).frame(width: 80)
                                    .accessibilityIdentifier("connection.port")
                            }.textFieldStyle(.roundedBorder)
                            HStack {
                                Label(model.status, systemImage: model.connected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.connected ? Color.green : Color.secondary)
                                Spacer()
                                Button(model.connected ? "Disconnect" : "Connect") {
                                    Task { if model.connected { await model.disconnect() } else { await model.connect() } }
                                }.disabled(model.busy).accessibilityIdentifier("connection.toggle")
                            }
                            if model.mode == .tls {
                                Text("Pins the public sample certificate. Use a separate identity in your own app.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(6)
                    }
                    GroupBox("Try a request") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Message", text: $model.message).textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Send echo") { model.sendEcho() }
                                Button("Stream 12 updates") { model.sendStream() }
                            }.disabled(!model.connected || model.busy)
                            HStack {
                                Button("Slow request") { model.slowRequest() }.disabled(!model.connected || model.busy)
                                Button("Cancel request") { model.cancelRequest() }.disabled(!model.canCancel)
                            }
                            Button("Suspend and reconnect") { Task { await model.simulateSuspend() } }
                                .disabled(!model.connected || model.busy)
                            Button("Run all checks") { model.runChecks() }
                                .buttonStyle(.borderedProminent).disabled(!model.connected || model.busy)
                                .accessibilityIdentifier("checks.run")
                            if !model.checks.isEmpty {
                                Text("\(model.checks.filter(\.passed).count) checks passed")
                                    .font(.headline).accessibilityIdentifier("checks.summary")
                            }
                        }.padding(6)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    GroupBox("Activity") {
                        VStack(alignment: .leading, spacing: 6) {
                            if model.log.isEmpty { Text("Start the Mac server, then connect.").foregroundStyle(.secondary) }
                            ForEach(Array(model.log.enumerated()), id: \.offset) { _, message in
                                Text(message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }.padding()
            }.navigationTitle("RPC Workbench")
        }
    }
}
