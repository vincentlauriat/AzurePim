# AzurePim — UI/UX design brief

## Audience and tone

Cloud and identity administrators who live in the terminal and the Azure portal, and want PIM to stay out of their way.
Three adjectives: **native, dense, discreet**. AzurePim should feel like a macOS system utility: you glance at it,
act in one or two clicks, and forget it. Security state must be readable in under a second.

## Reference products

| Product | Borrow | Avoid |
|---|---|---|
| **iStat Menus** | Compact, information-rich menu bar item; dense yet tidy dropdown with sections and fixed-width numbers; per-item customization of the menu bar label | Overwhelming number of options in v1 |
| **Juicy** | Minimal menu bar presence, one clear status, friendly notifications at the right moment | Playful tone that would undermine the "security tool" feel |
| macOS Control Center / Wi-Fi menu | Native `MenuBarExtra` materials, rows with toggles, section headers | — |
| Azure portal PIM blade | Vocabulary (Eligible, Active, Justification, Ticket) so admins feel at home | Long forms, 6-click paths, full-page reloads |

## Color palette

System colors only, so light/dark mode and accent color follow the user's settings. Hex values are the macOS defaults, for reference *(assumption)*.

| Role | SwiftUI | Light | Dark | Use |
|---|---|---|---|---|
| Primary / accent | `Color.accentColor` | `#007AFF` | `#0A84FF` | Activate button, selection |
| Background (panel) | `.regularMaterial` | — | — | Menu Bar Panel |
| Background (window) | `Color(nsColor: .windowBackgroundColor)` | `#ECECEC` | `#1E1E1E` | Main window |
| Text primary | `.primary` | `#000000` (85 %) | `#FFFFFF` (85 %) | Role names |
| Text secondary | `.secondary` | `#3C3C43` (60 %) | `#EBEBF5` (60 %) | Scopes, account names |
| Success — Active | `.green` | `#34C759` | `#30D158` | Active badge, countdown > 15 min |
| Warning — expiring / pending | `.orange` | `#FF9500` | `#FF9F0A` | Countdown ≤ 15 min, Pending approval |
| Error | `.red` | `#FF3B30` | `#FF453A` | Failed request, countdown ≤ 5 min |
| Info | `.blue` | `#007AFF` | `#0A84FF` | Consent required, tips |

Color is never the only signal: every status also has an SF Symbol and a word.

## Typography

San Francisco (system font) only.

| Use | Style | Size (pt) | Weight |
|---|---|---|---|
| Menu bar label | `.monospacedDigit()` system | 13 | Medium |
| Panel section header | `.caption` uppercase | 11 | Semibold, secondary |
| Role name | `.body` | 13 | Regular |
| Scope / account | `.caption` | 11 | Regular, secondary |
| Countdown in rows | `.callout.monospacedDigit()` | 12 | Medium |
| Window titles | `.title2` | 17 | Semibold |
| Sheet title | `.headline` | 13 | Semibold |

## Components

- **Menu bar label:** SF Symbol `key.fill` when no role active; `key.horizontal.fill` + count + next expiry (`2 · 1:42`) when active; label turns orange at ≤ 15 min, red at ≤ 5 min; symbol `clock.badge` overlay when a request is pending. User can choose "icon only" / "icon + count" / "icon + count + time" in Settings.
- **Role row (36 pt high):** leading source icon (`cloud` Azure resource, `person.badge.key` Entra role, `person.3` PIM group), role name, scope on second line (truncated in the middle), trailing status: countdown + Deactivate (hover) for active rows, Activate button for eligible rows.
- **Buttons:** `.borderedProminent` for Activate in the sheet; `.bordered` small for row actions; destructive confirm via popover, never a modal alert.
- **Favorite chips:** capsule, `.bordered`, max 4 visible in the panel, then "More…".
- **Sheets:** width 420 pt, form layout (`Form` `.grouped`), primary button on the right, Return = Activate, Esc = Cancel.
- **Banners:** in-panel, 1 line, icon + text + action, dismissible; no modal alerts except for deleting data.
- **Notifications:** title = role + scope, body = "Expires at 18:40 (15 min)", actions Extend / Dismiss.

## Layout rules

- **Menu Bar Panel:** width 360 pt, max height 560 pt then scroll; sections in order: header (account switcher, refresh, timestamp), Active, Favorites, Eligible (grouped by account then source), footer (Open AzurePim…, Settings, Quit).
- **Main window:** `NavigationSplitView`, sidebar 180 pt, list column min 320 pt, detail min 360 pt; default size 980 × 640 pt, min 760 × 480 pt.
- **Spacing scale:** 4 / 8 / 12 / 16 / 24 pt; row padding 8 pt horizontal, 6 pt vertical; section spacing 12 pt.
- No responsive breakpoints (desktop only); content adapts to window width via the split view.

## Per-screen notes

| Screen | Key content and hierarchy |
|---|---|
| Onboarding | 3 pages, 520 × 420 pt; big SF Symbol, one sentence, one primary button; privacy promise visible on page 1 |
| Menu Bar Panel | Active roles first (what matters now), then favorites, then eligible; empty Active section collapses to one line "No active role" |
| Activation Sheet | Role + scope on top; duration presets as segmented control; justification field focused; policy hints in secondary text ("Max 8 h · Ticket required · Approval required") |
| Roles Window | Table with columns Role, Scope, Source, Account, Status, Ends; detail pane with policy and assignment path ("via group SG-…") |
| History Window | Table: Time, Role, Scope, Action, Status, Duration, Time-to-activation; header card with median time-to-activation and count, last 30 days |
| Favorites Window | List of favorites left, roles of the selected favorite right with default duration and justification per role |
| Accounts Settings | One row per account: avatar initials, UPN, tenant name, mode badge (CLI / Microsoft), Entra status (enabled / consent required / n/a) |
| Admin Consent Sheet | Why (one paragraph), list of permissions with one-line purpose, consent link (selectable), buttons Copy link / Prepare email / Check again |
| Expiry Notification | Standard macOS banner; no custom UI |

## Accessibility

- WCAG AA contrast is met by system colors; never rely on color alone (symbol + text on every status).
- Full keyboard navigation: ↑/↓ rows, Return activates, ⌫ deactivates (with confirmation), ⌘R refresh, ⌘0 main window, ⌘1–3 sidebar.
- VoiceOver labels on every row: "Reader, Tenant Root Group, Azure resource, active, expires in 1 hour 42 minutes".
- Click targets ≥ 24 × 24 pt (macOS pointer), row height 36 pt; honour Reduce Motion and Increase Contrast.
- Countdown announcements throttled (no VoiceOver spam every second).

## Interaction states

| State | Rule |
|---|---|
| Hover | Row background `.quaternary`; row actions (Deactivate, …) appear on hover and on keyboard focus |
| Focus | System focus ring |
| Disabled | 40 % opacity + tooltip explaining why (e.g. "Can't deactivate within 5 minutes of activation") |
| Loading | Inline `ProgressView` (small) in the row or button; never block the whole panel |
| Error | Red symbol `exclamationmark.triangle.fill` + message under the row; full message in tooltip / detail pane |
| Success | Row animates to Active section (0.2 s, disabled with Reduce Motion) + light haptic-free sound off by default |
| Pending approval | Orange `clock` badge, text "Pending approval" |

## Required assets

- **App icon:** a key over a shield, macOS 14 icon grid, light/dark variants *(assumption — to design)*.
- **Menu bar icons:** SF Symbols (`key.fill`, `key.horizontal.fill`, `clock.badge`); no custom template image needed in v1.
- **Source icons:** SF Symbols `cloud`, `person.badge.key`, `person.3`.
- **Screenshots** for README / GitHub release: panel light and dark, Activation Sheet, Roles Window, History Window.
- No illustrations.
