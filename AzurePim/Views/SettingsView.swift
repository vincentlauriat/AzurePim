import AzurePimCore
import MSAL
import SwiftUI

/// Settings scene: Accounts Settings + About.
struct SettingsView: View {
    let updater: UpdaterController
    @Environment(AccountService.self) private var accounts

    var body: some View {
        TabView {
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            Form {
                LabeledContent("Version", value: Bundle.main.appVersion)
                LabeledContent("Core", value: AzurePimCore.version)
                LabeledContent("MSAL", value: MSALPublicClientApplication.sdkVersion ?? "?")
                LabeledContent("Sparkle", value: updater.sparkleVersion)
                LabeledContent("Microsoft sign-in", value: accounts.isMSALConfigured ? "Configured" : "No client ID")
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 520)
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
