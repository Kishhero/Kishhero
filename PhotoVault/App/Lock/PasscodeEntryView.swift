import SwiftUI
import VaultCore

/// Passcode input used by setup, the lock screen and passcode changes.
///
/// It owns the typed bytes, hands them to `onSubmit`, and wipes them as soon
/// as `onSubmit` returns, so no screen keeps a passcode around afterwards.
struct PasscodeEntryView: View {
    let title: String
    /// Neutral guidance, such as the minimum length.
    var hint: String?
    /// An error, shown in red in place of the hint.
    var message: String?
    var kind: PasscodeKind
    var shuffled = false
    var retryAfter: Date?
    var isWorking = false
    /// Changing this value shakes the input and plays an error haptic.
    var failureCount = 0
    var submitLabel = "Continue"
    let onSubmit: @MainActor (PasscodeBuffer) async -> Void

    @State private var buffer = PasscodeBuffer()
    @State private var passphrase = ""
    @State private var submitting = false

    private var isLockedOut: Bool {
        retryAfter.map { $0 > .now } ?? false
    }

    private var canSubmit: Bool {
        let length = kind == .digits ? buffer.count : passphrase.utf8.count
        // Every passcode is at least this long, so shorter input cannot be
        // right. Refusing it saves an attempt instead of counting a failure.
        return !submitting && !isWorking && !isLockedOut && length >= PasscodePolicy.minimumLength
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            input
                .modifier(Shake(animatableData: CGFloat(failureCount)))
                .animation(.default, value: failureCount)

            status
                .frame(minHeight: 44)

            Spacer(minLength: 12)

            if kind == .digits {
                KeypadView(
                    shuffled: shuffled,
                    isEnabled: !isLockedOut && !submitting && !isWorking,
                    canSubmit: canSubmit,
                    onDigit: { buffer.append(asciiDigit: $0) },
                    onDelete: { buffer.removeLast() },
                    onSubmit: { submit() }
                )
                .padding(.bottom, 24)
            } else {
                Button(submitLabel) { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSubmit)
                    .padding(.bottom, 48)
            }
        }
        .padding(.horizontal, 16)
        .sensoryFeedback(.error, trigger: failureCount)
    }

    @ViewBuilder
    private var input: some View {
        switch kind {
        case .digits:
            PasscodeDots(count: buffer.count)
        case .passphrase:
            SecureField("Passphrase", text: $passphrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { submit() }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .disabled(isLockedOut || submitting || isWorking)
        }
    }

    @ViewBuilder
    private var status: some View {
        if submitting || isWorking {
            ProgressView()
        } else if let retryAfter, isLockedOut {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(retryAfter.timeIntervalSince(context.date).rounded(.up)))
                Text("Too many attempts. Try again in \(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else if let message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        } else if let hint {
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        if kind == .passphrase {
            buffer.replace(withUTF8: passphrase)
            passphrase = ""
        }
        submitting = true
        Task {
            await onSubmit(buffer)
            buffer.wipe()
            submitting = false
        }
    }
}

/// Side-to-side shake for a wrong passcode.
struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}
