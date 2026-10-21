import SwiftUI
import UIKit

/// Covers the whole app, sheets and full-screen viewers included, whenever
/// it shouldn't be visible.
///
/// It is a separate window above everything else, because an overlay on the
/// root view does not cover presented sheets: the app switcher snapshot would
/// have shown an open photo or the Settings sheet.
///
/// Protects against: vault content in the app switcher snapshot (which iOS
/// saves to disk), behind Control Center or a system alert, and in screen
/// recordings or on mirrored displays while the vault is open.
/// Does not protect against: screenshots, which iOS gives apps no way to
/// block, or a camera pointed at the screen.
@MainActor
final class PrivacyShield {
    /// Screen-capture covering applies only while the vault is open; the lock
    /// screen shows nothing worth hiding.
    var isVaultOpen = false {
        didSet { update() }
    }

    private var isInactive = false
    private var isCaptured = false
    private var window: UIWindow?
    private var observers: [any NSObjectProtocol] = []

    init() {
        isCaptured = Self.anySceneCaptured()
        let center = NotificationCenter.default
        // willDeactivate arrives before iOS takes the app switcher snapshot.
        observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isInactive = true
                self?.update()
            }
        })
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isInactive = false
                self?.update()
            }
        })
        observers.append(center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isCaptured = Self.anySceneCaptured()
                self?.update()
            }
        })
    }

    private func update() {
        if isInactive {
            show(.inactive)
        } else if isCaptured && isVaultOpen {
            show(.screenCapture)
        } else {
            window?.isHidden = true
            window = nil
        }
    }

    private func show(_ reason: PrivacyCoverView.Reason) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let cover = window ?? UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.rootViewController = UIHostingController(rootView: PrivacyCoverView(reason: reason))
        cover.isHidden = false
        window = cover
    }

    private static func anySceneCaptured() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.traitCollection.sceneCaptureState == .active }
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
