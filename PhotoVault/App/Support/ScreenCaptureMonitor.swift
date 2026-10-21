import Observation
import UIKit

/// Notices screen recording, AirPlay and mirroring, so vault content can be hidden.
///
/// Protects against: photos showing up in a screen recording or on a mirrored
/// display you forgot about.
/// Does not protect against: screenshots. iOS does not let apps block them;
/// an app can only be told afterwards. Or a camera pointed at the screen.
@MainActor
@Observable
final class ScreenCaptureMonitor {
    private(set) var isCaptured = false
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        isCaptured = Self.anySceneCaptured()
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isCaptured = Self.anySceneCaptured()
            }
        }
    }

    private static func anySceneCaptured() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.traitCollection.sceneCaptureState == .active }
    }
}
