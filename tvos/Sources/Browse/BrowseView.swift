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
    @ObservedObject private var viewPref = ViewPreference.shared
    @ObservedObject private var ext = ExtensionPreference.shared
    @ObservedObject private var refresh = LibraryRefresh.shared
    @EnvironmentObject private var nav: NavCoordinator
    @State private var focusedKey: BrowseFocus?
    @State private var didApplyInitialFocus = false

    // Measured interior width of the poster panel, used to choose the grid's
    // column count. Both the visual `LazyVGrid` and the WrapColumns focus
    // topology derive their column count from this, so they stay in lockstep.
    @State private var gridWidth: CGFloat = 0

    private let client = DuplexClient()

    // Binge creation: long-pressing a folder flattens it and raises a confirm.
    // One dialog state ⇒ one `.alert` (multiple `.alert`s clobber each other).
    @State private var dialog: BingeDialog?

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
                isActive: dialog == nil,
                onActivate: handleActivate,
                onLongSelect: handleLongSelect,
                onPlayPause: { viewPref.cycle() },
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
        .alert(item: $dialog) { d in
            switch d {
            case .confirmCreate(let p):
                return Alert(
                    title: Text("Create a Binge?"),
                    message: Text("\(p.origin)\n\(p.vpaths.count) total \(p.vpaths.count == 1 ? "video" : "videos")"),
                    primaryButton: .default(Text("Binge")) {
                        BingeStore.shared.create(origin: p.origin, vpaths: p.vpaths)
                    },
                    secondaryButton: .cancel()
                )
            case .error(let msg):
                return Alert(
                    title: Text("Couldn’t build binge"),
                    message: Text(msg),
                    dismissButton: .cancel(Text("OK"))
                )
            case .confirmDelete:
                // Binges aren't deleted from Browse; never set here.
                return Alert(title: Text(""), dismissButton: .cancel())
            }
        }
        .task {
            await vm.load(path: dirPath)
            applyInitialFocusIfNeeded()
        }
        .onChange(of: sortedEntryNames) { _, _ in applyInitialFocusIfNeeded() }
        .onChange(of: viewPref.sort) { _, _ in snapFocusToTop() }
        .onChange(of: viewPref.layout) { _, _ in snapFocusToTop() }
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
        viewPref.layout == .list && viewPref.sort == .name && availableLetters.count >= 3
    }

    private var focusColumns: [[BrowseFocus]] {
        let entryKeys = sortedEntryNames.map { BrowseFocus.entry($0) }
        if viewPref.layout == .posters {
            // Strided columns mirror the row-major LazyVGrid, so WrapColumns'
            // left/right + up/down give true 2D grid navigation. No rail.
            return posterStridedColumns(entryKeys, cols: posterCols)
        }
        if showRail {
            return [entryKeys, availableLetters.map { BrowseFocus.letter($0) }]
        }
        return [entryKeys]
    }

    /// Number of poster columns that fit the measured panel interior.
    private var posterCols: Int { PosterMetric.columnCount(forWidth: gridWidth) }

    private func snapFocusToTop() {
        if let first = sortedEntryNames.first { focusedKey = .entry(first) }
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
            if viewPref.layout == .posters {
                posterList(entries: sortedEntries)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    list(entries: sortedEntries)
                    if showRail {
                        letterRail
                    }
                }
            }
        }
    }

    // MARK: - posters

    private func posterList(entries: [Entry]) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(DuplexColor.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    if entries.isEmpty {
                        EmptyColumn(icon: "📭", title: "Empty", hint: "Nothing in this folder.")
                    } else {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: PosterMetric.spacing),
                                count: posterCols
                            ),
                            spacing: 28
                        ) {
                            ForEach(entries, id: \.id) { entry in
                                posterCell(for: entry).id(entry.name)
                            }
                        }
                        .padding(20)
                    }
                }
                .onChange(of: focusedKey) { _, new in
                    guard case .entry(let name) = new else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(name, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        .background(
            GeometryReader { g in
                Color.clear.onChange(of: g.size.width, initial: true) { _, w in
                    // Subtract the grid's own 20pt inset on each side.
                    let usable = w - 40
                    if abs(gridWidth - usable) > 1 { gridWidth = usable }
                }
            }
        )
    }

    @ViewBuilder
    private func posterCell(for entry: Entry) -> some View {
        let isFocused = focusedKey == .entry(entry.name)
        switch entry {
        case .dir(let name, _, _, let hasPoster):
            PosterCell(
                url: hasPoster ? client.posterURL(path: subpath(name), cacheBust: refresh.posterNonce) : nil,
                fallbackGlyph: "📁",
                title: name,
                isFocused: isFocused
            )
        case .file(let name, _, _, _, let hasPoster):
            PosterCell(
                url: hasPoster ? client.posterURL(path: subpath(name), cacheBust: refresh.posterNonce) : nil,
                fallbackGlyph: "🎬",
                title: DuplexFormat.displayFileName(name),
                isFocused: isFocused
            )
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
        case .dir(let name, let children, let mtime, _):
            GridEntryRow(
                icon: "📁",
                title: name,
                subtitle: nil,
                meta: viewPref.sort == .recent
                    ? "\(children) · \(DuplexFormat.relative(mtime))"
                    : "\(children) entries",
                isFocused: isFocused
            )
        case .file(let name, _, let size, let mtime, _):
            GridEntryRow(
                icon: "🎬",
                title: DuplexFormat.displayFileName(name),
                subtitle: nil,
                meta: viewPref.sort == .recent
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
        // Poster grid: grid-aware Down/Up (drop into / wrap up to the partial
        // last row instead of skipping it). There's no alphabet rail in poster
        // mode, so no other cross-navigation applies.
        if viewPref.layout == .posters {
            guard case .entry = current else { return nil }
            let keys = sortedEntryNames.map { BrowseFocus.entry($0) }
            switch dir {
            case .down: return posterGridDownTarget(keys, from: current, cols: posterCols)
            case .up:   return posterGridUpTarget(keys, from: current, cols: posterCols)
            default:    return nil
            }
        }
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
            switch entry {
            case .dir:  nav.push(.browse(path: subpath(name)))
            case .file: nav.play(vpath: subpath(name))
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

    /// Long-press a folder to binge its entire subtree. Files ignore the hold
    /// (they just play on tap). Flattens server-side, then confirms.
    private func handleLongSelect(_ key: BrowseFocus) {
        guard case .entry(let name) = key,
              let entry = sortedEntries.first(where: { $0.name == name }),
              entry.isDir else { return }
        let origin = subpath(name)
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

    private func applyInitialFocusIfNeeded() {
        let names = sortedEntryNames
        guard !names.isEmpty else { return }
        if didApplyInitialFocus { return }
        focusedKey = .entry(names.first!)
        didApplyInitialFocus = true
    }

    private var isDirFocused: Bool {
        if case .entry(let name) = focusedKey,
           let entry = sortedEntries.first(where: { $0.name == name }) {
            return entry.isDir
        }
        return false
    }

    private var footerHint: some View {
        HStack(spacing: 18) {
            Spacer()
            Text("▶︎❙❙  View: \(viewPref.label)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DuplexColor.muted)
            if isDirFocused {
                Text("•").foregroundStyle(DuplexColor.muted)
                Text("Hold ✓ to binge this folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DuplexColor.muted)
            }
            Spacer()
        }
        // Constant height so toggling the hold-hint never resizes the list.
        .frame(height: 24)
        .padding(.bottom, 14)
    }

    private func subpath(_ name: String) -> String {
        dirPath.isEmpty ? name : "\(dirPath)/\(name)"
    }

    private func sortedEntriesList(_ entries: [Entry]) -> [Entry] {
        switch viewPref.sort {
        case .name:
            return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return entries.sorted { $0.mtime > $1.mtime }
        }
    }
}
