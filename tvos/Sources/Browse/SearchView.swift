import SwiftUI

/// Process-lifetime singleton so re-entering the Search route in the same
/// session restores the previous query and result list verbatim. We don't
/// persist anything to disk — search state is intentionally ephemeral.
@MainActor
final class SearchSession: ObservableObject {
    static let shared = SearchSession()

    enum State {
        case idle, loading
        case loaded
        case failed(String)
    }

    @Published var query: String = ""
    @Published var state: State = .idle
    @Published var results: [SearchItem] = []

    private let client = DuplexClient()
    private var lastQuery: String = ""
    private var inflight: Task<Void, Never>?

    func search(query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q != lastQuery else { return }
        lastQuery = q
        inflight?.cancel()
        if q.isEmpty {
            results = []
            state = .idle
            return
        }
        state = .loading
        inflight = Task {
            do {
                let resp = try await client.search(query: q)
                if Task.isCancelled { return }
                self.results = resp.items
                self.state = .loaded
            } catch {
                if Task.isCancelled { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Search has two focus targets: the single search card on the left, and any
/// result row on the right. WrapColumns sees these as two columns, so up/down
/// stays inside whichever column the user is in and left/right switches
/// between them.
enum SearchFocus: Hashable {
    case input
    case result(String)
}

struct SearchView: View {
    @EnvironmentObject private var nav: NavCoordinator
    @ObservedObject private var session = SearchSession.shared
    @ObservedObject private var ext = ExtensionPreference.shared
    @State private var focusedKey: SearchFocus? = .input
    @State private var inputOpen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            WrapColumns(
                columns: focusColumns,
                current: $focusedKey,
                onActivate: handleActivate,
                onMenuTap: { nav.path.removeLast() }
            ) {
                HStack(alignment: .top, spacing: 24) {
                    searchCard
                        .frame(maxWidth: .infinity)
                    resultsColumn
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
            footerHint
        }
        .background(DuplexColor.bg.ignoresSafeArea())
        .ignoresSafeArea()
        .navigationBarHidden(true)
        .onAppear { session.search(query: session.query) }
        .fullScreenCover(isPresented: $inputOpen) {
            SearchInputCover(query: $session.query) {
                session.search(query: session.query)
                inputOpen = false
            }
        }
    }

    private var focusColumns: [[SearchFocus]] {
        let resultKeys: [SearchFocus] = session.results.map { .result($0.vpath) }
        return [[.input], resultKeys]
    }

    // MARK: - layout

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            DuplexLogo(size: 40)
            Text("Search")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(DuplexColor.fg)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var searchCard: some View {
        let isFocused = focusedKey == .input
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Text("🔍").font(.system(size: 32))
                Text("Search")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DuplexColor.muted)
                Spacer(minLength: 0)
            }
            Text(session.query.isEmpty ? "Title, folder, episode…" : session.query)
                .font(.system(size: 28, weight: session.query.isEmpty ? .regular : .medium))
                .foregroundStyle(session.query.isEmpty ? DuplexColor.muted : DuplexColor.fg)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text("Press ✓ to type")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DuplexColor.muted)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        // Outline-only focus indicator — no fill swap so the text stays
        // legible (white on dark) in either state.
        .overlay(
            RoundedRectangle(cornerRadius: DuplexMetric.panelRadius)
                .stroke(isFocused ? DuplexColor.accent : DuplexColor.border,
                        lineWidth: isFocused ? 3 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    @ViewBuilder
    private var resultsColumn: some View {
        switch session.state {
        case .idle:
            placeholder(icon: "🔎", title: "Search your libraries",
                        hint: "Type a title, folder, or episode name.")
        case .loading:
            LoadingColumn()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DuplexColor.panel)
                .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        case .failed(let m):
            ColumnError(message: m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DuplexColor.panel)
                .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        case .loaded:
            if session.results.isEmpty {
                placeholder(icon: "🤷", title: "No results",
                            hint: "Try a different query.")
            } else {
                resultsList
            }
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            Rectangle().fill(DuplexColor.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.results, id: \.vpath) { item in
                            row(for: item)
                                .id(SearchFocus.result(item.vpath))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: focusedKey) { _, new in
                    guard let new, case .result = new else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
    }

    @ViewBuilder
    private func row(for item: SearchItem) -> some View {
        let parent = DuplexFormat.parent(of: item.vpath)
        let isFocused = focusedKey == .result(item.vpath)
        switch item {
        case .dir(let name, _, let mtime, let children):
            GridEntryRow(
                icon: "📁",
                title: name,
                subtitle: parent.isEmpty ? nil : parent,
                meta: "\(children) · \(DuplexFormat.relative(mtime))",
                isFocused: isFocused
            )
        case .file(let name, _, let mtime, let size):
            GridEntryRow(
                icon: "🎬",
                title: DuplexFormat.displayFileName(name),
                subtitle: parent.isEmpty ? nil : parent,
                meta: "\(DuplexFormat.size(size)) · \(DuplexFormat.relative(mtime))",
                isFocused: isFocused
            )
        }
    }

    private func placeholder(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(icon).font(.system(size: 48))
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DuplexColor.fg)
            Text(hint)
                .font(.system(size: 16))
                .foregroundStyle(DuplexColor.muted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
    }

    private var footerHint: some View {
        HStack {
            Spacer()
            Text("◀︎▶︎ to switch columns")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DuplexColor.muted)
            Spacer()
        }
        .padding(.bottom, 14)
    }

    // MARK: - actions

    private func handleActivate(_ key: SearchFocus) {
        switch key {
        case .input:
            inputOpen = true
        case .result(let vpath):
            guard let item = session.results.first(where: { $0.vpath == vpath }) else { return }
            switch item {
            case .dir:  nav.push(.browse(path: vpath))
            case .file: nav.play(vpath: vpath)
            }
        }
    }
}

/// Full-screen text-entry surface. Auto-focuses a giant TextField on appear so
/// tvOS shows its OSK without the user needing to press Select again. Pressing
/// the Done key on the keyboard, or Menu/Back, dismisses.
private struct SearchInputCover: View {
    @Binding var query: String
    var onSubmit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("Search")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(DuplexColor.fg)
            TextField("Title, folder, episode…", text: $query)
                .font(.system(size: 36))
                .focused($fieldFocused)
                .onSubmit { onSubmit() }
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .background(DuplexColor.panel)
                .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
                .frame(maxWidth: 1000)
            Text("◀︎ to cancel")
                .font(.system(size: 16))
                .foregroundStyle(DuplexColor.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DuplexColor.bg.ignoresSafeArea())
        .onAppear { fieldFocused = true }
        .onExitCommand { dismiss() }
    }
}
