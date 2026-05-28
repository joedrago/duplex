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
    @FocusState private var focusedName: String?

    var body: some View {
        VStack(spacing: 0) {
            BrowseHeader(crumbPath: dirPath, showSort: true, sort: sort)
            content
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
        }
        .background(DuplexColor.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task { await vm.load(path: dirPath) }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle, .loading:
            LoadingColumn().frame(maxHeight: .infinity)
        case .failed(let m):
            ColumnError(message: m).frame(maxHeight: .infinity)
        case .loaded(let entries):
            list(entries: sortedEntries(entries))
        }
    }

    private func list(entries: [Entry]) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(DuplexColor.border).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if entries.isEmpty {
                        EmptyColumn(icon: "📭", title: "Empty", hint: "Nothing in this folder.")
                    } else {
                        ForEach(entries, id: \.id) { entry in
                            row(for: entry)
                                .focused($focusedName, equals: entry.name)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        .onAppear {
            if let remembered = lastSel.get(dir: dirPath),
               entries.contains(where: { $0.name == remembered }) {
                focusedName = remembered
            } else {
                focusedName = entries.first?.name
            }
        }
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        switch entry {
        case .dir(let name, let children, let mtime):
            EntryRow(
                icon: "📁",
                title: name,
                subtitle: nil,
                meta: sort.mode == .recent
                    ? "\(children) · \(DuplexFormat.relative(mtime))"
                    : "\(children) entries"
            ) {
                lastSel.set(dir: dirPath, child: name)
                nav.push(.browse(path: subpath(name)))
            }
        case .file(let name, _, let size, let mtime, _):
            EntryRow(
                icon: "🎬",
                title: name,
                subtitle: nil,
                meta: sort.mode == .recent
                    ? "\(DuplexFormat.size(size)) · \(DuplexFormat.relative(mtime))"
                    : DuplexFormat.size(size)
            ) {
                lastSel.set(dir: dirPath, child: name)
                nav.push(.player(vpath: subpath(name)))
            }
        }
    }

    private func subpath(_ name: String) -> String {
        dirPath.isEmpty ? name : "\(dirPath)/\(name)"
    }

    private func sortedEntries(_ entries: [Entry]) -> [Entry] {
        switch sort.mode {
        case .name:
            return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return entries.sorted { $0.mtime > $1.mtime }
        }
    }
}
