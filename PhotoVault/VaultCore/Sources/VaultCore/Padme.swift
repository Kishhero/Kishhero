/// Padmé padding (Nikitin et al., "Reducing Metadata Leakage from Encrypted
/// Files and Communication with PURBs", PETS 2019).
///
/// Rounds a length up so that only the top few bits of it are kept. Encrypted
/// files of similar size then come out exactly the same size, so someone
/// looking at the vault folder cannot match a file to a known photo or video
/// by its byte count, or tell a 41-second clip from a 43-second one.
///
/// Cost: at most about 12% extra storage (11.6% worst case, much less for
/// large files on average). It hides exact sizes, not rough ones: a 4 MB photo
/// still looks different from a 2 GB video.
public enum Padme {
    public static func paddedLength(_ length: UInt64) -> UInt64 {
        guard length >= 2 else { return length }
        let exponent = UInt64(63 - length.leadingZeroBitCount)           // floor(log2(L))
        let exponentBits = UInt64(64 - exponent.leadingZeroBitCount)     // floor(log2(E)) + 1
        let mask = (UInt64(1) << (exponent - exponentBits)) - 1
        let (sum, overflow) = length.addingReportingOverflow(mask)
        return overflow ? length : sum & ~mask
    }
}
