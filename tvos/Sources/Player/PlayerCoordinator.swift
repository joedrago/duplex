import AVKit
import Combine
import Foundation

/// Wraps an `AVPlayer` for one virtual path. Handles:
///   • resume-position read at start, heartbeat write while playing
///   • end-of-video detection → fires `didEnd`
///   • surfaces `currentTime`/`duration` for the subtitle overlay tick.
@MainActor
final class PlayerCoordinator: ObservableObject {
    let player: AVPlayer

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var didEnd: Bool = false
    @Published private(set) var hasFailed: String? = nil

    let vpath: String
    private let resumeStore: ResumeStore
    private var timeObserver: Any?
    private var heartbeatObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusKVO: NSKeyValueObservation?
    private var didSeekToResume = false

    init(url: URL, vpath: String, resumeStore: ResumeStore = .shared) {
        self.vpath = vpath
        self.resumeStore = resumeStore

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        // Periodic time observer (~10Hz) for subtitle/progress sync.
        let tickInterval = CMTime(value: 1, timescale: 10)
        timeObserver = player.addPeriodicTimeObserver(forInterval: tickInterval, queue: .main) { [weak self] t in
            // Observer queue is .main; hop to MainActor explicitly for Swift concurrency.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
            }
        }

        // Heartbeat write (5s) to ResumeStore.
        let heartbeat = CMTime(seconds: 5, preferredTimescale: 600)
        heartbeatObserver = player.addPeriodicTimeObserver(forInterval: heartbeat, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistResume()
            }
        }

        // End-of-video.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didEnd = true
                if let v = self?.vpath { self?.resumeStore.remove(v) }
            }
        }

        // Status KVO: seek to resume position once ready, surface failures.
        statusKVO = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    if !self.didSeekToResume {
                        self.didSeekToResume = true
                        if let entry = self.resumeStore.get(self.vpath), entry.pos > 5 {
                            let t = CMTime(seconds: entry.pos, preferredTimescale: 600)
                            self.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                                self.player.play()
                            }
                        } else {
                            self.player.play()
                        }
                    }
                case .failed:
                    self.hasFailed = item.error?.localizedDescription ?? "playback failed"
                default:
                    break
                }
            }
        }
    }

    /// Stop playback and write the final resume position. Safe to call multiple
    /// times. Call from `onDisappear`.
    func teardown() {
        player.pause()
        persistResume()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let heartbeatObserver { player.removeTimeObserver(heartbeatObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        heartbeatObserver = nil
        endObserver = nil
        statusKVO?.invalidate()
        statusKVO = nil
    }

    private func persistResume() {
        guard !didEnd else { return }
        let pos = player.currentTime().seconds
        let dur = duration > 0 ? duration : (player.currentItem?.duration.seconds ?? 0)
        guard pos.isFinite, dur.isFinite, dur > 0 else { return }
        resumeStore.update(vpath: vpath, pos: pos, dur: dur)
    }
}
