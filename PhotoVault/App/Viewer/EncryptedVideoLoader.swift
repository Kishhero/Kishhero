import AVFoundation
import UniformTypeIdentifiers
import VaultCore

/// Feeds AVPlayer decrypted bytes straight from the encrypted blob.
///
/// The player asks for byte ranges through a custom URL scheme; each request
/// is answered by decrypting only the 256 KiB chunks it covers. Seeking to
/// the middle of a two-hour video decrypts a few chunks, not the whole file.
///
/// Protects against: a decrypted copy of the video ever being written to
/// disk. There is no temporary file, and AVFoundation keeps no disk cache
/// for resource-loader assets.
/// Does not protect against: decoded frames and the chunks being served,
/// which are in memory while the video plays.
///
/// `@unchecked Sendable`: the decryptor is not thread-safe, so every access
/// happens on `queue`, which is also the queue the resource loader calls the
/// delegate on.
final class EncryptedVideoLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "photovault-encrypted"

    let queue = DispatchQueue(label: "PhotoVault.encrypted-video", qos: .userInitiated)
    private let decryptor: StreamDecryptor
    private let contentType: String
    /// Answer in 1 MiB pieces, giving the queue back between pieces so a
    /// seek can cancel a large request instead of waiting behind it.
    private static let responseSize: UInt64 = 1 << 20

    init(decryptor: StreamDecryptor, contentType: String) {
        self.decryptor = decryptor
        self.contentType = contentType
    }

    /// A URL AVFoundation can't open on its own, so it has to ask this delegate.
    func url(for item: VaultItem) -> URL {
        let fileExtension = UTType(item.uniformType)?.preferredFilenameExtension ?? "mov"
        return URL(string: "\(Self.scheme)://video/\(item.id.uuidString).\(fileExtension)")!
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let length = decryptor.contentLength
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = Int64(length)
            information.isByteRangeAccessSupported = true
            information.isEntireLengthAvailableOnDemand = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = UInt64(max(0, dataRequest.requestedOffset))
        let end = dataRequest.requestsAllDataToEndOfResource
            ? length
            : min(length, start + UInt64(max(0, dataRequest.requestedLength)))
        serve(Pending(request: loadingRequest), from: start, to: end)
        return true
    }

    /// AVFoundation's request objects aren't Sendable; they are only ever
    /// touched on `queue`.
    private struct Pending: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
    }

    private func serve(_ pending: Pending, from offset: UInt64, to end: UInt64) {
        let request = pending.request
        guard !request.isCancelled, !request.isFinished else { return }
        guard offset < end else {
            request.finishLoading()
            return
        }
        do {
            let data = try decryptor.read(at: offset, count: Int(min(Self.responseSize, end - offset)))
            guard !data.isEmpty else {
                request.finishLoading()
                return
            }
            request.dataRequest?.respond(with: data)
            let next = offset + UInt64(data.count)
            queue.async { [weak self] in
                self?.serve(pending, from: next, to: end)
            }
        } catch {
            // A chunk that fails authentication stops playback; tampered
            // bytes are never handed to the decoder.
            request.finishLoading(with: error)
        }
    }
}
