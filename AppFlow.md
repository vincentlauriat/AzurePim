# AzurePim — App flow

## Entry points

- **Menu bar icon** (main entry, always present while the app runs; launch at login on by default).
- **Main window** — from the panel ("Open AzurePim…"), the Dock icon when visible, or `⌘0` in the panel.
- **Notification** — expiry or request-status notification; clicking opens the Menu Bar Panel on that role.
- **URL scheme** `azurepim://` — `azurepim://activate?favorite=<name>` (for Shortcuts / Raycast), `azurepim://open`.
- **First launch** after installing the DMG → Onboarding.

## Screen list

| Screen | Purpose | Data needed |
|---|---|---|
| Onboarding | Choose sign-in mode, grant notifications, launch-at-login | Detected `az` path and `az account show`, notification permission status |
| Menu Bar Panel | Daily view: active roles with countdown, eligible roles, favorites, quick actions | ActiveAssignment, EligibleRole, Favorite, Account (cached), last refresh time |
| Activation Sheet | Choose duration, justification, ticket; send activation | EligibleRole, its policy (max duration, ticket/justification/MFA/approval required), last justification |
| Roles Window | Full list with search and filters (source, account, state), details and policy of each role | EligibleRole, ActiveAssignment, Account |
| History Window | Past requests, pending approvals, median time-to-activation | ActivationRecord, pending requests from Azure/Graph |
| Favorites Window | Create, edit, order, delete favorites | Favorite, EligibleRole |
| Accounts Settings | Add/remove accounts, sign-in mode per account, consent status, custom client id, refresh and notification settings | Account, AppSettings |
| Admin Consent Sheet | Explain missing consent, copy consent link, prepare email | Account (tenant id, domain), required scopes list |
| Expiry Notification | System notification before expiry, with actions | ActiveAssignment, AppSettings (lead time) |

## Main path

`Menu Bar Panel -> click "Activate" on an eligible role -> Activation Sheet -> press Activate -> Menu Bar Panel (role in "Active" with countdown) -> Expiry Notification 15 min before end -> Extend or Dismiss`

## Alternative paths

- **Favorite:** `Menu Bar Panel -> click favorite -> (no sheet if every role has a saved default duration and justification and no ticket required; otherwise one Activation Sheet listing all roles) -> roles Active`.
- **Cancel:** Activation Sheet → Esc / Cancel → Menu Bar Panel, nothing sent.
- **Deactivate:** Menu Bar Panel → hover active role → Deactivate → confirm popover → role back to Eligible.
- **Approval required:** Activate → status *Pending approval* → role shows a clock badge → History Window lists it → notification when it becomes Active or is denied.
- **MFA required:** Activate → claims challenge → MSAL browser sign-in → automatic retry; CLI mode → sheet with the `az login` command to copy, then Retry.
- **Missing consent:** Roles Window / Menu Bar Panel Entra section → "Admin consent required" → Admin Consent Sheet.
- **Back:** the main window uses a sidebar (Roles, History, Favorites); Settings is a separate window (`⌘,`).

## Action details

### Menu Bar Panel

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Open panel | Click menu bar icon | — | Cached list instantly, spinner in header if refresh running | Fresh list, "Updated just now" | Header banner "Couldn't refresh – <reason>" + Retry | — |
| Activate | "Activate" button on eligible row | Role eligible, account token available | — | — | Token unavailable → sign-in prompt | Activation Sheet |
| Quick activate | ⌥-click "Activate" | Saved defaults exist and policy needs no ticket | Row spinner | Row moves to Active | Inline error under row | Menu Bar Panel |
| Deactivate | "Deactivate" on active row + confirm | Activation older than 5 min (Azure minimum) — otherwise button disabled with tooltip | Row spinner | Row back to Eligible | Inline error | Menu Bar Panel |
| Run favorite | Click favorite chip | At least one role still eligible | Chip spinner | Toast "2 of 2 activated" | Toast lists failures per role | Menu Bar Panel |
| Refresh | ⌘R or header button | — | Header spinner | Timestamp updated | Banner | — |
| Open main window | "Open AzurePim…" / ⌘0 | — | — | — | — | Roles Window |

### Activation Sheet

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Choose duration | Stepper / presets (1 h, 2 h, 4 h, 8 h, Max) | ≤ policy maximum | — | — | — | — |
| Type justification | Text field (prefilled with last one for this role) | Required if policy says so; 1–500 chars | — | — | Inline "Required by policy" | — |
| Type ticket | Ticket number + system fields (shown only if policy requires) | Non-empty when required | — | — | Inline | — |
| Activate | Return / button | All above | Button spinner, sheet stays | Sheet closes, role Active (or Pending approval) | Error text in sheet with Azure/Graph message; Retry | Menu Bar Panel |
| Cancel | Esc | — | — | — | — | Menu Bar Panel |

### Roles Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Search / filter | Search field, source and account filters | — | — | Filtered list | — | — |
| Show details | Select row | — | Policy loaded lazily | Detail pane: scope path, policy, via group, end time | "Policy unavailable" | — |
| Activate / Deactivate | Buttons in detail pane | Same as panel | Same | Same | Same | Activation Sheet |
| Add to favorite | Context menu | — | — | — | — | Favorites Window |

### History Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| View history | Sidebar "History" | — | Local records instantly, pending requests fetched | List with status, duration, time-to-activation | Banner if pending fetch fails | — |
| Cancel pending request | "Cancel request" on pending row | Status PendingApproval | Row spinner | Status Canceled | Inline error | — |
| Export | "Export CSV…" | — | — | Save panel, file written | Alert | — |

### Favorites Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Create favorite | "+" | Name 1–40 chars, unique; ≥ 1 role | — | Favorite listed, chip in panel | Inline | — |
| Edit / reorder / delete | Select, drag, ⌫ | Delete asks confirmation | — | Saved immediately | — | — |

### Accounts Settings

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Add account (CLI) | "Add → Azure CLI session" | `az` found, `az account show` succeeds | Spinner | Account listed with tenant | "Run `az login` first" + copy button | — |
| Add account (Microsoft) | "Add → Sign in with Microsoft" | — | Browser sign-in | Account listed | Sign-in error text | — |
| Grant directory access | "Enable Entra roles" | MSAL account | Incremental consent in browser | Status "Entra roles: enabled" | 403 consent → Admin Consent Sheet | Admin Consent Sheet |
| Remove account | "−" + confirm | — | — | Account, cache and its favorites' roles removed | — | — |
| Change settings | Toggles / steppers | Lead time 5–60 min, refresh 1–30 min, retention 7–365 days | — | Saved | — | — |

### Admin Consent Sheet

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Copy consent link | Button | Tenant id known | — | Link in clipboard, toast | — | — |
| Prepare email | Button | — | — | Mail draft opened via `mailto:` with subject, body and link (English or French template) | — | — |
| Check again | Button | — | Spinner | "Consent granted" → Entra roles load | Still 403 | Menu Bar Panel |

### Expiry Notification

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Extend | Notification action | Re-activate with the last duration and justification (deactivate first if Azure says the role is still active); refused if the policy needs approval, a ticket or MFA (PRD open question 11) | Background request | Follow-up notification "Extended until 18:40" or "Pending approval" | Notification with error, opens panel on click | — |
| Dismiss | Notification action | — | — | — | — | — |
| Open | Click body | — | — | — | — | Menu Bar Panel |

## Navigation rules

- Menu bar panel closes on outside click, stays open while the Activation Sheet is shown.
- Main window: `NavigationSplitView` sidebar — Roles (⌘1), History (⌘2), Favorites (⌘3). Settings in its own window (⌘,).
- Closing the main window hides the Dock icon; the app keeps running in the menu bar. Quit only from the panel menu (⌘Q).
- Deep links: `azurepim://open`, `azurepim://activate?favorite=<name>`, `azurepim://role?id=<eligibilityScheduleId>`. Running a favorite from a link always asks for confirmation (PRD open question 12).

## Empty and blocked states

| State | Where | What the user sees |
|---|---|---|
| No account | Panel, Roles Window | "Add an account to get started" + buttons Use Azure CLI session / Sign in with Microsoft |
| No eligible role | Panel | "No eligible PIM role for <account>" + link "What is PIM?" |
| `az` not found | Onboarding, Accounts Settings | "Azure CLI not found" + Choose… (file picker) + Install link |
| CLI session expired | Panel banner | "Azure CLI session expired — run `az login`" + Copy command |
| Consent missing | Entra section | "Admin consent required" → Admin Consent Sheet |
| Permission denied (403 not consent) | Row | "Not allowed by your tenant policy" with Azure message |
| Offline | Panel header | "Offline — showing data from 10:42"; actions disabled |
| Throttled (429) | Banner | "Microsoft is throttling requests — retrying in 30 s" |

## First use

1. Onboarding page 1 — what AzurePim does, privacy promise (no server, no telemetry).
2. Page 2 — sign-in: if `az` is detected and signed in, preselect "Use Azure CLI session (detected: <user>, <tenant>)"; second option "Sign in with Microsoft".
3. Page 3 — allow notifications, launch at login (both on by default, can be skipped).
4. Done → Menu Bar Panel opens attached to the icon, roles loading.
