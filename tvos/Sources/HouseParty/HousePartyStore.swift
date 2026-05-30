import Foundation

/// Coordinates "House Party" mode: a shared, server-side fake player that lets
/// multiple Apple TVs watch in sync. See `src/api/houseparty.rs` for the server
/// half.
///
/// Responsibilities, split deliberately:
///   - This store owns **polling** (once a second) and **nav-level mirroring**:
///     starting the party's video when it changes, and popping back to Home when
///     the party goes idle. Nav-level work needs the `NavCoordinator`, not the
///     VLC proxy.
///   - `PlayerView` owns **fine-grained mirroring** for the video that's already
///     playing (matching play/pause and seeking when the position drifts >1s),
///     because that needs the live VLC proxy.
///
/// Feedback loops are avoided by construction: mirror-application only ever
/// calls proxy/nav methods, never POSTs. POSTs come exclusively from explicit
/// local-user gestures in `PlayerView`. The ">1s" seek damping keeps two
/// clients from thrashing each other.
@MainActor
final class HousePartyStore: ObservableObject {
    static let shared = HousePartyStore()

    private let client = DuplexClient()

    /// Whether this client is participating (mirroring + broadcasting).
    /// In-memory only and always starts false: joining is a deliberate
    /// per-session act, never restored on launch — a TV shouldn't silently
    /// auto-join and start playing the room's video every time it opens.
    @Published private(set) var joined = false
    /// The most recent poll result — drives the Home status hint and the
    /// fine-grained sync in `PlayerView`. `nil` until the first successful poll.
    @Published private(set) var latest: HousePartyState?

    /// Set once by `RootView` so the store can drive navigation.
    weak var nav: NavCoordinator?

    /// When the store mirror-starts a video, it records that vpath here so the
    /// mounting `PlayerView` knows NOT to re-announce it as a local-user action.
    /// Consumed (cleared) by `PlayerView` once it has decided whether to
    /// announce.
    var suppressAnnounceVpath: String?

    /// Local-authority window. After this client takes a local action (start /
    /// scrub / pause / play / clear) it broadcasts that state, but the server
    /// won't reflect it until the POST lands and the next poll returns it (~1s
    /// round-trip). During that window we must NOT mirror incoming poll state,
    /// or this client fights its own action — yanking a scrub back to the stale
    /// server position, or popping the player on a stale `idle` right after we
    /// started one. A follower never calls `markLocalAction`, so it is never
    /// suppressed: "anyone can DJ" is preserved.
    private var suppressMirrorUntil: Date = .distantPast
    var mirrorSuppressed: Bool { Date() < suppressMirrorUntil }
    func markLocalAction() { suppressMirrorUntil = Date().addingTimeInterval(2.5) }

    private var pollTask: Task<Void, Never>?

    private init() {
        startPolling()
    }

    // MARK: join / leave

    func join() {
        guard !joined else { return }
        joined = true
        NSLog("[Duplex/HouseParty] joined")
        // Mirror immediately rather than waiting up to a second for the next tick.
        Task { await pollOnce() }
    }

    /// Leaving is local-only: it stops us mirroring/broadcasting but does NOT
    /// idle the party for everyone else.
    func leave() {
        guard joined else { return }
        joined = false
        NSLog("[Duplex/HouseParty] left")
    }

    // MARK: broadcasting (DJ direction) — called from PlayerView user gestures

    /// Announce local playback state to the party. No-op when not joined.
    func broadcast(vpath: String, duration: Double, position: Double, playing: Bool) {
        guard joined else { return }
        markLocalAction()
        NSLog("[Duplex/HouseParty] broadcast vpath=%@ pos=%.1f dur=%.1f playing=%d",
              vpath, position, duration, playing ? 1 : 0)
        Task {
            do {
                try await client.postHouseParty(vpath: vpath, duration: duration, position: position, playing: playing)
            } catch {
                NSLog("[Duplex/HouseParty] broadcast failed: %@", error.localizedDescription)
            }
        }
    }

    /// Force the party idle (stops the video for the whole room). Used when a
    /// joined user backs out of a video.
    func clear() {
        guard joined else { return }
        markLocalAction()
        NSLog("[Duplex/HouseParty] clear → idle")
        Task {
            do { try await client.clearHouseParty() } catch {
                NSLog("[Duplex/HouseParty] clear failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: polling

    /// Poll once a second for the whole app lifetime. A 1 Hz GET on a LAN is
    /// negligible, and polling unconditionally keeps the Home status hint live
    /// even when not joined (the stretch goal) without depending on fragile
    /// NavigationStack appear/disappear callbacks. Reconciliation (acting on the
    /// state) is still gated on `joined`.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func pollOnce() async {
        do {
            let state = try await client.housePartyState()
            latest = state
            if joined { reconcile(state) }
        } catch {
            // Transient network blips are expected on a LAN; keep polling.
        }
    }

    // MARK: nav-level mirroring

    /// Reconcile the party's nav-level state with ours. Fine-grained position /
    /// play-pause sync for the *currently playing* video is handled in
    /// `PlayerView`; here we only handle "start the right video" and "stop when
    /// the party is idle".
    private func reconcile(_ state: HousePartyState) {
        guard let nav else { return }
        // Don't act on poll state that predates our own just-taken local action
        // (see `suppressMirrorUntil`) — it would pop/restart the video we just
        // started, before our announce has propagated.
        if mirrorSuppressed { return }
        let current = nav.currentPlayerVpath

        if !state.active {
            // Party idle → make sure we're not playing anything.
            if current != nil { nav.path.removeLast() }
            return
        }
        guard let target = state.vpath else { return }
        if current == target {
            // Already on the right video — PlayerView handles seek / play-pause.
            return
        }
        // Different video (or we're not in a player yet) → start the party's.
        NSLog("[Duplex/HouseParty] mirror start target=%@ current=%@ pos=%.1f playing=%d",
              target, current ?? "nil", state.position, state.playing ? 1 : 0)
        suppressAnnounceVpath = target
        nav.playFromHouseParty(vpath: target)
    }
}
