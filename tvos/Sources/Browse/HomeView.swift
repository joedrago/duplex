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
        libraries = .loading
        do {
            let resp = try await client.browse(path: "")
            libraries = .loaded(resp.entries)
        } catch {
            libraries = .failed(error.localizedDescription)
        }
    }

    private func loadRecent() async {
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
    case library(String)
    case recent(String)
    case continueWatching(String)
    case settings
}

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @EnvironmentObject private var nav: NavCoordinator
    @ObservedObject private var resume = ResumeStore.shared
    @ObservedObject private var sort = SortPreference.shared

    @State private var focus: HomeFocus?
    @State private var didSetInitialFocus = false

    var body: some View {
        VStack(spacing: 0) {
            BrowseHeader(crumbPath: nil)
            WrapColumns(
                columns: focusColumns,
                current: $focus,
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
        .navigationBarHidden(true)
        .task {
            await vm.load()
            applyInitialFocusIfNeeded()
        }
        .onAppear { applyInitialFocusIfNeeded() }
    }

    // MARK: focus topology

    private var sortedLibraries: [Entry] {
        if case .loaded(let entries) = vm.libraries { return sortEntries(entries) }
        return []
    }

    private var recentItems: [RecentItem] {
        if case .loaded(let items) = vm.recent { return items }
        return []
    }

    private var continueItems: [(vpath: String, entry: ResumeEntry)] {
        resume.visible
    }

    /// Drives `WrapColumns`. Order here matches the visual HStack so left/right
    /// arrows cross between adjacent columns naturally.
    private var focusColumns: [[HomeFocus]] {
        let libKeys: [HomeFocus] = sortedLibraries.map { .library($0.name) } + [.settings]
        let recKeys: [HomeFocus] = recentItems.map { .recent($0.id) }
        let conKeys: [HomeFocus] = continueItems.map { .continueWatching($0.vpath) }
        return [libKeys, recKeys, conKeys]
    }

    // MARK: actions

    private func handleActivate(_ key: HomeFocus) {
        switch key {
        case .library(let name):
            if let entry = sortedLibraries.first(where: { $0.name == name }) {
                switch entry {
                case .dir(let n, _, _):           nav.push(.browse(path: n))
                case .file(let n, _, _, _, _):    nav.push(.player(vpath: n))
                }
            }
        case .recent(let id):
            if let item = recentItems.first(where: { $0.id == id }) {
                switch item {
                case .dir(_, let vpath, _, _):    nav.push(.browse(path: vpath))
                case .file(_, let vpath, _, _):   nav.push(.player(vpath: vpath))
                }
            }
        case .continueWatching(let vpath):
            nav.push(.player(vpath: vpath))
        case .settings:
            nav.push(.settings)
        }
    }

    private func handleLongSelect(_ key: HomeFocus) {
        guard case .continueWatching(let vpath) = key else { return }
        resume.remove(vpath)
        // Re-land on something sensible: prefer the next Continue Watching
        // entry, then top of Recently Added, then Libraries. Same precedence
        // as the initial focus on first load.
        if let first = resume.visible.first {
            focus = .continueWatching(first.vpath)
        } else if let first = recentItems.first {
            focus = .recent(first.id)
        } else if let first = sortedLibraries.first {
            focus = .library(first.name)
        }
    }

    /// Prefer top of Continue Watching; fall back to Recently Added; fall back
    /// to Libraries. Only fires once per appearance.
    private func applyInitialFocusIfNeeded() {
        guard !didSetInitialFocus else { return }
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
        if let first = sortedLibraries.first {
            focus = .library(first.name)
            didSetInitialFocus = true
        }
    }

    // MARK: column views

    private var librariesColumn: some View {
        Column(
            title: "Libraries",
            badge: sort.mode.label,
            scrollAnchor: anchorFor(columnIndex: 0)
        ) {
            switch vm.libraries {
            case .idle, .loading:
                LoadingColumn()
            case .failed(let m):
                ColumnError(message: m)
            case .loaded:
                let entries = sortedLibraries
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
                settingsRow
                    .id(HomeFocus.settings)
            }
        }
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
        case .file(let name, _, let size, _, _):
            GridEntryRow(
                icon: "🎬",
                title: name,
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
                title: name,
                subtitle: parent,
                meta: "\(DuplexFormat.size(size)) · \(DuplexFormat.relative(mtime))",
                isFocused: focus == key
            )
        }
    }

    private var continueColumn: some View {
        Column(title: "Continue Watching", scrollAnchor: anchorFor(columnIndex: 2)) {
            let items = continueItems
            if items.isEmpty {
                EmptyColumn(icon: "🍿", title: "Nothing in progress", hint: "Start watching something and it'll show up here.")
            } else {
                ForEach(items, id: \.vpath) { item in
                    let progress = item.entry.dur > 0 ? item.entry.pos / item.entry.dur : 0
                    let key = HomeFocus.continueWatching(item.vpath)
                    GridContinueRow(
                        title: DuplexFormat.leaf(of: item.vpath),
                        subtitle: DuplexFormat.parent(of: item.vpath),
                        progress: progress,
                        isFocused: focus == key
                    )
                    .id(key)
                }
            }
        }
    }

    private var footerHint: some View {
        HStack(spacing: 18) {
            Spacer()
            Text("▶︎❙❙  Sort: \(sort.mode.label)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DuplexColor.muted)
            Text("•")
                .foregroundStyle(DuplexColor.muted)
            Text("Hold ✓ on a Continue row to forget")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DuplexColor.muted)
            Spacer()
        }
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
