import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    enum LoadState<T> {
        case idle
        case loading
        case loaded(T)
        case failed(String)
    }

    @Published var libraries: LoadState<[Entry]> = .idle
    @Published var recent:    LoadState<[RecentItem]> = .idle

    private let client = DuplexClient()

    func load() async {
        async let libsTask: Void = loadLibraries(force: false)
        async let recentTask: Void = loadRecent(force: false)
        _ = await (libsTask, recentTask)
    }

    /// Explicit refresh: re-fetch unconditionally and swap in the new data when
    /// it lands, without blanking to `.loading` first (so the list doesn't flash
    /// and focus stays put).
    func reload() async {
        async let libsTask: Void = loadLibraries(force: true)
        async let recentTask: Void = loadRecent(force: true)
        _ = await (libsTask, recentTask)
    }

    private func loadLibraries(force: Bool) async {
        // Skip on pop-back to Home — see BrowseViewModel.load for rationale.
        if !force, case .loaded = libraries { return }
        // Only show the loading state on the first load; a refresh keeps the
        // current list visible until the new data arrives.
        if !force { libraries = .loading }
        do {
            let resp = try await client.browse(path: "")
            libraries = .loaded(resp.entries)
        } catch {
            libraries = .failed(error.localizedDescription)
        }
    }

    private func loadRecent(force: Bool) async {
        if !force, case .loaded = recent { return }
        if !force { recent = .loading }
        do {
            let resp = try await client.recent(limit: 30)
            recent = .loaded(resp.items)
        } catch {
            recent = .failed(error.localizedDescription)
        }
    }
}

/// Identifies a focusable row on the home screen.
enum HomeFocus: Hashable {
    case search
    case library(String)
    case recent(String)
    case binge(String)
    case continueWatching(String)
    case houseParty
    case refresh
    case settings
}

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @EnvironmentObject private var nav: NavCoordinator
    @ObservedObject private var resume = ResumeStore.shared
    @ObservedObject private var binges = BingeStore.shared
    @ObservedObject private var viewPref = ViewPreference.shared
    @ObservedObject private var houseParty = HousePartyStore.shared
    @ObservedObject private var ext = ExtensionPreference.shared
    @ObservedObject private var refresh = LibraryRefresh.shared

    @State private var focus: HomeFocus?
    @State private var didSetInitialFocus = false

    private let client = DuplexClient()

    // One dialog at a time: create confirm, delete confirm, or error. A single
    // `.alert` — see BingeDialog for why.
    @State private var dialog: BingeDialog?

    var body: some View {
        VStack(spacing: 0) {
            BrowseHeader(crumbPath: nil)
            WrapColumns(
                columns: focusColumns,
                current: $focus,
                isActive: dialog == nil,
                onActivate: handleActivate,
                onLongSelect: handleLongSelect,
                onPlayPause: { viewPref.cycle() },
                crossNavigate: posterCrossNavigate
            ) {
                HStack(alignment: .top, spacing: DuplexMetric.columnGap) {
                    librariesColumn
                    recentColumn
                    continueColumn
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
            footerHint
        }
        .background(DuplexColor.bg.ignoresSafeArea())
        .ignoresSafeArea()
        .navigationBarHidden(true)
        .alert(item: $dialog) { d in bingeAlert(d) }
        .onChange(of: dialog == nil) { _, isNil in
            // Freeze the 1 Hz House Party poll while a dialog is up; its republish
            // would otherwise re-render Home and re-present the alert, yanking
            // focus off the user's selection every second.
            if isNil { houseParty.resumePolling() } else { houseParty.pausePolling() }
        }
        .onDisappear { houseParty.resumePolling() }
        .task {
            await vm.load()
            applyInitialFocusIfNeeded()
        }
        .onAppear {
            if !didSetInitialFocus {
                applyInitialFocusIfNeeded()
            }
            // Pop-back from a library / route: @State preserves `focus`, so the
            // user lands on whatever row they activated. No store needed.
        }
    }

    // MARK: focus topology

    /// Libraries always display in the server's configured order — they are not
    /// re-sorted by the user's sort preference (which still governs sub-folder
    /// listings in BrowseView and the badge on the footer hint).
    private var libraryEntries: [Entry] {
        if case .loaded(let entries) = vm.libraries { return entries }
        return []
    }

    private var recentItems: [RecentItem] {
        if case .loaded(let items) = vm.recent { return items }
        return []
    }

    private var continueItems: [(vpath: String, entry: ResumeEntry)] {
        resume.visible
    }

    private var bingeItems: [Binge] { binges.ordered }

    /// Drives `WrapColumns`. Order here matches the visual HStack so left/right
    /// arrows cross between adjacent columns naturally. The third column stacks
    /// binges above Continue Watching, so up/down flows through both.
    /// Fixed column count for the Home content mini-grids (each content column
    /// is only ~⅓ of the screen wide).
    private static let homePosterCols = 3

    private var focusColumns: [[HomeFocus]] {
        let libKeys: [HomeFocus] = [.search] + libraryEntries.map { .library($0.name) } + [.houseParty, .refresh, .settings]
        let recKeys: [HomeFocus] = recentItems.map { .recent($0.id) }
        let bcKeys: [HomeFocus] = bingeItems.map { .binge($0.id) } + continueItems.map { .continueWatching($0.vpath) }
        if viewPref.layout == .posters {
            // Libraries stays a single list column; the two content columns each
            // expand into a row-major 2-wide grid so Left/Right walks the grid.
            return [libKeys]
                + posterStridedColumns(recKeys, cols: Self.homePosterCols)
                + posterStridedColumns(bcKeys, cols: Self.homePosterCols)
        }
        return [libKeys, recKeys, bcKeys]
    }

    /// Two flexible columns for the Home content poster grids.
    private var homeGridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: Self.homePosterCols)
    }

    // MARK: actions

    private func handleActivate(_ key: HomeFocus) {
        switch key {
        case .library(let name):
            if let entry = libraryEntries.first(where: { $0.name == name }) {
                switch entry {
                case .dir(let n, _, _, _):           nav.push(.browse(path: n))
                case .file(let n, _, _, _, _):    nav.play(vpath: n)
                }
            }
        case .recent(let id):
            if let item = recentItems.first(where: { $0.id == id }) {
                switch item {
                case .dir(_, let vpath, _, _, _):    nav.push(.browse(path: vpath))
                case .file(_, let vpath, _, _, _):   nav.play(vpath: vpath)
                }
            }
        case .binge(let id):
            // Play the binge's next-up video, bound to the binge so finishing
            // it advances the queue. bingeId set ⇒ no interception.
            if let binge = binges.binge(id: id), let front = binge.front {
                nav.play(vpath: front, bingeId: binge.id)
            }
        case .continueWatching(let vpath):
            nav.play(vpath: vpath)
        case .houseParty:
            if houseParty.joined { houseParty.leave() } else { houseParty.join() }
        case .refresh:
            // Re-pull libraries + recent from the server. Drop every cached
            // poster image and bump the nonce so all art re-fetches from the
            // server (the nonce also changes each poster URL, so any cell still
            // showing stale/blank art reloads).
            PosterImageCache.shared.clear()
            refresh.bump()
            Task { await vm.reload() }
        case .settings:
            nav.push(.settings)
        case .search:
            nav.push(.search)
        }
    }

    private func handleLongSelect(_ key: HomeFocus) {
        NSLog("[Duplex/Home] longSelect key=%@", String(describing: key))
        switch key {
        case .continueWatching(let vpath):
            resume.remove(vpath)
            refocusAfterBingeChange()
        case .binge(let id):
            // Deleting a binge is deliberately gated behind a confirm.
            if let b = binges.binge(id: id) { dialog = .confirmDelete(b) }
        case .library(let name):
            // Long-press a whole library root to binge everything under it.
            guard let entry = libraryEntries.first(where: { $0.name == name }), entry.isDir else { return }
            startBinge(origin: name)
        case .recent(let id):
            // Recently Added folders are bingeable too, same as in Browse.
            guard let item = recentItems.first(where: { $0.id == id }), item.isDir else { return }
            startBinge(origin: item.vpath)
        default:
            break
        }
    }

    /// Flatten `origin` server-side and raise the create confirm.
    private func startBinge(origin: String) {
        Task {
            do {
                let resp = try await client.flatten(path: origin)
                if resp.vpaths.isEmpty {
                    dialog = .error("There are no videos in \(DuplexFormat.leaf(of: origin)).")
                } else {
                    dialog = .confirmCreate(PendingBinge(origin: origin, vpaths: resp.vpaths))
                }
            } catch {
                dialog = .error(error.localizedDescription)
            }
        }
    }

    /// Builds the one alert shown for any binge dialog state.
    private func bingeAlert(_ d: BingeDialog) -> Alert {
        switch d {
        case .confirmCreate(let p):
            return Alert(
                title: Text("Create a Binge?"),
                message: Text("\(p.origin)\n\(p.vpaths.count) total \(p.vpaths.count == 1 ? "video" : "videos")"),
                primaryButton: .default(Text("Binge")) {
                    BingeStore.shared.create(origin: p.origin, vpaths: p.vpaths)
                    refocusAfterBingeChange()
                },
                secondaryButton: .cancel()
            )
        case .confirmDelete(let b):
            return Alert(
                title: Text("Delete this binge?"),
                message: Text("\(b.origin)\n\(b.remaining) remaining. This can’t be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    BingeStore.shared.remove(id: b.id)
                    refocusAfterBingeChange()
                },
                secondaryButton: .cancel()
            )
        case .error(let msg):
            return Alert(
                title: Text("Couldn’t build binge"),
                message: Text(msg),
                dismissButton: .cancel(Text("OK"))
            )
        }
    }

    /// Land on something sensible after a binge or Continue row is removed:
    /// next binge, then Continue Watching, then Recently Added, then Libraries.
    private func refocusAfterBingeChange() {
        if let first = bingeItems.first {
            focus = .binge(first.id)
        } else if let first = resume.visible.first {
            focus = .continueWatching(first.vpath)
        } else if let first = recentItems.first {
            focus = .recent(first.id)
        } else if let first = libraryEntries.first {
            focus = .library(first.name)
        }
    }

    /// Prefer top of Binges; then Continue Watching; then Recently Added; then
    /// Libraries. Only fires once per appearance.
    private func applyInitialFocusIfNeeded() {
        guard !didSetInitialFocus else { return }
        if let first = bingeItems.first {
            focus = .binge(first.id)
            didSetInitialFocus = true
            return
        }
        if let first = continueItems.first {
            focus = .continueWatching(first.vpath)
            didSetInitialFocus = true
            return
        }
        if let first = recentItems.first {
            focus = .recent(first.id)
            didSetInitialFocus = true
            return
        }
        if let first = libraryEntries.first {
            focus = .library(first.name)
            didSetInitialFocus = true
        }
    }

    // MARK: column views

    private var librariesColumn: some View {
        Column(
            title: "Libraries",
            scrollAnchor: anchor(in: .libraries),
            scrollToTop: pinTop(in: .libraries)
        ) {
            searchRow
                .id(HomeFocus.search)
            Rectangle()
                .fill(DuplexColor.border)
                .frame(height: 1)
                .padding(.vertical, 6)
            switch vm.libraries {
            case .idle, .loading:
                LoadingColumn()
            case .failed(let m):
                ColumnError(message: m)
            case .loaded:
                let entries = libraryEntries
                if entries.isEmpty {
                    EmptyColumn(icon: "📭", title: "No libraries", hint: "Start the server with one or more --library paths.")
                } else {
                    ForEach(entries, id: \.id) { entry in
                        libraryRow(entry)
                            .id(HomeFocus.library(entry.name))
                    }
                }
                Rectangle()
                    .fill(DuplexColor.border)
                    .frame(height: 1)
                    .padding(.vertical, 6)
                housePartyRow
                    .id(HomeFocus.houseParty)
                refreshRow
                    .id(HomeFocus.refresh)
                settingsRow
                    .id(HomeFocus.settings)
            }
        }
    }

    private var housePartyRow: some View {
        GridEntryRow(
            icon: "🎉",
            title: houseParty.joined ? "Leave House Party" : "Join House Party",
            subtitle: nil,
            meta: housePartyStatus,
            isFocused: focus == .houseParty
        )
    }

    /// Live party status shown as the row's meta: "Idle" when nothing is
    /// playing, otherwise the leaf name of the current video. `nil` until the
    /// first poll lands (no meta column).
    private var housePartyStatus: String? {
        guard let s = houseParty.latest else { return nil }
        guard s.active, let vpath = s.vpath else { return "Idle" }
        return DuplexFormat.displayFileLeaf(of: vpath)
    }

    private var searchRow: some View {
        GridEntryRow(
            icon: "🔍",
            title: "Search",
            subtitle: nil,
            meta: nil,
            isFocused: focus == .search
        )
    }

    @ViewBuilder
    private func libraryRow(_ entry: Entry) -> some View {
        let key = HomeFocus.library(entry.name)
        switch entry {
        case .dir(let name, let children, _, _):
            GridEntryRow(
                icon: "📁",
                title: name,
                subtitle: nil,
                meta: "\(children) entries",
                isFocused: focus == key
            )
        case .file(let name, _, let size, _, _):
            GridEntryRow(
                icon: "🎬",
                title: DuplexFormat.displayFileName(name),
                subtitle: nil,
                meta: DuplexFormat.size(size),
                isFocused: focus == key
            )
        }
    }

    private var refreshRow: some View {
        GridEntryRow(
            icon: "🔄",
            title: "Refresh",
            subtitle: nil,
            meta: nil,
            isFocused: focus == .refresh
        )
    }

    private var settingsRow: some View {
        GridEntryRow(
            icon: "⚙",
            title: "Settings",
            subtitle: nil,
            meta: nil,
            isFocused: focus == .settings
        )
    }

    private var recentColumn: some View {
        Column(title: "Recently Added", scrollAnchor: anchor(in: .recent), scrollToTop: pinTop(in: .recent)) {
            switch vm.recent {
            case .idle, .loading:
                LoadingColumn()
            case .failed:
                EmptyColumn(icon: "💤", title: "Nothing new", hint: "")
            case .loaded:
                let items = recentItems
                if items.isEmpty {
                    EmptyColumn(icon: "💤", title: "Nothing new", hint: "")
                } else if viewPref.layout == .posters {
                    LazyVGrid(columns: homeGridItems, spacing: 18) {
                        ForEach(items, id: \.id) { item in
                            recentPosterCell(item)
                                .id(HomeFocus.recent(item.id))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                } else {
                    ForEach(items, id: \.id) { item in
                        recentRow(item)
                            .id(HomeFocus.recent(item.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentPosterCell(_ item: RecentItem) -> some View {
        let isFocused = focus == .recent(item.id)
        switch item {
        case .dir(let name, let vpath, _, _, let hasPoster):
            PosterCell(
                url: hasPoster ? client.posterURL(path: vpath, cacheBust: refresh.posterNonce) : nil,
                fallbackGlyph: "📁",
                title: name,
                isFocused: isFocused
            )
        case .file(let name, let vpath, _, _, let hasPoster):
            PosterCell(
                url: hasPoster ? client.posterURL(path: vpath, cacheBust: refresh.posterNonce) : nil,
                fallbackGlyph: "🎬",
                title: DuplexFormat.displayFileName(name),
                isFocused: isFocused
            )
        }
    }

    @ViewBuilder
    private func recentRow(_ item: RecentItem) -> some View {
        let parent = DuplexFormat.parent(of: item.vpath)
        let key = HomeFocus.recent(item.id)
        switch item {
        case .dir(let name, _, let mtime, let children, _):
            GridEntryRow(
                icon: "📁",
                title: name,
                subtitle: parent,
                meta: "\(children) · \(DuplexFormat.relative(mtime))",
                isFocused: focus == key
            )
        case .file(let name, _, let mtime, let size, _):
            GridEntryRow(
                icon: "🎬",
                title: DuplexFormat.displayFileName(name),
                subtitle: parent,
                meta: "\(DuplexFormat.size(size)) · \(DuplexFormat.relative(mtime))",
                isFocused: focus == key
            )
        }
    }

    /// The third column mixes binges and Continue Watching; title it for
    /// whatever it actually holds so it doesn't read "Binges" when there are
    /// none.
    private var continueColumnTitle: String {
        switch (bingeItems.isEmpty, continueItems.isEmpty) {
        case (false, false): return "Binges & Continue"
        case (false, true):  return "Binges"
        default:             return "Continue Watching"
        }
    }

    private var continueColumn: some View {
        Column(title: continueColumnTitle, scrollAnchor: anchor(in: .bingeContinue), scrollToTop: pinTop(in: .bingeContinue)) {
            if viewPref.layout == .posters {
                bingeContinuePosterGrid
            } else {
                bingeSection
                Rectangle()
                    .fill(DuplexColor.border)
                    .frame(height: 1)
                    .padding(.vertical, 6)
                // Sub-header only when binges sit above it; otherwise the column
                // title already reads "Continue Watching" and a matching
                // sub-header would just double the label.
                if !bingeItems.isEmpty {
                    sectionHeader("Continue Watching")
                }
                continueSection
            }
        }
    }

    @ViewBuilder
    private var bingeContinuePosterGrid: some View {
        let binges = bingeItems
        let cont = continueItems
        if binges.isEmpty && cont.isEmpty {
            EmptyColumn(icon: "🍿", title: "Nothing here yet", hint: "Hold ✓ on a folder to binge it.")
        } else {
            LazyVGrid(columns: homeGridItems, spacing: 18) {
                ForEach(binges) { binge in
                    let isFocused = focus == .binge(binge.id)
                    let front = binge.front ?? ""
                    PosterCell(
                        url: front.isEmpty ? nil : client.posterURL(path: front, cacheBust: refresh.posterNonce),
                        fallbackGlyph: "🍿",
                        title: binge.origin,
                        subtitle: "\(binge.remaining) left",
                        isFocused: isFocused
                    )
                    .id(HomeFocus.binge(binge.id))
                }
                ForEach(cont, id: \.vpath) { item in
                    let isFocused = focus == .continueWatching(item.vpath)
                    let progress = item.entry.dur > 0 ? item.entry.pos / item.entry.dur : 0
                    PosterCell(
                        url: client.posterURL(path: item.vpath, cacheBust: refresh.posterNonce),
                        fallbackGlyph: "🎬",
                        title: DuplexFormat.displayFileLeaf(of: item.vpath),
                        progress: progress,
                        isFocused: isFocused
                    )
                    .id(HomeFocus.continueWatching(item.vpath))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var bingeSection: some View {
        let items = bingeItems
        if items.isEmpty {
            EmptyColumn(icon: "🍿", title: "No binges yet", hint: "Hold ✓ on a folder to binge everything in it.")
        } else {
            ForEach(items) { binge in
                let key = HomeFocus.binge(binge.id)
                GridBingeRow(
                    origin: binge.origin,
                    nextLeaf: DuplexFormat.displayFileLeaf(of: binge.front ?? ""),
                    remaining: binge.remaining,
                    isFocused: focus == key
                )
                .id(key)
            }
        }
    }

    @ViewBuilder
    private var continueSection: some View {
        let items = continueItems
        if items.isEmpty {
            EmptyColumn(icon: "🎬", title: "Nothing in progress", hint: "Start watching something and it'll show up here.")
        } else {
            ForEach(items, id: \.vpath) { item in
                let progress = item.entry.dur > 0 ? item.entry.pos / item.entry.dur : 0
                let key = HomeFocus.continueWatching(item.vpath)
                GridContinueRow(
                    title: DuplexFormat.displayFileLeaf(of: item.vpath),
                    subtitle: DuplexFormat.parent(of: item.vpath),
                    progress: progress,
                    isFocused: focus == key
                )
                .id(key)
            }
        }
    }

    /// An inline muted section label, matching the column header treatment, for
    /// sub-sections that live under a single column title.
    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(DuplexColor.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Context hint keyed off what's focused, so the long-press affordance is
    /// always discoverable for the current row.
    private var holdHint: String? {
        switch focus {
        case .binge:            return "Hold ✓ to delete this binge"
        case .continueWatching: return "Hold ✓ to forget"
        case .library(let name):
            let isDir = libraryEntries.first(where: { $0.name == name })?.isDir ?? false
            return isDir ? "Hold ✓ to binge this library" : nil
        case .recent(let id):
            let isDir = recentItems.first(where: { $0.id == id })?.isDir ?? false
            return isDir ? "Hold ✓ to binge this folder" : nil
        default:                return nil
        }
    }

    private var footerHint: some View {
        HStack(spacing: 18) {
            Spacer()
            Text("▶︎❙❙  View: \(viewPref.label)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DuplexColor.muted)
            if let hint = holdHint {
                Text("•")
                    .foregroundStyle(DuplexColor.muted)
                Text(hint)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DuplexColor.muted)
            }
            Spacer()
        }
        // Constant height: the panels' ScrollViews fill the space between
        // header and footer, so a reflowing footer would resize all three.
        // Reserve the line whether or not a hold-hint is showing.
        .frame(height: 24)
        .padding(.bottom, 14)
    }

    /// Grid-aware Down within the poster mini-grids: dropping off the bottom of
    /// a short column lands on the last item (down-and-left) rather than
    /// wrapping. Each content grid is handled independently; Libraries (a list)
    /// and all other directions keep WrapColumns' defaults.
    private func posterCrossNavigate(_ cur: HomeFocus, _ dir: WrapColumnsCrossDirection) -> HomeFocus? {
        guard viewPref.layout == .posters, dir == .down || dir == .up else { return nil }
        let cols = Self.homePosterCols
        let keys: [HomeFocus]
        switch cur {
        case .recent:
            keys = recentItems.map { HomeFocus.recent($0.id) }
        case .binge, .continueWatching:
            keys = bingeItems.map { HomeFocus.binge($0.id) }
                + continueItems.map { HomeFocus.continueWatching($0.vpath) }
        default:
            return nil // Libraries (a list) keeps WrapColumns' defaults.
        }
        return dir == .down
            ? posterGridDownTarget(keys, from: cur, cols: cols)
            : posterGridUpTarget(keys, from: cur, cols: cols)
    }

    /// The three visual columns, identified by which focus keys belong to them.
    /// Membership is layout-independent, so this drives each `Column`'s scroll
    /// anchor whether the content columns are lists or poster mini-grids.
    private enum HomeColumn { case libraries, recent, bingeContinue }

    private func belongs(_ f: HomeFocus, to col: HomeColumn) -> Bool {
        switch col {
        case .libraries:
            switch f {
            case .search, .library, .houseParty, .refresh, .settings: return true
            default: return false
            }
        case .recent:
            if case .recent = f { return true }
            return false
        case .bingeContinue:
            switch f {
            case .binge, .continueWatching: return true
            default: return false
            }
        }
    }

    /// Returns the focused key if it lives in `col`, so that column's
    /// ScrollViewReader keeps it in view.
    private func anchor(in col: HomeColumn) -> AnyHashable? {
        guard let f = focus, belongs(f, to: col) else { return nil }
        return AnyHashable(f)
    }

    /// True when the focused item sits in `col`'s first row, so the column
    /// should scroll fully to the top rather than doing a minimal reveal.
    private func pinTop(in col: HomeColumn) -> Bool {
        guard let f = focus, belongs(f, to: col) else { return false }
        let cols = viewPref.layout == .posters ? Self.homePosterCols : 1
        switch col {
        case .libraries:
            return f == .search
        case .recent:
            guard case .recent(let id) = f,
                  let idx = recentItems.firstIndex(where: { $0.id == id }) else { return false }
            return idx < cols
        case .bingeContinue:
            let keys = bingeItems.map { HomeFocus.binge($0.id) }
                + continueItems.map { HomeFocus.continueWatching($0.vpath) }
            guard let idx = keys.firstIndex(of: f) else { return false }
            return idx < cols
        }
    }
}
