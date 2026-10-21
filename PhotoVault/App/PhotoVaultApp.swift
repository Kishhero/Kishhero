import SwiftUI

@main
struct PhotoVaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Creating the model does no crypto and no file reads beyond one "does
    // vault.hdr exist" check, so launch goes straight to the keypad.
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Blocks third-party keyboards everywhere in the app (MASVS-STORAGE-2).
    /// They can log keystrokes or send them to the network, and the
    /// passphrase field and album names go through the keyboard. The PIN
    /// keypad is drawn by the app itself, so no keyboard ever sees PINs.
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}
