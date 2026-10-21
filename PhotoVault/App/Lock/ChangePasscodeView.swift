import SwiftUI
import VaultCore

/// Current passcode, then new, then confirm. The current passcode is checked
/// only at the end, through the same attempt limits as the lock screen.
struct ChangePasscodeView: View {
    private enum Step {
        case current, new, confirm
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.passcodeKind) private var savedKind = PasscodeKind.digits
    @State private var step = Step.current
    @State private var newKind = PasscodeKind.digits
    @State private var current = PasscodeBuffer()
    @State private var new = PasscodeBuffer()
    @State private var message: String?
    @State private var failures = 0

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .current:
                    PasscodeEntryView(
                        title: "Enter Current Passcode",
                        message: message,
                        kind: savedKind,
                        retryAfter: model.status?.retryAfter,
                        failureCount: failures
                    ) { buffer in
                        current.copy(from: buffer)
                        message = nil
                        step = .new
                    }
                case .new:
                    VStack(spacing: 0) {
                        PasscodeEntryView(
                            title: "Choose a New Passcode",
                            hint: newKind == .digits ? "At least 8 digits." : "At least 8 characters.",
                            message: message,
                            kind: newKind
                        ) { buffer in
                            new.copy(from: buffer)
                            message = nil
                            step = .confirm
                        }
                        Button(newKind == .digits ? "Use a Passphrase Instead" : "Use Digits Instead") {
                            newKind = newKind == .digits ? .passphrase : .digits
                        }
                        .padding(.bottom, 16)
                    }
                case .confirm:
                    PasscodeEntryView(title: "Enter It Again", kind: newKind, isWorking: model.isWorking) { buffer in
                        await confirm(buffer)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        current.wipe()
                        new.wipe()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { newKind = savedKind }
        .task { await model.refreshStatus() }
    }

    private func confirm(_ buffer: PasscodeBuffer) async {
        guard buffer.matches(new) else {
            new.wipe()
            message = "Those didn't match. Choose a new passcode again."
            step = .new
            return
        }
        let result = await model.changePasscode(current: current, new: buffer)
        current.wipe()
        new.wipe()
        switch result {
        case .succeeded:
            savedKind = newKind
            dismiss()
        case .wrongPasscode:
            failures += 1
            message = "The current passcode was wrong."
            step = .current
        case .throttled:
            message = nil
            step = .current
        case .erased:
            dismiss()
        case .failed, .ignored, .unrecoverable:
            message = "The passcode couldn't be changed. Try again."
            step = .current
        }
    }
}
