import SwiftUI
import MSAL
import AzurePimCore

/// Settings scene. Step 1: About only; Accounts Settings arrives in T2.5.
struct SettingsView: View {
    let updater: UpdaterController

    var body: some View {
        TabView {
            Form {
                LabeledContent("Version", value: Bundle.main.appVersion)
                LabeledContent("Core", value: AzurePimCore.version)
                LabeledContent("MSAL", value: MSALPublicClientApplication.sdkVersion ?? "?")
                LabeledContent("Sparkle", value: updater.sparkleVersion)
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 260)
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
