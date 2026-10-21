import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var capture = ScreenCaptureMonitor()

    var body: some View {
        Group {
            switch model.phase {
            case .setup: SetupView()
            case .locked: LockScreenView()
            case .unlocked: VaultHomeView()
            }
        }
        .overlay {
            // Inactive: the app switcher is about to take its snapshot, or a
            // system sheet is up. Cover everything, so no photo ends up in the
            // snapshot that iOS stores on disk.
            if scenePhase != .active {
                PrivacyCoverView(reason: .inactive)
            } else if capture.isCaptured && model.phase == .unlocked {
                PrivacyCoverView(reason: .screenCapture)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Lock the moment the app leaves the foreground: the passcode is
            // needed every time you come back, with no grace period.
            if newPhase == .background {
                model.lock()
            }
        }
    }
}

struct PrivacyCoverView: View {
    enum Reason {
        case inactive, screenCapture
    }

    let reason: Reason

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
            VStack(spacing: 12) {
                Image(systemName: reason == .screenCapture ? "eye.slash" : "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                if reason == .screenCapture {
                    Text("Hidden while the screen is being recorded or mirrored.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}
