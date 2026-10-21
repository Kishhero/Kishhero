import SwiftUI
import VaultCore

/// First run: the no-recovery warning, then choose and confirm a passcode.
struct SetupView: View {
    private enum Step {
        case intro, choose, confirm, creating
    }

    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.passcodeKind) private var savedKind = PasscodeKind.digits
    @State private var step = Step.intro
    @State private var kind = PasscodeKind.digits
    @State private var understood = false
    @State private var firstEntry = PasscodeBuffer()
    @State private var message: String?
    @State private var failures = 0

    var body: some View {
        switch step {
        case .intro:
            intro
        case .choose:
            VStack(spacing: 0) {
                PasscodeEntryView(
                    title: "Choose a Passcode",
                    hint: kind == .digits ? "At least 8 digits." : "At least 8 characters.",
                    message: message,
                    kind: kind,
                    failureCount: failures
                ) { buffer in
                    firstEntry.copy(from: buffer)
                    message = nil
                    step = .confirm
                }
                Button(kind == .digits ? "Use a Passphrase Instead" : "Use Digits Instead") {
                    kind = kind == .digits ? .passphrase : .digits
                    message = nil
                }
                .padding(.bottom, 16)
            }
        case .confirm:
            PasscodeEntryView(title: "Enter It Again", kind: kind) { buffer in
                guard buffer.matches(firstEntry) else {
                    firstEntry.wipe()
                    message = "Those didn't match. Choose a passcode again."
                    failures += 1
                    step = .choose
                    return
                }
                step = .creating
                // Saved first, so the lock screen shows the right input even if
                // the app is killed the moment the vault is created.
                savedKind = kind
                let created = await model.setUp(with: buffer)
                firstEntry.wipe()
                if !created {
                    message = "The vault couldn't be created. Try again."
                    step = .choose
                }
            }
        case .creating:
            VStack(spacing: 16) {
                ProgressView()
                Text("Creating your vault…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)

                if model.notice == .erasedAfterFailedAttempts {
                    Label("The previous vault was erased after 10 wrong passcodes.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text("PhotoVault")
                    .font(.largeTitle.bold())
                Text("Photos and videos you add are encrypted and stored only on this iPhone. The app never connects to the internet.")

                VStack(alignment: .leading, spacing: 12) {
                    Text("There is no way to recover the vault").font(.headline)
                    Label("If you forget your passcode, everything in it is lost.", systemImage: "key")
                    Label("It is not in iCloud or computer backups. If this iPhone is lost or broken, everything in it is lost.", systemImage: "iphone.slash")
                    Label("Deleting the app deletes the vault.", systemImage: "trash")
                }
                .padding()
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))

                Toggle("I understand that nobody can recover my vault", isOn: $understood)

                Button {
                    step = .choose
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!understood)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }
}
