# AzurePim — Implementation plan

Build order for an AI agent (Claude Code) with Vincent as product owner. Each step ends with a checkpoint.
Names of features, screens and entities are those of `PRD.md`, `AppFlow.md` and `BackendSchema.md`.

## Step 1, project setup

| Task | Owner | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T1.1 Repo and Xcode project | agent | TRD | Git repo `AzurePim`, Xcode project (macOS 14, Swift 6), app target + Swift package `AzurePimCore`, `.gitignore` (tracking files, `release/`, `*.dmg`) | `xcodebuild -scheme AzurePim build` succeeds | — |
| T1.2 App shell | agent | AppFlow navigation rules | `MenuBarExtra(.window)` with placeholder panel, main `Window` with sidebar (Roles, History, Favorites), `Settings` scene, `LSUIElement`, Dock icon toggling | App runs, icon in menu bar, ⌘0 opens window, closing it hides Dock icon | T1.1 |
| T1.3 Dependencies | agent | TRD | SPM: MSAL (`microsoft-authentication-library-for-objc`), Sparkle 2 | Build green with both linked | T1.1 |
| T1.4 CI | agent | TRD | GitHub Actions: build + `swift test` on `AzurePimCore` + SwiftLint | CI green on a PR | T1.1 |
| T1.5 App registration | Vincent | TRD scopes table, PRD open question 2 | Multi-tenant public client in publisher tenant, redirect URI `msauth.fr.vincentlauriat.azurepim://auth`, delegated scopes listed in TRD | Client id recorded in `Config.xcconfig` | — |

**Checkpoint 1:** app launches from Xcode, menu bar icon visible, empty panel and window open/close correctly.

## Step 2, data and authentication

| Task | Owner | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T2.1 SwiftData schema | agent | BackendSchema | `@Model` Account, EligibleRole, ActiveAssignment, Favorite, ActivationRecord, AppSettings; `VersionedSchema` v1; seed AppSettings | Unit tests create/read each entity; validation rules tested | T1.1 |
| T2.2 TokenProvider protocol | agent | TRD | `TokenProvider` in `AzurePimCore`, `Resource` enum (arm, graph), `AccessToken`, error types incl. `claimsChallenge` | Protocol + mock provider used by tests | T1.1 |
| T2.3 AzureCLITokenProvider | agent | TRD, Open question 8 | `az` discovery (known paths, user override), `Process` with argument array, JSON parsing, tenant selection, `az account show` for UPN/tenant | Test against real `az` returns ARM token; missing `az` / expired session map to typed errors | T2.2 |
| T2.4 MSALTokenProvider | agent | TRD, T1.5 | Interactive + silent sign-in, multi-account, incremental directory scopes, claims challenge re-auth, sign-out | Sign-in with a Voltalia and a dev-tenant account; silent token after relaunch | T2.2, T1.3, T1.5 |
| T2.5 Onboarding and Accounts Settings | agent | AppFlow (First use, Accounts Settings) | Onboarding (3 pages), Accounts Settings (add/remove, mode badge, Entra status) | Acceptance criteria 4 and 5 pass | T2.3, T2.4, T2.1 |

**Checkpoint 2:** both sign-in modes add an Account; relaunch keeps them; criteria 4 and 5 verified by hand.

## Step 3, main user path

| Task | Owner | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T3.1 ARMClient | agent | TRD API table | List eligibilities / active instances (`asTarget()`), activation requests (`SelfActivate`, `SelfDeactivate`, `SelfExtend`), policy read, retries/429 handling | Contract tests with recorded JSON fixtures; live test lists Reader @ Tenant Root Group | T2.2 |
| T3.2 GraphClient (Entra roles + PIM groups) | agent | TRD API table | `filterByCurrentUser` eligibilities/instances, `selfActivate` / `selfDeactivate` / `selfExtend`, group equivalents, policy read, 403-consent detection | Fixtures tests; live test in dev tenant with consent | T2.2 |
| T3.3 PIMService + RoleStore | agent | BackendSchema | Normalization of 3 sources into EligibleRole / ActiveAssignment, concurrent refresh per account, cache in SwiftData, `@Observable` store | Refresh of 2 accounts < 3 s p50 in live test | T3.1, T3.2, T2.1 |
| T3.4 Menu Bar Panel | agent | AppFlow, DesignBrief | Sections Active / Favorites / Eligible, account grouping, header refresh + timestamp, empty and blocked states | Acceptance criteria 1 and 12 pass | T3.3 |
| T3.5 Menu bar label | agent | DesignBrief components | Count + next expiry, colour thresholds, style setting, update cadence (60 s / 1 s last 5 min) | Label matches active state after activation; idle CPU < 0.5 % | T3.3 |
| T3.6 Activation Sheet | agent | AppFlow action details | Duration presets capped by policy, justification/ticket validation, send, Pending approval state, claims-challenge retry, CLI-mode `az login` hint | Acceptance criteria 2, 2b pass | T3.3 |
| T3.7 Deactivate | agent | AppFlow | Row action + confirm popover, 5-min rule | Acceptance criterion 3 passes | T3.3 |
| T3.8 Admin Consent Sheet | agent | AppFlow, `docs/admin-consent/` templates | Consent link builder (`/{tenant}/v2.0/adminconsent`), `mailto:` draft EN/FR, Check again | Acceptance criterion 8 passes in a non-consented tenant | T3.2 |
| T3.9 Expiry Notification | agent | AppFlow, DesignBrief | `UNUserNotificationCenter` scheduling at `endAt − lead`, categories with Extend/Dismiss, reschedule on refresh | Acceptance criterion 7 passes with a 20-min activation | T3.3 |

**Checkpoint 3:** full main path works for Azure resource roles (CLI and MSAL) and Entra roles (MSAL, consented dev tenant): criteria 1, 2, 2b, 3, 6, 7, 8, 12.

## Step 4, secondary features

| Task | Owner | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T4.1 Extend activation | agent | AppFlow notification actions | `SelfExtend` / re-activate fallback, follow-up notification | Acceptance criterion 9 passes | T3.6, T3.9 |
| T4.2 Favorites | agent | AppFlow Favorites Window | Favorites Window CRUD + reorder, panel chips, run with one or zero sheet, `azurepim://activate?favorite=` | Acceptance criterion 10 passes | T3.6 |
| T4.3 History and pending requests | agent | BackendSchema ActivationRecord | ActivationRecord writes for every request, History Window table, pending fetch + cancel, CSV export, retention cleanup | Acceptance criterion 11 passes | T3.6 |
| T4.4 Multi-account polish | agent | AppFlow | Account switcher in panel header, per-account errors isolated, ordering | Two tenants side by side; one failing does not hide the other | T3.4 |
| T4.5 Activation timing | agent | PRD success metric | `panelOpenedAt` capture, `completedAt` on provisioned, median card in History Window | Acceptance criterion 13 passes | T4.3 |
| T4.6 Roles Window | agent | AppFlow | Table with search/filters, detail pane with policy and assignment path | All roles of 2 accounts searchable; policy shown | T3.3 |

**Checkpoint 4:** every P1 criterion (9–13) verified by hand; History shows median time-to-activation.

## Step 5, quality

| Task | Owner | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T5.1 Error handling | agent | AppFlow empty/blocked states | Offline, 429, 403, expired CLI, claims challenge — each mapped to its UI state | Each state reproduced and screenshotted | Step 4 |
| T5.2 Accessibility | agent | DesignBrief accessibility | VoiceOver labels, keyboard shortcuts, Reduce Motion | VoiceOver walkthrough of panel and sheet | Step 4 |
| T5.3 Security review | `security-reviewer` agent | TRD security | Review of token handling, logging privacy, `Process` usage, Hardened Runtime | No high/critical finding open | Step 4 |
| T5.4 Performance | agent | TRD targets | Instruments run: panel open, refresh, idle CPU/memory | Targets of TRD met | Step 4 |
| T5.5 Code review | `code-reviewer` agent | whole repo | Review pass separate from authoring | Findings fixed or tracked | T5.1–T5.4 |

**Checkpoint 5:** all 14 acceptance criteria pass; no open high-severity finding.

## Step 6, go-live

| Task | Owner | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T6.1 Test plan run | Vincent + agent | PRD acceptance criteria | Checklist filled on a clean Mac account (CLI only, MSAL only, both) | All criteria green | Step 5 |
| T6.2 Admin consent at Voltalia | Vincent → Voltalia Entra admin | `docs/admin-consent/email-voltalia-admin.md` | Consent granted (or Voltalia registration as fallback) | Entra roles load in Voltalia tenant | T1.5 |
| T6.3 Publisher verification | Vincent | MPN account | Verified publisher on the app registration | "Verified" badge on consent screen | T1.5 |
| T6.4 Release pipeline | agent | `macos-app-release` skill | `Scripts/release.sh`, `dmgbuild` layout, Sparkle appcast, GitHub release, README with screenshots | Notarization `Accepted` on this DMG, `stapler validate` and `spctl` pass | Step 5 |
| T6.5 Update test | agent | Sparkle | Install v1.0.0, publish v1.0.1, update end-to-end | Sparkle updates without manual action | T6.4 |
| T6.6 Rollback and monitoring | agent | — | Rollback = re-publish previous version in appcast; monitoring = GitHub issues template (no telemetry) | Documented in README | T6.4 |

**Checkpoint 6:** v1.0.0 public on GitHub, installed from the DMG on a second Mac, updated via Sparkle.

## Traceability

| Feature | Priority | Screens (AppFlow) | Entities (BackendSchema, or "—" if none stored) | Tasks |
|---|---|---|---|---|
| Role list and menu bar countdown | P0 | Menu Bar Panel, Roles Window | EligibleRole, ActiveAssignment, Account | T3.1, T3.2, T3.3, T3.4, T3.5, T4.6 |
| Activate and deactivate | P0 | Menu Bar Panel, Activation Sheet | EligibleRole, ActiveAssignment, ActivationRecord | T3.6, T3.7 |
| Dual sign-in | P0 | Onboarding, Accounts Settings | Account, AppSettings | T2.2, T2.3, T2.4, T2.5 |
| Entra roles and PIM groups | P0 | Menu Bar Panel, Roles Window, Accounts Settings | EligibleRole, ActiveAssignment, Account | T3.2, T3.3 |
| Expiry notification | P0 | Expiry Notification | ActiveAssignment, AppSettings | T3.9 |
| Admin consent helper | P0 | Admin Consent Sheet, Accounts Settings | Account | T3.8, T6.2 |
| Extend activation | P1 | Expiry Notification, Menu Bar Panel | ActiveAssignment, ActivationRecord | T4.1 |
| Favorites | P1 | Favorites Window, Menu Bar Panel | Favorite, EligibleRole | T4.2 |
| History and pending requests | P1 | History Window | ActivationRecord | T4.3 |
| Multi-account | P1 | Menu Bar Panel, Accounts Settings | Account | T4.4 |
| Activation timing | P1 | History Window | ActivationRecord | T4.5 |
