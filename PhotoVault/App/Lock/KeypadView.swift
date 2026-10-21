import SwiftUI

/// The app's own digit keypad.
///
/// Protects against: keyboard apps and keyboard caches ever seeing the PIN,
/// and, with shuffling on, someone learning the PIN from where your finger
/// goes or from smudges on the screen.
/// Does not protect against: someone watching the screen itself.
struct KeypadView: View {
    var shuffled: Bool
    var isEnabled: Bool
    var canSubmit: Bool
    var onDigit: (UInt8) -> Void
    var onDelete: () -> Void
    var onSubmit: () -> Void

    @State private var digits: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
    @State private var taps = 0

    private let columns = Array(repeating: GridItem(.fixed(78), spacing: 24), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(digits.prefix(9), id: \.self) { digit in
                digitKey(digit)
            }
            Button {
                onDelete()
            } label: {
                Image(systemName: "delete.left")
                    .font(.title2)
                    .frame(width: 78, height: 78)
            }
            .accessibilityLabel("Delete")

            digitKey(digits[9])

            Button {
                onSubmit()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.largeTitle)
                    .frame(width: 78, height: 78)
            }
            .disabled(!canSubmit)
            .accessibilityLabel("Unlock")
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .onAppear {
            if shuffled {
                // SystemRandomNumberGenerator is the system CSPRNG, so the
                // layout cannot be predicted.
                digits.shuffle()
            }
        }
    }

    private func digitKey(_ digit: UInt8) -> some View {
        Button {
            taps += 1
            onDigit(digit)
        } label: {
            Text(String(digit))
                .font(.system(size: 34, weight: .regular, design: .rounded))
                .frame(width: 78, height: 78)
                .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(digit))
    }
}

/// One dot per character typed; at least 8 outlines, as a hint of the minimum length.
struct PasscodeDots: View {
    let count: Int
    private let maxDots = 16

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<min(max(count, 8), maxDots), id: \.self) { index in
                Circle()
                    .strokeBorder(.primary, lineWidth: 1.5)
                    .background(Circle().fill(index < count ? Color.primary : Color.clear))
                    .frame(width: 13, height: 13)
            }
            if count > maxDots {
                Text("+\(count - maxDots)")
                    .font(.footnote.monospacedDigit())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) characters entered")
    }
}
