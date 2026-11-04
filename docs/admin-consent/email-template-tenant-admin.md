# Email template — admin consent request (any tenant)

> Generic English template, also used by the Admin Consent Sheet (`mailto:` draft). Placeholders in square brackets
> are filled by the app: tenant id, tenant domain, client id, user name.

**Subject:** Admin consent request — AzurePim (self-service PIM activation)

Hello,

I use **AzurePim**, a free macOS app to activate, track and end my own Privileged Identity Management (PIM) roles from
the menu bar. Azure resource roles already work. For **Microsoft Entra roles and PIM for Groups**, Microsoft Graph
requires admin consent, which only a tenant administrator can grant.

**Request:** please grant admin consent to AzurePim for tenant [tenant domain].

- Application: AzurePim — multi-tenant public client (no secret), publisher [publisher name, verified]
- Client ID: [client id]
- Consent link: `https://login.microsoftonline.com/[tenant id]/v2.0/adminconsent?client_id=[client id]&scope=https://graph.microsoft.com/.default&redirect_uri=msauth.fr.vincentlauriat.azurepim://auth`

**Permissions — all delegated** (the app acts only as the signed-in user, within that user's own rights; no
application permissions):

| Permission | Purpose |
|---|---|
| `User.Read` | Identify the signed-in user |
| `RoleEligibilitySchedule.Read.Directory` | List the Entra roles the user is eligible for |
| `RoleAssignmentSchedule.ReadWrite.Directory` | Self-activate / deactivate / extend the user's own Entra roles |
| `RoleManagementPolicy.Read.Directory` | Read PIM rules (max duration, ticket, MFA, approval) |
| `PrivilegedEligibilitySchedule.Read.AzureADGroup` | List eligible PIM groups |
| `PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup` | Self-activate / deactivate the user's own PIM group membership |
| `RoleManagementPolicy.Read.AzureADGroup` | Read PIM group rules |

**Safeguards**
- PIM policies stay enforced by Microsoft (MFA, justification, ticket, approval, maximum duration). Users can only
  activate what they are already eligible for.
- No server and no telemetry: tokens stay in the user's macOS Keychain and travel only between the Mac and Microsoft.
- Works with Conditional Access (system browser / Enterprise SSO plug-in).
- You can require user assignment on the enterprise application and revoke consent at any time.

**Alternative:** if your policy forbids consenting to external multi-tenant apps, register a single-tenant app with the
same delegated permissions and give me its client ID; AzurePim accepts a custom client ID in Settings.

Thank you,
[user name]
