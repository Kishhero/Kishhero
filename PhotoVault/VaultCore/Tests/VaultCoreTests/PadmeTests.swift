import Testing
@testable import VaultCore

@Suite("Padmé padding")
struct PadmeTests {
    @Test("matches the reference implementation")
    func referenceValues() {
        for (length, expected) in ReferenceVectors.padme {
            #expect(Padme.paddedLength(length) == expected, "padme(\(length))")
        }
    }

    @Test("never shrinks, is stable, and costs at most 12%")
    func properties() {
        let violations = (UInt64(0)..<(1 << 16)).filter { length in
            let padded = Padme.paddedLength(length)
            let overhead = (length == 0 || padded < length) ? 0 : Double(padded - length) / Double(length)
            return padded < length || Padme.paddedLength(padded) != padded || overhead > 0.12
        }
        #expect(violations.isEmpty, "first bad lengths: \(violations.prefix(5))")
    }

    @Test("files of similar size become indistinguishable")
    func hidesExactSizes() {
        // Two "videos" about 100 KB apart in a 50 MB range pad to the same size.
        #expect(Padme.paddedLength(50_000_000) == Padme.paddedLength(50_100_000))
        // But wildly different sizes stay different: Padmé hides exact sizes, not rough ones.
        #expect(Padme.paddedLength(4_000_000) != Padme.paddedLength(2_000_000_000))
    }

    @Test("does not overflow near the top of the range")
    func noOverflow() {
        #expect(Padme.paddedLength(.max) == .max)
        #expect(Padme.paddedLength(.max - 1) >= .max - 1)
    }
}
