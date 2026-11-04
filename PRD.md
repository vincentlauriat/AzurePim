# AzurePim — Product Requirements Document

## Product name and one-line pitch

**AzurePim** — a free macOS menu bar and desktop app to see, activate, extend and revoke your own Microsoft PIM
(Privileged Identity Management) roles in a couple of clicks, in any Microsoft Entra tenant, without opening the portal.

## Target users

| Persona | Who | Need |
|---|---|---|
| **Cloud admin** | Azure / platform engineer working with just-in-time roles (e.g. Reader at tenant root, Contributor on a resource group) | Activate the right role fast, know when it expires, never be cut mid-deployment |
| **Identity / M365 admin** | Entra admin using eligible directory roles (Application Administrator, Cloud Application Administrator…) and PIM groups | Activate directory roles without the 6-click portal path, see pending approvals |
| **Consultant / MSP** | Works across several customer tenants | One place for every tenant and account, clear separation between them |

Audience: anyone with a Microsoft work account, at Voltalia and outside. Free app.

## Problem and current solution

PIM is the right security model (no standing privilege), but daily use is painful: activating a role in the Azure or
Entra portal takes about a minute and 5–8 clicks, there is no global view of what is active across Azure resources,
Entra roles and PIM groups, and activations expire silently in the middle of work.

Today users rely on the Entra portal (*PIM → My roles*), browser bookmarks, or scripts such as
`scripts/pim-activate.sh` (Azure CLI + REST, Azure resource roles only).

## Goal and success metric

**Goal:** a user never needs the portal for day-to-day PIM activation.

**Success metric:** median time from opening the menu bar panel to an activation in state *Provisioned* is
**under 10 seconds** (portal baseline ≈ 60 s), measured locally by the **Activation timing** feature over the first
30 days of use. No telemetry leaves the Mac; the user can read the figure in the History window.

## Main features

| Feature | User benefit | Priority |
|---|---|---|
| **Role list and menu bar countdown** | See eligible and active roles across Azure resources, Entra roles and PIM groups; the menu bar shows the number of active roles and the time to the next expiry | P0 |
| **Activate and deactivate** | Activate a role with duration, justification and ticket in one sheet; end an activation early | P0 |
| **Dual sign-in** | Use the existing Azure CLI session (`az login`, no app consent needed) or a native Microsoft sign-in (MSAL) | P0 |
| **Entra roles and PIM groups** | Directory roles and PIM for Groups, available in MSAL mode once the tenant admin has consented | P0 |
| **Expiry notification** | macOS notification before an activation expires, with actions Extend / Re-activate / Dismiss | P0 |
| **Admin consent helper** *(proposed)* | When directory scopes are not consented, generate the admin-consent link and a ready-to-send email for the tenant admin | P0 |
| **Extend activation** | Extend or re-activate an activation about to expire, honoring approval rules | P1 |
| **Favorites** | Named sets of roles activated in one click (e.g. "Morning Azure admin") | P1 |
| **History and pending requests** | Past requests made by the app, plus requests waiting for approval, with their status | P1 |
| **Multi-account** | Several accounts and tenants side by side, each clearly labelled | P1 |
| **Activation timing** *(proposed)* | Local measure of time-to-activation, feeding the success metric | P1 |

## Out of scope for v1

| Item | Why it waits |
|---|---|
| Approver mode (approve / deny others' requests) | Different persona and permission set; v1 focuses on the requester |
| Administering PIM role settings (policies) | Admin tooling, high blast radius, already well served by the portal |
| Managing eligibilities (create / remove eligible assignments) | Same reason; needs privileged write scopes |
| Windows and Linux versions | Native macOS first |
| Mac App Store version | The App Store sandbox forbids running the Azure CLI; planned after v1 as an MSAL-only build |

## User stories

1. **Role list and menu bar countdown** — As a cloud admin, I want to see all my eligible and active roles from the menu bar, so that I know my current privileges at a glance.
2. **Activate and deactivate** — As a cloud admin, I want to activate a role with a duration and a justification in one sheet, so that I can start working within seconds.
3. **Activate and deactivate** — As any user, I want to end an activation early, so that I hold privileges no longer than needed.
4. **Dual sign-in** — As a user who already ran `az login`, I want AzurePim to reuse that session, so that I need no extra setup or admin approval.
5. **Dual sign-in** — As a user without the Azure CLI, I want to sign in with my Microsoft account inside the app, so that I do not need a terminal.
6. **Entra roles and PIM groups** — As an identity admin, I want to activate eligible Entra roles and PIM group memberships, so that I can do directory work without the portal.
7. **Expiry notification** — As any user, I want a notification 15 minutes before an activation ends, so that I am not cut off mid-task.
8. **Admin consent helper** — As a user whose tenant has not consented, I want a ready-made consent link and email, so that I can ask my admin in one step.
9. **Extend activation** — As a cloud admin, I want to extend an activation from the notification, so that a long deployment is not interrupted.
10. **Favorites** — As a daily user, I want to activate my usual set of roles in one click, so that my morning routine takes seconds.
11. **History and pending requests** — As any user, I want to see past and pending requests, so that I know what is waiting for approval and what I did.
12. **Multi-account** — As a consultant, I want several tenants side by side, so that I can work for several customers without signing out.
13. **Activation timing** — As the product owner, I want the time-to-activation measured locally, so that I can check the 10-second goal.

## Acceptance criteria

1. Given a signed-in account with 2 eligible Azure roles, when I open the menu bar panel, then both roles appear with their scope within 2 s (cached list shown instantly, refreshed in the background).
2. Given an eligible role with a 8 h maximum, when I choose 4 h, type a justification and press Activate, then the role shows *Active* with a countdown and the menu bar count increases by one.
2b. Given a policy that requires a ticket number, when I leave the ticket empty, then Activate stays disabled and the field says why.
3. Given an active role, when I press Deactivate and confirm, then the role returns to *Eligible* and the countdown disappears.
4. Given `az login` has been run, when I choose "Use Azure CLI session" at first launch, then Azure resource roles load without any browser sign-in.
5. Given no Azure CLI, when I choose "Sign in with Microsoft", then a system browser sign-in (with MFA) completes and roles load.
6. Given MSAL mode and admin consent granted, when I open the Entra section, then eligible directory roles and PIM groups are listed and can be activated.
7. Given an activation ending in 15 minutes, when that moment comes, then a notification appears with Extend and Dismiss actions.
8. Given MSAL mode and a 403 for missing consent, when I open the Entra section, then I see "Admin consent required" with buttons Copy consent link and Prepare email.
9. Given an activation ending in 10 minutes, when I press Extend, then a new request is sent and its status (*Provisioned* or *PendingApproval*) is shown.
10. Given a favorite with 2 roles, when I click it, then both activation requests are sent and each result is shown separately.
11. Given a request pending approval, when I open History, then it is listed as *Pending approval* with the time it was sent.
12. Given two accounts in two tenants, when I open the panel, then roles are grouped by account with the tenant name as header.
13. Given 5 activations made from the panel, when I open History, then the median time-to-activation is shown.

## Open questions

1. **Name and trademark.** "Azure" is a Microsoft trademark; Microsoft's guidelines discourage it in third-party product names. *Recommendation:* keep **AzurePim** as working name for v1 and for internal use; before public release on GitHub, consider a neutral name (e.g. "PimBar") with "for Microsoft Entra / Azure" in the description.
2. **Publisher tenant of the multi-tenant app registration.** *Assumption:* a tenant owned by Vincent (personal or free Microsoft 365 developer tenant), not Voltalia's. *Recommendation:* use a dedicated dev tenant so the app identity does not depend on an employer.
3. **Voltalia consent.** *Assumption:* the Voltalia Entra admin is asked to grant admin consent to the multi-tenant app; alternative is a Voltalia-owned single-tenant registration. Drafts in `docs/admin-consent/`. *Recommendation:* ask for consent first; fall back to a Voltalia registration if policy forbids third-party multi-tenant apps.
4. **License.** *Assumption:* MIT, public GitHub repository. *Recommendation:* MIT.
5. **Both sign-in modes in v1.** Resolved contradiction: Entra roles need admin consent per tenant, so v1 must stay fully useful for Azure resource roles without it; the Entra section degrades to the **Admin consent helper**.
6. **Success metric measurability.** Resolved contradiction: no feature measured activation time, so **Activation timing** was added.
7. **App Store later vs Azure CLI mode.** Resolved contradiction: the sandbox forbids launching `az`; sign-in is behind a `TokenProvider` protocol so an App Store build can ship MSAL only.
8. **GUI apps do not inherit the shell PATH.** *Assumption:* AzurePim looks for `az` in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then lets the user pick the binary.
9. **Default notification lead time.** *Assumption:* 15 minutes, configurable 5–60.
10. **Refresh interval.** *Assumption:* 5 minutes in the background, immediate on panel open if data is older than 60 s.
11. **What "Extend" does (changed 2026-11-04).** PIM `SelfExtend` / `selfExtend` targets *assignments* expiring within 14 days, with admin approval; it does not lengthen an activation. *Decision:* Extend reads the policy fresh, then deactivates the role and activates it again with its last duration and justification (a few seconds without the role; up to 3 retries while Azure still reports the old activation). Extend is refused — role untouched — when the policy cannot be read, or needs approval, a ticket or MFA, or within 5 minutes of activation. Every follow-up notification says whether the role is still held. *Recommendation:* keep; confirm with a live test. **To be confirmed by Vincent.**
12. **Deep links can activate roles (added 2026-11-04).** Any local process can open `azurepim://activate?favorite=`. *Decision:* AzurePim always asks for confirmation before running a favorite from a link. *Recommendation:* keep; a setting to skip the confirmation could come later for Shortcuts users.
