import SwiftUI
import VaultCore

struct LockScreenView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.shuffleKeypad) private var shuffleKeypad = false
    @AppStorage(Preferences.passcodeKind) private var kind = PasscodeKind.digits
    @State private var feedback: AppModel.Feedback?
    @State private var failures = 0
    @State private var confirmingErase = false

    var body: some View {
        VStack(spacing: 0) {
            entry
            // In case the saved choice is ever lost: lets the owner pick the
            // other input. It reveals nothing about the passcode.
            if feedback == .unrecoverable {
                Button("Erase Vault and Start Over", role: .destructive) { confirmingErase = true }
                    .font(.footnote)
                    .padding(.bottom, 8)
            }
            Button(kind == .digits ? "Use Passphrase" : "Use Keypad") {
                kind = kind == .digits ? .passphrase : .digits
            }
            .font(.footnote)
            .padding(.bottom, 12)
        }
        .confirmationDialog("Erase the vault?", isPresented: $confirmingErase, titleVisibility: .visible) {
            Button("Erase Everything", role: .destructive) {
                Task { _ = await model.erase() }
            }
        } message: {
            Text("This vault can't be opened on this iPhone any more. Erasing destroys everything in it and lets you create a new one. This can't be undone.")
        }
        .task {
            await model.refreshStatus()
        }
        .task(id: model.status?.retryAfter) {
            // Re-enable the keypad the moment the lockout ends.
            guard let retryAfter = model.status?.retryAfter else { return }
            try? await Task.sleep(for: .seconds(max(0, retryAfter.timeIntervalSinceNow)))
            await model.refreshStatus()
        }
    }

    private var entry: some View {
        PasscodeEntryView(
            title: "Enter Passcode",
            message: message,
            kind: kind,
            shuffled: shuffleKeypad,
            retryAfter: model.status?.retryAfter,
            isWorking: model.isWorking,
            failureCount: failures,
            submitLabel: "Unlock"
        ) { buffer in
            let result = await model.unlock(with: buffer)
            feedback = result
            if result == .wrongPasscode {
                failures += 1
            }
        }
        .id(kind)
    }

    private var message: String? {
        switch feedback {
        case .wrongPasscode:
            if let left = model.status?.attemptsBeforeErase, left <= 3 {
                return left == 1
                    ? "Wrong passcode. 1 attempt left before the vault is erased."
                    : "Wrong passcode. \(left) attempts left before the vault is erased."
            }
            return "Wrong passcode."
        case .failed:
            return "The vault couldn't be opened. Try again."
        case .unrecoverable:
            return "This vault can't be opened: its key on this iPhone is gone, or its files are damaged."
        default:
            return nil
        }
    }
}
