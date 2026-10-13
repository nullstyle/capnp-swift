import SwiftUI

@main struct WorkbenchApp: App {
    @State private var model = WorkbenchModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup("RPC Workbench") {
            WorkbenchView(model: model)
                .task { await model.handleLaunchArguments() }
                .onChange(of: phase) { _, phase in
                    Task { await model.changePhase(phase) }
                }
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 640)
                #endif
        }
    }
}
