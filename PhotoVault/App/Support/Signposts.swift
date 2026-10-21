import os

/// Intervals for Instruments' "Points of Interest" track: unlock, vault
/// creation, each import, each thumbnail and photo decode. Records timing
/// only, never names or data. See "Measuring performance" in the README.
enum Signposts {
    static func make() -> OSSignposter {
        OSSignposter(subsystem: "PhotoVault", category: .pointsOfInterest)
    }
}
