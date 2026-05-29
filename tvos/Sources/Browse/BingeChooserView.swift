import SwiftUI

/// Shown when a video is played *outside* a binge but happens to be the
/// next-up video of one or more binges. Lets the user attach this playback to
/// a binge (so finishing it advances the queue) or play it unattached.
///
/// Presented as its own navigation route rather than an overlay so it owns the
/// focus engine outright — no contention with the underlying grid's
/// press-capture host.
struct BingeChooserView: View {
    let vpath: String

    @EnvironmentObject private var nav: NavCoordinator
    @ObservedObject private var store = BingeStore.shared

    private var matches: [Binge] { store.bingesWithFront(vpath) }

    var body: some View {
        ZStack {
            DuplexColor.bg.ignoresSafeArea()
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text("🍿")
                        .font(.system(size: 52))
                    Text("Continue a binge?")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(DuplexColor.fg)
                    Text(DuplexFormat.leaf(of: vpath))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DuplexColor.muted)
                        .lineLimit(1)
                }

                VStack(spacing: 14) {
                    ForEach(matches) { binge in
                        bingeButton(binge)
                    }
                    Button(action: { nav.resolveChooser(vpath: vpath, bingeId: nil) }) {
                        Text("This isn’t part of a binge — just play it")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(DuplexColor.fg)
                            .frame(maxWidth: 560)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 18)
                            .background(DuplexColor.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(40)
        }
        .navigationBarHidden(true)
        .onExitCommand { nav.path.removeLast() }
        .onAppear {
            // Defensive: if the binges changed out from under us and nothing
            // matches anymore, don't strand the user on an empty chooser.
            if matches.isEmpty {
                nav.resolveChooser(vpath: vpath, bingeId: nil)
            }
        }
    }

    private func bingeButton(_ binge: Binge) -> some View {
        Button(action: { nav.resolveChooser(vpath: vpath, bingeId: binge.id) }) {
            HStack(spacing: 16) {
                Text("▶")
                    .font(.system(size: 26))
                    .foregroundStyle(DuplexColor.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue binge")
                        .font(.system(size: 15, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(DuplexColor.muted)
                    Text(binge.origin)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(DuplexColor.fg)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("\(binge.remaining) remaining")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DuplexColor.accent)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(DuplexColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.card)
    }
}
