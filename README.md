# AzurePim

Free macOS menu bar and desktop app to see, activate, extend and end your own Microsoft PIM roles — Azure resource
roles, Entra roles and PIM groups — in any tenant, without opening the portal.

Status: **Step 1 — project setup** (app shell, no PIM feature yet).

## Build

Requirements: Xcode (stable), macOS 14+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), SwiftLint.

```bash
xcodegen generate                       # AzurePim.xcodeproj is generated, not committed
swift test --package-path Packages/AzurePimCore
xcodebuild -project AzurePim.xcodeproj -scheme AzurePim -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
open build/DerivedData/Build/Products/Debug/AzurePim.app
```

## Project layout

| Path | Content |
|---|---|
| `AzurePim/` | SwiftUI app: menu bar panel, main window, settings |
| `Packages/AzurePimCore/` | UI-free logic (token providers, ARM/Graph clients — from Step 2) |
| `Scripts/` | Icon generator (release pipeline in Step 6) |
| `project.yml` | XcodeGen spec (MSAL, Sparkle via SPM) |

| Document | Content |
|---|---|
| [PRD.md](PRD.md) | Product, features, acceptance criteria, open questions |
| [TRD.md](TRD.md) | Technical choices, APIs, scopes, architecture |
| [AppFlow.md](AppFlow.md) | Screens, paths, states |
| [DesignBrief.md](DesignBrief.md) | Visual direction and UX rules |
| [BackendSchema.md](BackendSchema.md) | Local data model |
| [ImplementationPlan.md](ImplementationPlan.md) | Build order and traceability |
| [docs/admin-consent/](docs/admin-consent/) | Admin consent emails |

License: [MIT](LICENSE).
