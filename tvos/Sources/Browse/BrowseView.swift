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

/// The two kinds of things that can be focused in BrowseView: an entry row in
/// the main list, or a letter on the alphabet rail. Modeled as a single enum
/// so we can hand both columns to `WrapColumns` and let its left/right wrap
/// navigation jump between the list and the rail.
enum BrowseFocus: Hashable {
    case entry(String)
    case letter(String)
}

struct BrowseView: View {
    let dirPath: String

    @StateObject private var vm = BrowseViewModel()
    @ObservedObject private var sort = SortPreference.shared
    @ObservedObject private var lastSel = LastSelectionStore.shared
    @EnvironmentObject private var nav: NavCoordinator
    @State private var focusedKey: BrowseFocus?
    @State private var didApplyInitialFocus = false

    // Remembered entry name from the last time the list (not the rail) had focus.
    // Lets `crossNavigate` send Rail → List back to where the user was reading,
    // instead of WrapColumns' same-row-index default which would land them on
    // some arbitrary entry whose ordinal happens to match the focused letter.
    @State private var lastEntryFocus: String?

    var body: some View {
        VStack(spacing: 0) {
            BrowseHeader(crumbPath: dirPath)
            WrapColumns(
                columns: focusColumns,
                current: $focusedKey,
                onActivate: handleActivate,
                onPlayPause: { sort.toggle() },
                onMenuTap: { nav.path.removeLast() },
                crossNavigate: crossNavigate
            ) {
                contentRow
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
                focusedKey = .entry(remembered)
            }
        }
        .onChange(of: sortedEntryNames) { _, _ in applyInitialFocusIfNeeded() }
        .onChange(of: sort.mode) { _, _ in
            // Sort toggle reshuffles the list — snap focus to the top of the
            // new ordering rather than leaving the user mid-list at a row
            // whose neighbors have changed underneath them.
            if let first = sortedEntryNames.first {
                focusedKey = .entry(first)
            }
        }
        .onChange(of: focusedKey) { _, new in
            if case .entry(let name) = new { lastEntryFocus = name }
        }
    }

    // MARK: - data

    private var sortedEntries: [Entry] {
        if case .loaded(let entries) = vm.state { return sortedEntriesList(entries) }
        return []
    }

    private var sortedEntryNames: [String] { sortedEntries.map(\.name) }

    /// Letters present in this directory's entries, in alphabetical order.
    /// Non-alpha leading characters (digits, symbols) collapse under "#".
    private var availableLetters: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in sortedEntries {
            let letter = firstLetter(of: entry.name)
            if seen.insert(letter).inserted {
                ordered.append(letter)
            }
        }
        return ordered.sorted()
    }

    private func firstLetter(of name: String) -> String {
        guard let first = name.unicodeScalars.first else { return "#" }
        if CharacterSet.letters.contains(first) {
            return String(first).uppercased()
        }
        return "#"
    }

    /// Show the rail only when the sort gives the user a navigable alphabetical
    /// ordering to jump within, and when there are enough buckets that jumping
    /// is actually faster than scrolling.
    private var showRail: Bool {
        sort.mode == .name && availableLetters.count >= 3
    }

    private var focusColumns: [[BrowseFocus]] {
        let entryCol = sortedEntryNames.map { BrowseFocus.entry($0) }
        if showRail {
            return [entryCol, availableLetters.map { BrowseFocus.letter($0) }]
        }
        return [entryCol]
    }

    // MARK: - layout

    @ViewBuilder
    private var contentRow: some View {
        switch vm.state {
        case .idle, .loading:
            LoadingColumn().frame(maxHeight: .infinity)
        case .failed(let m):
            ColumnError(message: m).frame(maxHeight: .infinity)
        case .loaded:
            HStack(alignment: .top, spacing: 16) {
                list(entries: sortedEntries)
                if showRail {
                    letterRail
                }
            }
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
                .onChange(of: focusedKey) { _, new in
                    guard case .entry(let name) = new else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(name, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
    }

    private var letterRail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(DuplexColor.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(availableLetters, id: \.self) { letter in
                            letterRow(letter)
                                .id(BrowseFocus.letter(letter))
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: focusedKey) { _, new in
                    guard case .letter = new else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(new!, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 72)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
    }

    private func letterRow(_ letter: String) -> some View {
        let isFocused = focusedKey == .letter(letter)
        return Text(letter)
            .font(.system(size: 22, weight: isFocused ? .heavy : .semibold).monospacedDigit())
            .foregroundStyle(isFocused ? DuplexColor.bg : DuplexColor.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isFocused ? DuplexColor.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 8)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        let isFocused = focusedKey == .entry(entry.name)
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

    // MARK: - actions

    /// Override left/right cross-column behavior so the list↔rail jump means
    /// what the user intends instead of WrapColumns' same-row-index default:
    ///
    /// - List → Rail: land on the rail letter that matches the focused entry's
    ///   first letter, so the user starts navigating the rail from "where they
    ///   already are" alphabetically.
    /// - Rail → List: land back on whichever entry the list last focused
    ///   (tracked in `lastEntryFocus`), so the rail acts as a scratchpad
    ///   without yanking the list cursor to some unrelated row.
    private func crossNavigate(_ current: BrowseFocus, _ dir: WrapColumnsCrossDirection) -> BrowseFocus? {
        switch (current, dir) {
        case (.entry(let name), .right):
            let letter = firstLetter(of: name)
            return availableLetters.contains(letter) ? .letter(letter) : nil
        case (.letter, .left):
            guard let name = lastEntryFocus, sortedEntryNames.contains(name) else { return nil }
            return .entry(name)
        default:
            return nil
        }
    }

    private func handleActivate(_ key: BrowseFocus) {
        switch key {
        case .entry(let name):
            guard let entry = sortedEntries.first(where: { $0.name == name }) else { return }
            lastSel.set(dir: dirPath, child: name)
            switch entry {
            case .dir:  nav.push(.browse(path: subpath(name)))
            case .file: nav.push(.player(vpath: subpath(name)))
            }
        case .letter(let letter):
            // Jump to (and put focus back on) the first entry that lives under
            // this letter. The list's `onChange(of: focusedKey)` scrolls the
            // matched row to center.
            if let target = sortedEntries.first(where: { firstLetter(of: $0.name) == letter }) {
                focusedKey = .entry(target.name)
            }
        }
    }

    private func applyInitialFocusIfNeeded() {
        let names = sortedEntryNames
        guard !names.isEmpty else { return }
        if didApplyInitialFocus { return }
        if let remembered = lastSel.get(dir: dirPath), names.contains(remembered) {
            focusedKey = .entry(remembered)
        } else {
            focusedKey = .entry(names.first!)
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
