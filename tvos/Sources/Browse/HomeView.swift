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

/// Identifies a focusable row on the home screen. Three columns, three cases.
enum HomeFocus: Hashable {
    case library(String)
    case recent(String)
    case continueWatching(String)
}

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @EnvironmentObject private var nav: NavCoordinator
    @ObservedObject private var resume = ResumeStore.shared
    @ObservedObject private var sort = SortPreference.shared

    @FocusState private var focus: HomeFocus?
    @State private var didSetInitialFocus = false

    var body: some View {
        VStack(spacing: 0) {
            BrowseHeader(crumbPath: nil, showSort: true, sort: sort)
            HStack(alignment: .top, spacing: DuplexMetric.columnGap) {
                librariesColumn
                recentColumn
                continueColumn
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .background(DuplexColor.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            await vm.load()
            applyInitialFocusIfNeeded()
        }
        .onAppear { applyInitialFocusIfNeeded() }
    }

    /// Prefer top of Continue Watching; fall back to Recently Added; fall back
    /// to Libraries. Only fires once per appearance — subsequent re-renders
    /// don't yank focus away from wherever the user has navigated.
    private func applyInitialFocusIfNeeded() {
        guard !didSetInitialFocus else { return }
        if let firstResume = resume.visible.first {
            focus = .continueWatching(firstResume.vpath)
            didSetInitialFocus = true
            return
        }
        if case .loaded(let items) = vm.recent, let first = items.first {
            focus = .recent(first.id)
            didSetInitialFocus = true
            return
        }
        if case .loaded(let entries) = vm.libraries {
            let sorted = sortEntries(entries)
            if let first = sorted.first {
                focus = .library(first.name)
                didSetInitialFocus = true
            }
        }
    }

    private var librariesColumn: some View {
        Column(title: "Libraries") {
            switch vm.libraries {
            case .idle, .loading:
                LoadingColumn()
            case .failed(let m):
                ColumnError(message: m)
            case .loaded(let entries):
                let sorted = sortEntries(entries)
                if sorted.isEmpty {
                    EmptyColumn(icon: "📭", title: "No libraries", hint: "Start the server with one or more --library paths.")
                } else {
                    ForEach(sorted, id: \.id) { entry in
                        switch entry {
                        case .dir(let name, let children, _):
                            EntryRow(
                                icon: "📁",
                                title: name,
                                subtitle: nil,
                                meta: "\(children) entries"
                            ) {
                                nav.push(.browse(path: name))
                            }
                            .focused($focus, equals: .library(name))
                        case .file(let name, _, let size, _, _):
                            EntryRow(
                                icon: "🎬",
                                title: name,
                                subtitle: nil,
                                meta: DuplexFormat.size(size)
                            ) {
                                nav.push(.player(vpath: name))
                            }
                            .focused($focus, equals: .library(name))
                        }
                    }
                }
            }
        }
    }

    private var recentColumn: some View {
        Column(title: "Recently Added") {
            switch vm.recent {
            case .idle, .loading:
                LoadingColumn()
            case .failed:
                EmptyColumn(icon: "💤", title: "Nothing new", hint: "")
            case .loaded(let items):
                if items.isEmpty {
                    EmptyColumn(icon: "💤", title: "Nothing new", hint: "")
                } else {
                    ForEach(items, id: \.id) { item in
                        let parent = DuplexFormat.parent(of: item.vpath)
                        switch item {
                        case .dir(let name, let vpath, let mtime, let children):
                            EntryRow(
                                icon: "📁",
                                title: name,
                                subtitle: parent,
                                meta: "\(children) · \(DuplexFormat.relative(mtime))"
                            ) {
                                nav.push(.browse(path: vpath))
                            }
                            .focused($focus, equals: .recent(vpath))
                        case .file(let name, let vpath, let mtime, let size):
                            EntryRow(
                                icon: "🎬",
                                title: name,
                                subtitle: parent,
                                meta: "\(DuplexFormat.size(size)) · \(DuplexFormat.relative(mtime))"
                            ) {
                                nav.push(.player(vpath: vpath))
                            }
                            .focused($focus, equals: .recent(vpath))
                        }
                    }
                }
            }
        }
    }

    private var continueColumn: some View {
        Column(title: "Continue Watching") {
            let entries = resume.visible
            if entries.isEmpty {
                EmptyColumn(icon: "🍿", title: "Nothing in progress", hint: "Start watching something and it'll show up here.")
            } else {
                ForEach(entries, id: \.vpath) { item in
                    let progress = item.entry.dur > 0 ? item.entry.pos / item.entry.dur : 0
                    ContinueRow(
                        icon: "🎬",
                        title: DuplexFormat.leaf(of: item.vpath),
                        subtitle: DuplexFormat.parent(of: item.vpath),
                        progress: progress,
                        onSelect: { nav.push(.player(vpath: item.vpath)) },
                        onRemove: { resume.remove(item.vpath) }
                    )
                    .focused($focus, equals: .continueWatching(item.vpath))
                }
            }
        }
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
