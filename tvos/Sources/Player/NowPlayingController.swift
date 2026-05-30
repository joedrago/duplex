import AVFoundation
import Foundation
import MediaPlayer
import VLCUI

/// Bridges our VLC-backed playback to tvOS's media-remote subsystem. With this
/// wired up, Siri commands like "seek to 20 minutes" / "skip ahead a minute" /
/// "pause" are routed into our `VLCVideoPlayer.Proxy`.
///
/// Two pieces:
///   1. `MPRemoteCommandCenter` handlers — receive incoming commands.
///   2. `MPNowPlayingInfoCenter` — publish what we're playing so the system
///      knows which app is the playback target.
@MainActor
final class NowPlayingController {
    /// Fired every time a remote command (Siri, Control Center, headphone
    /// button, etc.) lands. Lets the player surface flash the OSD so the user
    /// sees the seek take effect.
    var onRemoteCommand: (() -> Void)?

    private weak var proxy: VLCVideoPlayer.Proxy?
    private weak var session: PlayerSession?
    private var title: String = ""
    private var vpath: String = ""
    private var registrations: [(MPRemoteCommand, Any)] = []
    private var didConfigureAudioSession = false

    func attach(proxy: VLCVideoPlayer.Proxy, session: PlayerSession, vpath: String) {
        self.proxy = proxy
        self.session = session
        self.vpath = vpath
        self.title = DuplexFormat.leaf(of: vpath)
        configureAudioSessionOnce()
        registerCommands()
    }

    /// Mirror a Siri / Control Center / system-scrubber command to House Party.
    /// These are explicit user gestures, identical in intent to the on-screen
    /// controls — they just arrive through `MPRemoteCommandCenter`. No-op when
    /// not joined.
    private func broadcastHouseParty(position: Double, playing: Bool) {
        guard let session else { return }
        HousePartyStore.shared.broadcast(
            vpath: vpath,
            duration: Double(session.durationSeconds),
            position: position,
            playing: playing
        )
    }

    func detach() {
        for (command, target) in registrations {
            command.removeTarget(target)
        }
        registrations.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Push the latest media position/state so Siri + Control Center stay in sync.
    func updateNowPlayingInfo(positionSeconds: Int, durationSeconds: Int, isPlaying: Bool) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        if durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationSeconds)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(positionSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureAudioSessionOnce() {
        guard !didConfigureAudioSession else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [])
        try? s.setActive(true)
        didConfigureAudioSession = true
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        register(center.playCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            self.proxy?.play()
            self.broadcastHouseParty(position: Double(self.session?.positionSeconds ?? 0), playing: true)
            self.onRemoteCommand?()
            return .success
        }
        register(center.pauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            self.proxy?.pause()
            self.broadcastHouseParty(position: Double(self.session?.positionSeconds ?? 0), playing: false)
            self.onRemoteCommand?()
            return .success
        }
        register(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            let willPlay = self.session?.isPlaying != true
            if willPlay { self.proxy?.play() } else { self.proxy?.pause() }
            self.broadcastHouseParty(position: Double(self.session?.positionSeconds ?? 0), playing: willPlay)
            self.onRemoteCommand?()
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [10]
        register(center.skipForwardCommand) { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            if #available(tvOS 16.0, *) {
                self.proxy?.jumpForward(.seconds(Int(interval)))
            }
            let target = Double((self.session?.positionSeconds ?? 0) + Int(interval))
            self.broadcastHouseParty(position: target, playing: self.session?.isPlaying ?? true)
            self.onRemoteCommand?()
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        register(center.skipBackwardCommand) { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            if #available(tvOS 16.0, *) {
                self.proxy?.jumpBackward(.seconds(Int(interval)))
            }
            let target = Double(max(0, (self.session?.positionSeconds ?? 0) - Int(interval)))
            self.broadcastHouseParty(position: target, playing: self.session?.isPlaying ?? true)
            self.onRemoteCommand?()
            return .success
        }

        // The big one — "seek to 20 minutes" / the system scrubber lands here.
        // `positionTime` is the exact destination, so we broadcast it directly
        // (no VLC-readback lag).
        register(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self,
                  let pos = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            if #available(tvOS 16.0, *) {
                self.proxy?.setSeconds(.seconds(Int(pos.positionTime)))
            }
            self.broadcastHouseParty(position: pos.positionTime, playing: self.session?.isPlaying ?? true)
            self.onRemoteCommand?()
            return .success
        }
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        registrations.append((command, target))
    }
}
