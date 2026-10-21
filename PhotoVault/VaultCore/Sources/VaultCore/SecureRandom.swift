import Foundation
#if canImport(Security)
import Security
#endif

/// A source of random bytes for salts, nonces and keys.
///
/// Production code only ever uses `SecureRandom`. The protocol exists so tests
/// can replay fixed bytes and reproduce the reference vectors exactly.
protocol RandomBytesGenerator {
    func bytes(_ count: Int) throws -> [UInt8]
}

/// The operating system's cryptographically secure random number generator:
/// `SecRandomCopyBytes` on Apple platforms, `getrandom(2)` (through
/// `SystemRandomNumberGenerator`) on Linux, where only the tests run.
struct SecureRandom: RandomBytesGenerator {
    func bytes(_ count: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return output }
        #if canImport(Security)
        let status = output.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        // Never fall back to a weaker generator: without good randomness no
        // key or nonce can be trusted, so refuse to continue.
        guard status == errSecSuccess else { throw VaultError.randomGenerationFailed }
        #else
        var generator = SystemRandomNumberGenerator()
        for index in output.indices {
            output[index] = generator.next()
        }
        #endif
        return output
    }
}
