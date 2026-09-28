# Meridian — Agent Instructions

Shared agent rules (hard rules, self-review, wrap-up/branch protocol) live in `AGENTS.md` at the repo root — read it first.

Meridian is a native Swift 6 / SwiftUI macOS app (macOS 15+) that plays PC (Steam) games on Mac via CrossOver/Wine technology. Zero external SPM dependencies; StrictConcurrency enabled.

## Architecture Map

| Module | Purpose |
|--------|---------|
| `Meridian/App/` | Entry point (`MeridianApp` @main), `AppDelegate` (window sizing: splash 480×300 → full 1030×625), `BootstrapManager` (init pipeline: engine → prefix → Steam) |
| `Meridian/Engine/` | `WineEngine` (runtime detection), `WinePrefix` (bottle lifecycle), `SteamClientBootstrap`, `GameCompatibilityDB` (per-game fixes), `GameProfile`, `GameStackResolver` |
| `Meridian/Launch/` | `Launcher` (launch orchestration: offline gbe_fork emulator vs online steam.exe `-applaunch`), `DepotDownloaderInstall` (native arm64 DepotDownloader fork, NDJSON progress) |
| `Meridian/Steam/` | `SteamSession` (steam.exe lifecycle, local.vdf JWT), `SteamCredentialAuth` (RSA + Steam Guard), `SteamLibraryStore` (game list + install-state polling), `SteamAPIService`, `SteamAppInfoResolver` (PICS via DepotDownloader `-appinfo`), `SteamWindow` (Wine window suppression) |
| `Meridian/Models/` | `Game`, `AppSettings` (@Observable UserDefaults-backed singleton), `CategoryStore`, `GameArtOverrides` |
| `Meridian/Views/` | SwiftUI UI: `ContentView` (detail column is a ZStack "stage": root page always mounted + `GameDetailView` zoomed in over it — no NavigationStack push), `HomeView` (`HeroCarousel` pager), `Library/` (grid, detail, `DetailTransition` zoom model/modifiers, `DetailZoomTuning` live-tuning window ⌥⌘Z, `CachedAsyncImage` + `ImageCache`), `Auth/`, `Friends/`, `Settings/`, `Downloads/` |
| `Meridian/Utilities/` | `MeridianLog` (os.log + disk file at `~/Library/Application Support/com.meridian.app/logs/meridian.log`) |

Runtime data lives under `~/Library/Application Support/com.meridian.app/` (engine/, bottles/steam/, logs/). Image cache: `~/Library/Caches/com.meridian.app/images/`.

## State & Concurrency Conventions

- Use the **Observation framework** (`@Observable`, `@MainActor` final classes), NOT Combine/ObservableObject. Wire via `.environment(obj)` / `@Environment(Type.self)`.
- Services model state as `Equatable` enums with `.failed(String)` cases (e.g. `Launcher`, `SteamSession`, `BootstrapManager.Phase`). Views observe the enum and surface failures; never crash on process errors — log and continue.
- All state objects are created as `@State` in `MeridianApp` and wired manually in its `body` (e.g. `launcher.steamWindow = steamWindow`).
- Mark non-observed stored properties `@ObservationIgnored`. Structs crossing actor boundaries are `Sendable`.
- Logging: `private let log = MeridianLog(category: "TypeName")`, then `log.info/warning/error`.
- Organize files with `// MARK: -` sections. Prefer computed properties for derived state.

## Build & Test

**Agents never build or run the app** — the user builds in Xcode (see `AGENTS.md` hard rules and `.cursor/rules/xcode-build-only.mdc`). Run `swift test` only when asked, with:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer  # CLT lacks macro plugins + XCTest
swift test --build-system native    # default swiftbuild backend fails codesign on the resource bundle (Dropbox xattrs)
```
Xcode project (`Meridian.xcodeproj`) is for signing/entitlements/IDE. Many tests are **contract tests** that grep source files for expected patterns — if you rename APIs or change key strings (timer intervals, stage names), check MeridianTests/ for assertions on source text.

`Scripts/` builds external artifacts (Wine engine tarball, DepotDownloader fork, dylibs) — do not touch unless working on engine packaging.

## Hard Rules

- **UI is pixel-perfect by design.** Never change visual appearance (layout, colors, spacing, animation curves users can see) when fixing performance or refactoring. Performance fixes must be visually invisible.
- Performance work: see `.github/instructions/swiftui-performance.instructions.md` and track all changes in `docs/PERFORMANCE-IMPROVEMENTS.md`.
- Don't add SPM dependencies — the app is intentionally dependency-free.
- Don't block the main actor with disk I/O, image decoding, or process spawning; hop off with `Task.detached` or nonisolated async functions.
- Card↔detail zoom rules: the root page must never be transformed (dim/alpha only); blur bleeds and AppKit-backed views (`ProgressView`) inside `GameDetailView` mount only after landing (`showsAmbient`); pages must not set `.navigationTitle` (ContentView owns it); the page's `.onAppear` stays INSIDE `.id(game.id)`. Motion constants live in `DetailZoomParameters` — tune via the window, then paste the literal back as defaults.
- Steam auth uses JWT refresh tokens (never store passwords). Token lives DPAPI-encrypted in the Wine prefix's `local.vdf`.
