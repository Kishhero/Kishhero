// swift-tools-version: 6.0
import PackageDescription

// VaultCore: the vault's cryptography and storage formats, with no UI.
// Kept as its own package so it can be tested quickly with `swift test`
// (macOS or Linux) without building or launching the iOS app.
let package = Package(
    name: "VaultCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VaultCore", targets: ["VaultCore"]),
    ],
    dependencies: [
        // libsodium, for Argon2id only. CryptoKit has no memory-hard password KDF.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.9.1"),
        // Apple's open-source CryptoKit API. Linked only on Linux, where CryptoKit
        // does not exist; the iOS app uses the system CryptoKit and ships none of it.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "VaultCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "VaultCoreTests",
            dependencies: [
                "VaultCore",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
    ]
)
