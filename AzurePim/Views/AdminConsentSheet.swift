import AppKit
import AzurePimCore
import SwiftData
import SwiftUI

/// Admin Consent Sheet (AppFlow, ImplementationPlan T3.8): explains the missing consent, builds the consent link
/// and a ready-to-send email (templates in docs/admin-consent/).
struct AdminConsentSheet: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    let accountId: UUID?
    @Query private var allAccounts: [Account]
    @State private var status: String?
    @State private var checking = false

    private var account: Account? { allAccounts.first { $0.id == accountId } }

    var body: some View {
        Group {
            if let account {
                content(account)
            } else {
                ContentUnavailableView("Account not found", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .frame(width: 560)
        .padding(20)
    }

    private func content(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Admin consent required", systemImage: "info.circle").font(.title3.weight(.semibold))
            Text("""
            Microsoft Graph only lets AzurePim read and activate Entra roles and PIM groups after an administrator \
            of \(account.tenantName ?? account.tenantId) consents to these delegated permissions. Azure resource roles \
            keep working meanwhile.
            """)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(ConsentRequest.permissions, id: \.0) { permission, purpose in
                    HStack(alignment: .firstTextBaseline) {
                        Text(permission).font(.caption.monospaced())
                        Text("— \(purpose)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let link = ConsentRequest.link(tenantId: account.tenantId, clientId: accounts.msalClientId) {
                Text(link.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                HStack {
                    Button("Copy consent link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        status = "Link copied."
                    }
                    Button("Prepare email") {
                        if let mail = ConsentRequest.mailto(account: account, link: link) { NSWorkspace.shared.open(mail) }
                    }
                    Spacer()
                    if checking { ProgressView().controlSize(.small) }
                    Button("Check again") { Task { await check(account) } }
                        .disabled(checking)
                }
            } else {
                Text("Microsoft sign-in is not configured in this build (no client ID), so no consent link can be built.")
                    .foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func check(_ account: Account) async {
        checking = true
        defer { checking = false }
        do {
            try await accounts.enableDirectoryAccess(for: account)
            if account.directoryAccess == .enabled {
                status = "Consent granted — loading Entra roles."
                await store.refresh()
                dismissWindow()
            } else {
                status = "Still waiting for admin consent."
            }
        } catch {
            status = AccountService.message(for: error)
        }
    }
}

enum ConsentRequest {
    static let permissions: [(String, String)] = [
        ("User.Read", "identify the signed-in user"),
        ("RoleEligibilitySchedule.Read.Directory", "list eligible Entra roles"),
        ("RoleAssignmentSchedule.ReadWrite.Directory", "activate / deactivate your own Entra roles"),
        ("RoleManagementPolicy.Read.Directory", "read PIM rules"),
        ("PrivilegedEligibilitySchedule.Read.AzureADGroup", "list eligible PIM groups"),
        ("PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup", "activate your own PIM group membership"),
        ("RoleManagementPolicy.Read.AzureADGroup", "read PIM group rules")
    ]

    static func link(tenantId: String, clientId: String?) -> URL? {
        guard let clientId else { return nil }
        var components = URLComponents(string: "https://login.microsoftonline.com/\(tenantId)/v2.0/adminconsent")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "scope", value: "https://graph.microsoft.com/.default"),
            URLQueryItem(name: "redirect_uri", value: "msauth.\(Bundle.main.bundleIdentifier ?? "fr.vincentlauriat.azurepim")://auth")
        ]
        return components.url
    }

    /// `mailto:` draft based on docs/admin-consent/email-template-tenant-admin.md (French when the Mac is in French).
    static func mailto(account: Account, link: URL) -> URL? {
        let french = Locale.preferredLanguages.first?.hasPrefix("fr") == true
        let list = permissions.map { "- \($0.0): \($0.1)" }.joined(separator: "\n")
        let tenant = account.tenantName ?? account.tenantId
        let subject = french ? "Demande de consentement administrateur – AzurePim (activation PIM)"
                             : "Admin consent request — AzurePim (self-service PIM activation)"
        let body = french ? """
        Bonjour,

        J'utilise AzurePim, une application macOS gratuite pour activer, suivre et révoquer mes propres rôles PIM. \
        Pour les rôles Entra et les groupes PIM, Microsoft Graph exige un consentement administrateur.

        Peux-tu donner le consentement pour le tenant \(tenant) ?
        \(link.absoluteString)

        Permissions déléguées uniquement (l'application agit au nom de l'utilisateur, avec ses propres droits) :
        \(list)

        Les règles PIM (MFA, justification, ticket, approbation, durée max) restent appliquées par Microsoft. \
        Aucun serveur, aucune télémétrie.

        Merci,
        \(account.upn)
        """ : """
        Hello,

        I use AzurePim, a free macOS app to activate, track and end my own PIM roles. For Entra roles and PIM \
        groups, Microsoft Graph requires admin consent.

        Could you grant consent for tenant \(tenant)?
        \(link.absoluteString)

        Delegated permissions only (the app acts as the signed-in user, within that user's own rights):
        \(list)

        PIM policies (MFA, justification, ticket, approval, maximum duration) stay enforced by Microsoft. \
        No server, no telemetry.

        Thank you,
        \(account.upn)
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }
}
