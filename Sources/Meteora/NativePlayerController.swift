import AppKit
import AVFoundation
import AVKit
import SwiftUI
import MeteoraCore

/// Plays everything macOS opens itself (MP4, MOV, M4A, MP3, WAV, …) with
/// AVFoundation. Key frames are taken with an image generator straight from
/// the file, so analysis never disturbs playback.
@MainActor
final class NativePlayerController: PlayerController {
    let avPlayer: AVPlayer
    private let asset: AVURLAsset
    private let thumbGenerator: AVAssetImageGenerator
    private let fullGenerator: AVAssetImageGenerator
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var lastSampleTime: Double?

    init(url: URL) {
        asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        avPlayer = AVPlayer(playerItem: item)
        avPlayer.actionAtItemEnd = .pause
        avPlayer.preventsDisplaySleepDuringVideoPlayback = true

        thumbGenerator = AVAssetImageGenerator(asset: asset)
        thumbGenerator.appliesPreferredTrackTransform = true
        thumbGenerator.maximumSize = CGSize(width: 320, height: 200)
        thumbGenerator.requestedTimeToleranceBefore = .zero
        thumbGenerator.requestedTimeToleranceAfter = .zero

        fullGenerator = AVAssetImageGenerator(asset: asset)
        fullGenerator.appliesPreferredTrackTransform = true
        fullGenerator.maximumSize = CGSize(width: 2560, height: 2560)
        fullGenerator.requestedTimeToleranceBefore = .zero
        fullGenerator.requestedTimeToleranceAfter = .zero
        super.init()

        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = time.seconds
                if t.isFinite { self.currentTime = t }
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let duration = item.duration.seconds
            let size = item.presentationSize
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if duration.isFinite, duration > 0 { self.duration = duration }
                    if size.width > 0, size.height > 0 { self.videoSize = size }
                    self.isReady = true
                    self.log("native:ready")
                case .failed:
                    self.mediaErrorCode = -2
                    self.log("native:failed \(item.error?.localizedDescription ?? "")")
                default: break
                }
            }
        }
        controlObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    override func tearDown() {
        avPlayer.pause()
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        controlObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        thumbGenerator.cancelAllCGImageGeneration()
        fullGenerator.cancelAllCGImageGeneration()
        avPlayer.replaceCurrentItem(with: nil)
    }

    override func play() {
        if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
        avPlayer.playImmediately(atRate: Float(rate))
        isPlaying = true
    }

    override func pause() {
        avPlayer.pause()
        isPlaying = false
    }

    override func seek(to t: Double) {
        let clamped = max(0, min(t, duration > 0 ? duration : t))
        currentTime = clamped
        lastSampleTime = nil
        avPlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    override func setRate(_ r: Double) {
        rate = r
        if isPlaying { avPlayer.rate = Float(r) }
    }

    override func setVolume(_ v: Double) {
        volume = v
        avPlayer.volume = Float(v)
    }

    // MARK: Frames for key-frame analysis

    override func sample(at t: Double) async throws -> FrameThumb {
        let image = try await thumbGenerator.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image
        lastSampleTime = t
        guard let thumb = Self.thumb(from: image) else { throw SampleError.failed("Не удалось получить кадр.") }
        return thumb
    }

    override func grabFrame() async throws -> CGImage? {
        let t = lastSampleTime ?? currentTime
        return try await fullGenerator.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image
    }

    override func debugInfo() async -> String {
        "native ready=\(isReady) size=\(Int(videoSize.width))x\(Int(videoSize.height)) duration=\(duration)"
    }
}

/// AVPlayer surface without controls: Meteora draws its own transport.
struct NativePlayerHost: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.allowsMagnification = false
        v.showsFullScreenToggleButton = false
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
