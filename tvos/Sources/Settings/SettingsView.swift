import SwiftUI

struct SettingsView: View {
    @ObservedObject private var resume = ResumeStore.shared
    @State private var serverOverride: String = ""
    @State private var confirmForget: ConfirmTarget?

    private enum ConfirmTarget: Identifiable {
        case resumes
        var id: Int { 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Settings")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(DuplexColor.fg)
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)

            ScrollView {
                VStack(spacing: 18) {
                    settingRow(
                        title: "Resume positions",
                        status: "\(resume.count) remembered"
                    ) {
                        Button("Forget all") { confirmForget = .resumes }
                            .disabled(resume.count == 0)
                    }

                    serverURLRow
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DuplexColor.bg.ignoresSafeArea())
        .onAppear {
            serverOverride = UserDefaults.standard.string(forKey: AppConfig.serverURLOverrideKey) ?? ""
        }
        .alert(item: $confirmForget) { target in
            switch target {
            case .resumes:
                return Alert(
                    title: Text("Forget all \(resume.count) resume positions?"),
                    primaryButton: .destructive(Text("Forget all")) { resume.forgetAll() },
                    secondaryButton: .cancel())
            }
        }
    }

    private func settingRow<Trailing: View>(
        title: String,
        status: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DuplexColor.fg)
                Text(status)
                    .font(.system(size: 18))
                    .foregroundStyle(DuplexColor.muted)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
    }

    private var serverURLRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server URL")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DuplexColor.fg)
            Text("Build-time default: \(AppConfig.buildTimeServerURL)")
                .font(.system(size: 16))
                .foregroundStyle(DuplexColor.muted)
            HStack {
                TextField("Override (e.g. http://10.10.10.113:2345)", text: $serverOverride)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .padding(12)
                    .background(DuplexColor.panel2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Save") {
                    AppConfig.setServerURLOverride(serverOverride)
                }
                .disabled(serverOverride == (UserDefaults.standard.string(forKey: AppConfig.serverURLOverrideKey) ?? ""))
                Button("Reset") {
                    AppConfig.setServerURLOverride(nil)
                    serverOverride = ""
                }
                .disabled(UserDefaults.standard.string(forKey: AppConfig.serverURLOverrideKey) == nil)
            }
            Text("Restart the app for changes to take effect.")
                .font(.system(size: 14))
                .foregroundStyle(DuplexColor.muted)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
    }
}
