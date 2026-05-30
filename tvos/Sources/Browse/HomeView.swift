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
        async let libsTask: Void = loadLibraries()
        async let recentTask: Void = loadRecent()
        _ = await (libsTask, recentTask)
    }

    private func loadLibraries() async {
        // Skip on pop-back to Home — see BrowseViewModel.load for rationale.
        if case .loaded = libraries { return }
        libraries = .loading
        do {
            let resp = try await client.browse(path: "")
            libraries = .loaded(resp.entries)
        } catch {
            libraries = .failed(error.localizedDescription)
        }
    }

    private func loadRecent() async {
        if case .loaded = recent { return }
        recent = .loading
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
    case settings
}

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @EnvironmentObject private var nav: NavCoordinator
    @ObservedObject private var resume = ResumeStore.shared
    @ObservedObject private var binges = BingeStore.shared
    @ObservedObject private var sort = SortPreference.shared
    @ObservedObject private var houseParty = HousePartyStore.shared
    @ObservedObject private var ext = ExtensionPreference.shared

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
                onPlayPause: { sort.toggle() }
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
    private var focusColumns: [[HomeFocus]] {
        let libKeys: [HomeFocus] = [.search] + libraryEntries.map { .library($0.name) } + [.houseParty, .settings]
        let recKeys: [HomeFocus] = recentItems.map { .recent($0.id) }
        let bingeKeys: [HomeFocus] = bingeItems.map { .binge($0.id) }
        let conKeys: [HomeFocus] = continueItems.map { .continueWatching($0.vpath) }
        return [libKeys, recKeys, bingeKeys + conKeys]
    }

    // MARK: actions

    private func handleActivate(_ key: HomeFocus) {
        switch key {
        case .library(let name):
            if let entry = libraryEntries.first(where: { $0.name == name }) {
                switch entry {
                case .dir(let n, _, _):           nav.push(.browse(path: n))
                case .file(let n, _, _, _):    nav.play(vpath: n)
                }
            }
        case .recent(let id):
            if let item = recentItems.first(where: { $0.id == id }) {
                switch item {
                case .dir(_, let vpath, _, _):    nav.push(.browse(path: vpath))
                case .file(_, let vpath, _, _):   nav.play(vpath: vpath)
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
            scrollAnchor: anchorFor(columnIndex: 0)
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
        case .dir(let name, let children, _):
            GridEntryRow(
                icon: "📁",
                title: name,
                subtitle: nil,
                meta: "\(children) entries",
                isFocused: focus == key
            )
        case .file(let name, _, let size, _):
            GridEntryRow(
                icon: "🎬",
                title: DuplexFormat.displayFileName(name),
                subtitle: nil,
                meta: DuplexFormat.size(size),
                isFocused: focus == key
            )
        }
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
        Column(title: "Recently Added", scrollAnchor: anchorFor(columnIndex: 1)) {
            switch vm.recent {
            case .idle, .loading:
                LoadingColumn()
            case .failed:
                EmptyColumn(icon: "💤", title: "Nothing new", hint: "")
            case .loaded:
                let items = recentItems
                if items.isEmpty {
                    EmptyColumn(icon: "💤", title: "Nothing new", hint: "")
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
    private func recentRow(_ item: RecentItem) -> some View {
        let parent = DuplexFormat.parent(of: item.vpath)
        let key = HomeFocus.recent(item.id)
        switch item {
        case .dir(let name, _, let mtime, let children):
            GridEntryRow(
                icon: "📁",
                title: name,
                subtitle: parent,
                meta: "\(children) · \(DuplexFormat.relative(mtime))",
                isFocused: focus == key
            )
        case .file(let name, _, let mtime, let size):
            GridEntryRow(
                icon: "🎬",
                title: DuplexFormat.displayFileName(name),
                subtitle: parent,
                meta: "\(DuplexFormat.size(size)) · \(DuplexFormat.relative(mtime))",
                isFocused: focus == key
            )
        }
    }

    private var continueColumn: some View {
        Column(title: "Binges", scrollAnchor: anchorFor(columnIndex: 2)) {
            bingeSection
            Rectangle()
                .fill(DuplexColor.border)
                .frame(height: 1)
                .padding(.vertical, 6)
            sectionHeader("Continue Watching")
            continueSection
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
            Text("▶︎❙❙  Sort: \(sort.mode.label)")
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

    /// Returns the focus key if it's in the given column — used to drive each
    /// `Column`'s ScrollViewReader so the focused row stays in view.
    private func anchorFor(columnIndex: Int) -> AnyHashable? {
        guard let f = focus else { return nil }
        let cols = focusColumns
        guard columnIndex >= 0 && columnIndex < cols.count else { return nil }
        return cols[columnIndex].contains(f) ? AnyHashable(f) : nil
    }

    private func sortEntries(_ entries: [Entry]) -> [Entry] {
        switch sort.mode {
        case .name:
            return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return entries.sorted { $0.mtime > $1.mtime }
        }
    }
}
