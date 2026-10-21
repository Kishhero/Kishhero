import AVFoundation
import AVKit
import UIKit
import VaultCore

/// A video page. Starts playing when it is fully on screen and tears the
/// player down when it leaves, so only one video is ever decrypting.
///
/// Turned off, because each would show vault content outside the app:
/// - Picture in Picture, which keeps playing after the vault locks
/// - AirPlay, which sends the video over the network to another device
/// - the lock screen and Control Center "Now Playing" card
final class VideoPageController: MediaPageController {
    private let posterView = UIImageView()
    private let messageLabel = UILabel()
    private var playerController: AVPlayerViewController?
    private var loader: EncryptedVideoLoader?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        posterView.contentMode = .scaleAspectFit
        posterView.frame = view.bounds
        posterView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        posterView.image = library.cachedThumbnail(for: item)
        view.addSubview(posterView)

        messageLabel.textColor = .secondaryLabel
        messageLabel.font = .preferredFont(forTextStyle: .callout)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPlayback()
    }

    private func startPlayback() {
        guard playerController == nil else { return }
        do {
            let loader = EncryptedVideoLoader(
                decryptor: try library.vault.originalDecryptor(for: item),
                contentType: item.uniformType
            )
            let asset = AVURLAsset(url: loader.url(for: item))
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player.allowsExternalPlayback = false

            let controller = AVPlayerViewController()
            controller.player = player
            controller.allowsPictureInPicturePlayback = false
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            controller.updatesNowPlayingInfoCenter = false
            controller.entersFullScreenWhenPlaybackBegins = false
            controller.exitsFullScreenWhenPlaybackEnds = false

            addChild(controller)
            controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.backgroundColor = .clear
            view.addSubview(controller.view)
            controller.didMove(toParent: self)

            // The resource loader holds its delegate weakly; this page keeps it alive.
            self.loader = loader
            playerController = controller
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            player.play()
        } catch {
            messageLabel.text = "This video couldn't be opened."
            messageLabel.isHidden = false
        }
    }

    private func stopPlayback() {
        guard let controller = playerController else { return }
        controller.player?.pause()
        controller.player?.replaceCurrentItem(with: nil)
        controller.player = nil
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        playerController = nil
        loader = nil
    }
}
