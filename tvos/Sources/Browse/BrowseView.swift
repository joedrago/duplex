import SwiftUI

@MainActor
final class BrowseViewModel: ObservableObject {
    enum State {
        case idle, loading
        case loaded([Entry])
        case failed(String)
    }

    @Published var state: State = .idle
    private let client = DuplexClient()

    func load(path: String) async {
        // Pop-back re-fires `.task`, which would otherwise reset our state to
        // .loading and momentarily empty the list — that briefly empties the
        // WrapColumns columns, which clears the focused row, which then resnaps
        // to the top of the list after data lands. Skip if we already have it.
        if case .loaded = state { return }
        state = .loading
        do {
            let resp = try await client.browse(path: path)
            state = .loaded(resp.entries)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct BrowseView: View {
    let dirPath: String

    @StateObject private var vm = BrowseViewModel()
    @ObservedObject private var sort = SortPreference.shared
    @ObservedObject private var lastSel = LastSelectionStore.shared
    @EnvironmentObject private var nav: NavCoordinator
    @State private var focusedName: String?
    @State private var didApplyInitialFocus = false

    var body: some View {
        VStack(spacing: 0) {
            BrowseHeader(crumbPath: dirPath)
            WrapColumns(
                columns: [sortedEntryNames],
                current: $focusedName,
                onActivate: handleActivate,
                onPlayPause: { sort.toggle() },
                onMenuTap: { nav.path.removeLast() }
            ) {
                content
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
            }
            footerHint
        }
        .background(DuplexColor.bg.ignoresSafeArea())
        .ignoresSafeArea()
        .navigationBarHidden(true)
        .task {
            await vm.load(path: dirPath)
            applyInitialFocusIfNeeded()
        }
        .onAppear {
            // Fires on every pop-back from a child route. Re-apply lastSel so
            // the row the user activated stays highlighted when they return.
            // (On the very first load this fires before data lands, so it
            // no-ops and the .task → applyInitialFocusIfNeeded path handles it.)
            if let remembered = lastSel.get(dir: dirPath),
               sortedEntryNames.contains(remembered) {
                focusedName = remembered
            }
        }
        .onChange(of: sortedEntryNames) { _, _ in applyInitialFocusIfNeeded() }
        .onChange(of: sort.mode) { _, _ in
            // Sort toggle reshuffles the list — snap focus to the top of the
            // new ordering rather than leaving the user mid-list at a row
            // whose neighbors have changed underneath them.
            if let first = sortedEntryNames.first {
                focusedName = first
            }
        }
    }

    private var sortedEntries: [Entry] {
        if case .loaded(let entries) = vm.state { return sortedEntriesList(entries) }
        return []
    }

    private var sortedEntryNames: [String] { sortedEntries.map(\.name) }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle, .loading:
            LoadingColumn().frame(maxHeight: .infinity)
        case .failed(let m):
            ColumnError(message: m).frame(maxHeight: .infinity)
        case .loaded:
            list(entries: sortedEntries)
        }
    }

    private func list(entries: [Entry]) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(DuplexColor.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if entries.isEmpty {
                            EmptyColumn(icon: "📭", title: "Empty", hint: "Nothing in this folder.")
                        } else {
                            ForEach(entries, id: \.id) { entry in
                                row(for: entry)
                                    .id(entry.name)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: focusedName) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        let isFocused = focusedName == entry.name
        switch entry {
        case .dir(let name, let children, let mtime):
            GridEntryRow(
                icon: "📁",
                title: name,
                subtitle: nil,
                meta: sort.mode == .recent
                    ? "\(children) · \(DuplexFormat.relative(mtime))"
                    : "\(children) entries",
                isFocused: isFocused
            )
        case .file(let name, _, let size, let mtime, _):
            GridEntryRow(
                icon: "🎬",
                title: name,
                subtitle: nil,
                meta: sort.mode == .recent
                    ? "\(DuplexFormat.size(size)) · \(DuplexFormat.relative(mtime))"
                    : DuplexFormat.size(size),
                isFocused: isFocused
            )
        }
    }

    private func handleActivate(_ name: String) {
        guard let entry = sortedEntries.first(where: { $0.name == name }) else { return }
        lastSel.set(dir: dirPath, child: name)
        switch entry {
        case .dir:  nav.push(.browse(path: subpath(name)))
        case .file: nav.push(.player(vpath: subpath(name)))
        }
    }

    private func applyInitialFocusIfNeeded() {
        let names = sortedEntryNames
        guard !names.isEmpty else { return }
        if didApplyInitialFocus { return }
        if let remembered = lastSel.get(dir: dirPath), names.contains(remembered) {
            focusedName = remembered
        } else {
            focusedName = names.first
        }
        didApplyInitialFocus = true
    }

    private var footerHint: some View {
        HStack {
            Spacer()
            Text("▶︎❙❙  Sort: \(sort.mode.label)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DuplexColor.muted)
            Spacer()
        }
        .padding(.bottom, 14)
    }

    private func subpath(_ name: String) -> String {
        dirPath.isEmpty ? name : "\(dirPath)/\(name)"
    }

    private func sortedEntriesList(_ entries: [Entry]) -> [Entry] {
        switch sort.mode {
        case .name:
            return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return entries.sorted { $0.mtime > $1.mtime }
        }
    }
}
