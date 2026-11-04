import AzurePimCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// Onboarding (AppFlow › First use): privacy promise, sign-in mode, notifications + launch at login.
struct OnboardingView: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var page = 0
    @State private var busy = false
    @State private var error: String?
    @State private var notifications = true
    @State private var launchAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: signIn
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            Divider()
            footer.padding(16)
        }
        .frame(width: 520, height: 420)
        .task { await accounts.refreshCLIStatus() }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Welcome to AzurePim").font(.title2.weight(.semibold))
            Text("Activate, track and end your Microsoft PIM roles from the menu bar.")
                .multilineTextAlignment(.center)
            Label("No server, no telemetry: your tokens never leave this Mac except to Microsoft.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How should AzurePim sign in?").font(.title3.weight(.semibold))
            cliOption
            Button {
                run { try await accounts.addMSALAccount() }
            } label: {
                Label("Sign in with Microsoft", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .disabled(busy || !accounts.isMSALConfigured)
            Text(accounts.isMSALConfigured
                 ? "Azure resource roles, Entra roles and PIM groups (Entra roles need your admin's consent)."
                 : "Not available in this build yet (no app registration client ID).")
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var cliOption: some View {
        switch accounts.cliStatus {
        case .signedIn(let identity):
            Button {
                run { try await accounts.addCLIAccount() }
            } label: {
                Label("Use Azure CLI session (\(identity.upn), \(identity.tenantName ?? identity.tenantId))",
                      systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            Text("Azure resource roles, no admin consent needed.").font(.caption).foregroundStyle(.secondary)
        case .notSignedIn(let command):
            Label("Azure CLI found but not signed in — run `\(command)` then retry.", systemImage: "terminal")
            Button("Retry") { Task { await accounts.refreshCLIStatus() } }
        case .notInstalled:
            Label("Azure CLI not found (optional).", systemImage: "terminal").foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .unknown:
            ProgressView("Looking for the Azure CLI…").controlSize(.small)
        }
    }

    private var finish: some View {
        Form {
            Toggle("Notify me before an activation expires", isOn: $notifications)
            Toggle("Launch AzurePim at login", isOn: $launchAtLogin)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            if page > 0 { Button("Back") { page -= 1 } }
            Spacer()
            if page == 1 { Button("Skip") { page = 2 } }
            Button(page == 2 ? "Done" : "Continue") {
                if page < 2 { page += 1 } else { Task { await complete() } }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await action()
                page = 2
                await store.refresh()
            } catch {
                self.error = AccountService.message(for: error)
            }
        }
    }

    private func complete() async {
        if notifications {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try? await SMAppService.mainApp.unregister() }
        } catch {
            // Unsigned debug builds cannot register; the setting stays editable in Settings.
            self.error = "Launch at login: \(error.localizedDescription)"
        }
        let settings = accounts.settings
        settings.launchAtLogin = launchAtLogin
        settings.onboardingCompleted = true
        dismissWindow(id: WindowID.onboarding)
    }
}
