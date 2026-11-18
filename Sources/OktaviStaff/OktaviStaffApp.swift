import SwiftUI

@main
struct OktaviStaffApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Oktavi Staff") {
            RootView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 620)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.sceneBecameActive()
                    case .inactive, .background: model.sceneBecameInactive()
                    @unknown default: break
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { model.userActivity() })
                .alert("Hinweis", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("OK") { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("App sperren") { model.lock() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.authState {
            case .loading: ProgressView("Schlüsselbund wird geladen …")
            case .setup: SetupView()
            case .locked(let metadata): UnlockView(metadata: metadata)
            case .unlocked(let metadata): StaffShellView(metadata: metadata)
            }
        }
        .animation(.default, value: model.authState)
    }
}
