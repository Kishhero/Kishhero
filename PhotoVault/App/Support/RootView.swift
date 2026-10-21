import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var shield = PrivacyShield()

    var body: some View {
        Group {
            switch model.phase {
            case .setup: SetupView()
            case .locked: LockScreenView()
            case .unlocked:
                if let library = model.library {
                    LibraryView(library: library)
                }
            }
        }
        .onAppear {
            shield.isVaultOpen = model.phase == .unlocked
        }
        .onChange(of: model.phase) { _, phase in
            shield.isVaultOpen = phase == .unlocked
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Lock the moment the app leaves the foreground: the passcode is
            // needed every time you come back, with no grace period. Locking
            // also closes any open viewer, because the library view goes away.
            if newPhase == .background {
                model.lock()
            }
        }
    }
}
