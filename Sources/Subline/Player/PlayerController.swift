import Foundation
import AVFoundation
import SublineCore

/// Video playback for the preview: play/pause, frame stepping and precise scrubbing.
/// Files AVFoundation cannot play (MKV, WebM, AVI, ...) get a playable copy made with ffmpeg in the background.
@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    /// A playable item is loaded and its first frame can be shown.
    @Published private(set) var isReady = false
    /// Progress of making a playable copy, nil when not needed.
    @Published private(set) var copyProgress: Double?
    @Published private(set) var copyFailed = false
    @Published private(set) var frameRate: Double = 30

    /// Called on every time change (playback, seeking, stepping).
    var onTimeChange: ((Double) -> Void)?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var isSeeking = false
    private var chaseTarget: CMTime?
    private var mediaURL: URL?

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSeeking, time.isNumeric else { return }
                self.setTime(time.seconds)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    // MARK: - Loading

    func load(_ info: MediaInfo) {
        unload()
        mediaURL = info.url
        duration = info.duration
        frameRate = info.fps ?? 30
        loadTask = Task { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: info.url)
            if await Self.canPlayDirectly(asset, info: info) {
                await self.setAsset(asset, info: info)
                return
            }
            await self.loadPlaybackCopy(info)
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        isReady = false
        isPlaying = false
        copyProgress = nil
        copyFailed = false
        currentTime = 0
        mediaURL = nil
    }

    private static func canPlayDirectly(_ asset: AVURLAsset, info: MediaInfo) async -> Bool {
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        if info.hasVideo {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  (try? await track.load(.isDecodable)) == true else { return false }
        }
        if info.hasAudio {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  (try? await track.load(.isDecodable)) == true else { return false }
        }
        return true
    }

    private func setAsset(_ asset: AVURLAsset, info: MediaInfo) async {
        let item = AVPlayerItem(asset: asset)
        if info.isHDR {
            // Show HDR tone-mapped to SDR, exactly like the exported video.
            if let composition = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) {
                composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
                composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
                composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
                item.videoComposition = composition
            }
        }
        guard !Task.isCancelled, mediaURL == info.url else { return }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let ready = item.status == .readyToPlay
            let failed = item.status == .failed
            Task { @MainActor in
                guard let self else { return }
                if ready {
                    self.isReady = true
                    if let rate = try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate), rate > 0 {
                        self.frameRate = Double(rate)
                    }
                } else if failed {
                    self.isReady = false
                    self.copyFailed = true
                }
            }
        }
        player.replaceCurrentItem(with: item)
        seek(to: currentTime)
    }

    private func loadPlaybackCopy(_ info: MediaInfo) async {
        let destination = AppPaths.proxiesDir.appendingPathComponent((TranscriptCache.key(for: info.url) ?? UUID().uuidString) + ".mp4")
        if !FileManager.default.fileExists(atPath: destination.path) {
            copyProgress = 0
            let partial = destination.deletingPathExtension().appendingPathExtension("part.mp4")
            let job = Task.detached(priority: .utility) { [weak self] in
                try await FFmpeg.makePlaybackCopy(of: info, to: partial) { value in
                    Task { @MainActor in self?.copyProgress = value }
                }
            }
            do {
                try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
                try FileManager.default.moveItem(at: partial, to: destination)
                Self.trimProxyCache(keeping: destination)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                if !Task.isCancelled, mediaURL == info.url {
                    copyProgress = nil
                    copyFailed = true
                }
                return
            }
        }
        guard !Task.isCancelled, mediaURL == info.url else { return }
        copyProgress = nil
        await setAsset(AVURLAsset(url: destination), info: info)
    }

    /// Keeps the playback copies folder small: the newest few files stay.
    private static func trimProxyCache(keeping current: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.proxiesDir, includingPropertiesForKeys: keys) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(6) where file != current {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard isReady else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    /// Moves by whole frames (negative = back). The player pauses, like in video editors.
    func step(frames: Int) {
        pause()
        if isReady, let item = player.currentItem, frames > 0 ? item.canStepForward : item.canStepBackward {
            item.step(byCount: frames)
        } else {
            seek(to: currentTime + Double(frames) / max(1, frameRate))
        }
    }

    /// Precise seek. Rapid calls (scrubbing) are coalesced: only the latest target is sought next,
    /// so the picture keeps up with the pointer.
    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(0, duration))
        setTime(clamped)
        guard isReady || player.currentItem != nil else { return }
        chaseTarget = CMTime(seconds: clamped, preferredTimescale: 600)
        if !isSeeking { performChaseSeek() }
    }

    private func performChaseSeek() {
        guard let target = chaseTarget else {
            isSeeking = false
            return
        }
        isSeeking = true
        chaseTarget = nil
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.chaseTarget != nil {
                    self.performChaseSeek()
                } else {
                    self.isSeeking = false
                }
            }
        }
    }

    private func setTime(_ seconds: Double) {
        guard abs(seconds - currentTime) > 0.0001 else { return }
        currentTime = seconds
        onTimeChange?(seconds)
    }

    /// Frame number at the current time (for the transport display).
    var currentFrame: Int { Int((currentTime * frameRate).rounded(.down)) }
}
