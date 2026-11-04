import AzurePimCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Accounts Settings (AppFlow): add/remove accounts, mode badge, Entra status, custom client id, preferences.
struct AccountsSettingsView: View {
    @Environment(AccountService.self) private var service
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var busy = false
    @State private var error: String?
    @State private var pendingRemoval: Account?

    var body: some View {
        Form {
            Section("Accounts") {
                if accounts.isEmpty {
                    Text("No account yet.").foregroundStyle(.secondary)
                }
                ForEach(accounts) { account in
                    AccountRow(account: account, busy: busy) {
                        run { try await service.enableDirectoryAccess(for: account) }
                    } remove: {
                        pendingRemoval = account
                    }
                }
                HStack {
                    Menu("Add Account") {
                        Button("Use Azure CLI session") { run { try await service.addCLIAccount() } }
                        Button("Sign in with Microsoft") { run { try await service.addMSALAccount() } }
                            .disabled(!service.isMSALConfigured)
                    }
                    .fixedSize()
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            PreferencesSection(settings: service.settings)
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(pendingRemoval?.upn ?? "")?", isPresented: .constant(pendingRemoval != nil),
                            presenting: pendingRemoval) { account in
            Button("Remove", role: .destructive) {
                do { try service.remove(account) } catch { self.error = AccountService.message(for: error) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("Its cached roles and history are deleted from this Mac. Your roles in Azure are not changed.")
        }
    }

    private func run(_ action: @escaping () async throws -> some Any) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { _ = try await action() } catch { self.error = AccountService.message(for: error) }
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let busy: Bool
    let enableEntra: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(initials).font(.caption.weight(.semibold)).frame(width: 28, height: 28)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.upn)
                Text(account.tenantName ?? account.tenantId).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(account.mode == .azureCLI ? "CLI" : "Microsoft")
                .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
            entraStatus
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Remove account")
        }
    }

    @ViewBuilder private var entraStatus: some View {
        switch account.directoryAccess {
        case .notApplicable:
            Text("Entra: n/a").font(.caption).foregroundStyle(.secondary)
                .help("Entra roles need Microsoft sign-in: the Azure CLI cannot request PIM directory permissions.")
        case .notRequested:
            Button("Enable Entra roles", action: enableEntra).controlSize(.small).disabled(busy)
        case .consentRequired:
            Label("Consent required", systemImage: "info.circle").font(.caption).foregroundStyle(.blue)
        case .enabled:
            Label("Entra roles", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        }
    }

    private var initials: String {
        account.upn.split(separator: "@").first.map { String($0.prefix(2)).uppercased() } ?? "?"
    }
}

private struct PreferencesSection: View {
    @Bindable var settings: AppSettings
    @State private var clientIdText = ""
    @State private var azPathError: String?

    var body: some View {
        Section("Preferences") {
            Stepper("Refresh every \(settings.refreshIntervalMinutes) min",
                    value: $settings.refreshIntervalMinutes, in: 1...30)
            Stepper("Notify \(settings.notificationLeadMinutes) min before expiry",
                    value: $settings.notificationLeadMinutes, in: 5...60, step: 5)
            Stepper("Keep history \(settings.historyRetentionDays) days",
                    value: $settings.historyRetentionDays, in: 7...365, step: 7)
            Picker("Menu bar", selection: $settings.menuBarStyle) {
                Text("Icon").tag(MenuBarStyle.icon)
                Text("Icon + count").tag(MenuBarStyle.iconCount)
                Text("Icon + count + time").tag(MenuBarStyle.iconCountTime)
            }
        }
        Section("Advanced") {
            LabeledContent("Azure CLI") {
                HStack {
                    Text(settings.azCLIPath ?? "Auto-detect").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseAZ)
                    if settings.azCLIPath != nil { Button("Reset") { settings.azCLIPath = nil } }
                }
            }
            if let azPathError { Text(azPathError).font(.caption).foregroundStyle(.red) }
            TextField("Custom client ID", text: $clientIdText, prompt: Text("AzurePim app registration"))
                .onSubmit(saveClientId)
                .onAppear { clientIdText = settings.customClientId ?? "" }
            if !clientIdText.isEmpty, Validation.clientId(clientIdText) != nil {
                Text("Must be a GUID.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func saveClientId() {
        let trimmed = clientIdText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { settings.customClientId = nil } else if Validation.clientId(trimmed) == nil {
            settings.customClientId = trimmed
        }
    }

    private func chooseAZ() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.prompt = "Choose az"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if Validation.azPath(url.path) == nil {
            settings.azCLIPath = url.path
            azPathError = nil
        } else {
            azPathError = "Choose the executable named `az`."
        }
    }
}
