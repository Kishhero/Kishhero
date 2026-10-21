import Combine
import UIKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var shield = PrivacyShield()
    @State private var screenshotTaken = false

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
        // iOS lets apps learn of a screenshot only after it is saved. Say so,
        // so it can be deleted from Photos if it shows vault content.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if model.phase == .unlocked {
                screenshotTaken = true
            }
        }
        .alert("Screenshot Saved to Photos", isPresented: $screenshotTaken) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It may show what's in the vault, and it isn't encrypted. If it does, delete it in Photos, and from Recently Deleted.")
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
