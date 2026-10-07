# Branching & Release Strategy

Meridian uses **trunk-based development with short-lived branches** — the right weight for a small team shipping a pre-1.0 app.

## Branches

| Branch | Purpose | Rules |
|--------|---------|-------|
| `main` | The trunk. Always buildable; every commit could become a release. | Never force-push. All work merges here. |
| `<type>/<topic>` | Short-lived work branches, e.g. `perf/ui-main-thread`, `fix/steam-auth-retry`, `feat/cloud-saves`. | Branch from `main`, merge back with `--no-ff` (or a PR), delete after merge. Days not weeks. |
| `archive/*` (tags) | Unmerged work worth keeping, e.g. `archive/main-pre-v0.9.12`. | Annotated tag with a reason. Replaces long-lived `backup/*` branches. Never deleted. |

Branch types mirror commit prefixes: `feat/`, `fix/`, `perf/`, `docs/`, `chore/`, `refactor/`, `test/`.

**When to branch vs. commit to `main`:** trivial, no-behavior-change work (docs, comments, `.gitignore`) may go straight to `main`. Everything else gets a `<type>/<topic>` branch and merges back `--no-ff` only once verified in Xcode. Merge commits carry a `STABLE:` line so `main`'s first-parent history reads as a list of revert points.

**Do NOT create version-named branches** (`v0.9.13`). Versions are tags, not branches — a branch named like a tag shadows it and confuses `git checkout`.

## Commits

Conventional-commit style, matching existing history:

```
perf(ui): move image decode off the main actor
fix(online): stop wiping localconfig.vdf
feat(friends): Discord-style friends panel
```

Types: `feat`, `fix`, `perf`, `docs`, `chore`, `refactor`, `test`. Scope is the module or feature area.

## Versioning (SemVer, pre-1.0)

App releases are **3-part tags**: `v0.MINOR.PATCH`.

- `v0.x.0` — feature releases (new capability, UI additions)
- `v0.x.y` — patch releases (fixes, perf work, no new features)
- **Drop the 4th component** — `v0.9.14.0` should have been `v0.9.14`. Next release after `v0.9.16.0` is `v0.9.17` (or `v0.10.0` if it ships features).
- `v1.0.0` when the app is ready for general users: stable bootstrap, reliable online + offline launch paths, no known data-loss bugs.

While pre-1.0, breaking/behavioral changes are allowed in minor bumps — that's what 0.x means.

### Engine tags (separate artifact line)

The Wine engine tarball has its own lifecycle and its own tag suffix: `vX.Y.Z-engine` (created by `Scripts/engine/publish-engine.sh`). This is intentional — engine versions move independently of app versions. Keep the `-engine` suffix; never tag an app release with it.

The engine **major** is a compatibility contract. Apps only install engines whose major matches `WineEngine.supportedEngineMajor`; bump the major (and that constant, in the same app release) whenever the engine layout changes in a way older apps can't drive. Publish the new-major engine before the app that requires it, or fresh installs of that app find no engine.

## Release flow

The Xcode project (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) is the single source of truth for the version; `Scripts/check-version.sh` enforces 3-part semver and that both build configurations agree (runs in CI on every push).

1. Land work on `main` via merged branches. Working tree must be clean.
2. `bash Scripts/release-app.sh --minor --tag-only` (or `--patch`, `--major`, or an explicit `1.2.0`). This bumps the project, commits `chore: release X.Y.Z`, tags `vX.Y.Z` and pushes.
3. The **Release** GitHub Actions workflow (`.github/workflows/release.yml`) picks up the tag: verifies tag == project version, archives with the Developer ID certificate, notarizes and staples the app and DMG, and publishes the GitHub release with the DMG + SHA-256. It refuses to run unsigned.
4. `AppUpdateChecker` in installed copies sees the new release and offers the in-app update.

One-time setup for the workflow (repository secrets): `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` (a "Developer ID Application" certificate exported from Keychain Access), and `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_BASE64` (an App Store Connect API key with Developer access). Never tag without going through step 2 — a tag with no matching bump fails the workflow, and a tag with no release leaves users stranded on the previous version.

Running `release-app.sh` without `--tag-only` still builds locally (needs the cert + `meridian-notarize` keychain profile on your Mac) and creates a *draft* release you must publish by hand. Engine releases go through `Scripts/engine/publish-engine.sh` independently.

## Repo hygiene

GitHub holds `main`, branches for work genuinely in progress, and tags. Nothing else. Merged branches are deleted locally and on origin immediately. Unmerged work being set aside is preserved as an `archive/*` tag, then deleted. Release and archive tags are never deleted or moved.

## Issuing license keys

Keys are Ed25519-signed tokens of the form `MRDN1.<payload>.<signature>`, verified offline against the public key embedded in `LicenseManager.publicKeyBase64`.

```bash
swift Scripts/license-keygen.swift gen                                  # once: create the signing keypair
swift Scripts/license-keygen.swift sign --email buyer@example.com       # per sale (optional --exp yyyy-mm-dd)
swift Scripts/license-keygen.swift verify MRDN1...                      # sanity-check a key
```

The private key lives at `~/.config/meridian/license-signing.key` on the maintainer's machine. Back it up: a new keypair invalidates every issued key unless the old public key is also kept in the app. `sign` is meant to be called from the payment provider's post-purchase webhook (Paddle, Lemon Squeezy and Gumroad all work). `LicenseManager.purchaseURL` is the "Buy Meridian" target.

## Engine provenance

The engine is built from source on an Apple Silicon Mac by `Scripts/engine/` — no CrossOver install is involved:

| Step | Script | What it does |
|---|---|---|
| 1 | `build-deps.sh` | Cross-compiles the x86_64 libraries Wine loads (gmp, nettle, GnuTLS, freetype, SDL2, GLib, GStreamer) and fetches MoltenVK from Khronos |
| 2 | `build-wine.sh` | Builds Wine 11.0 from CodeWeavers' published CrossOver source (LGPL), with WoW64 for 32-bit games |
| 3 | `package-engine.sh` | Adds DXMT, Meridian's helpers and DepotDownloader; relinks, strips, signs; builds the prefix template; writes license texts |
| 4 | `smoke/smoke-test.sh` | Headless D3D11 (DXMT and wined3d, 32/64-bit), swap-chain presentation, and HTTPS through Wine |
| 5 | `publish-engine.sh` | Runs 1–4, then creates the `vX.Y.Z-engine` GitHub release |

```bash
brew install meson ninja cmake bison flex autoconf automake libtool mingw-w64 coreutils gh
bash Scripts/engine/publish-engine.sh v4.0.1-engine --no-upload   # build + test only
bash Scripts/engine/publish-engine.sh v4.0.1-engine               # build, test, publish
```

Builds happen in `~/meridian-engine-build` (outside Dropbox). Library builds are stamped, so reruns are incremental.

**Renderer selection.** Wine searches its own `lib/wine` before any `WINEDLLPATH` entry, so the D3D front-ends Meridian switches between (`d3d11`, `dxgi`, `d3d10core`, `d3d12`, `d3d12core`) are kept out of it, in one directory per implementation (`lib/dxmt`, `lib/wined3d`). `WineEngine.dllSearchPath(preferring:)` puts the chosen one first. CrossOver does the same job with its closed-source `cxcompatdb.so`, which Meridian does not ship.

**Not in the engine:** Apple's D3DMetal, `cxcompatdb.so`, the gbe_fork Steamworks emulator, and any Valve binary. Steamworks games run through the real Steam client; the client and its current `steam.exe` come from Valve's CDN at first use.

## Release readiness

What still has to happen before Meridian can be sold as a 1.0:

1. ~~**Engine from source.**~~ Done: `Scripts/engine/` (see Engine provenance). Still to do: run it in CI so engine releases are reproducible, and publish the DepotDownloader fork source (GPL-2.0) with each engine release.
2. **Direct3D 12.** The shipped engine has no D3D12 → Metal path (D3DMetal is not redistributable without an agreement with Apple; vkd3d on MoltenVK does not work). Options: leave DX12 games unsupported for 1.0 and say so in the compatibility rating, the Whisky model (user imports Apple's Game Porting Toolkit; `WineEngine` already routes to `lib/gptk` when present), or a redistribution agreement.
3. ~~**gbe_fork.**~~ Done: not shipped; Steamworks games launch through the real Steam client.
4. **Publish engine v4 and the app together.** v0.11.1 and earlier install any `-engine` release and cannot drive the v4 layout, so publish `v4.0.0-engine` immediately before the first app release that has `supportedEngineMajor = 4`.
5. **Configure the Release workflow secrets** (see Release flow above) so tags produce signed, notarized DMGs. Tags `v0.9.8` through `v0.11.1` exist without artifacts; installed apps currently see `v0.9.7.1` as latest until a release is published.
6. **Legal copy.** EULA, privacy policy (Steam credentials are entered into the app; the refresh token is stored DPAPI-encrypted in the prefix), support contact. Prefer Steam QR / mobile-confirm login so no password ever passes through Meridian.
7. **Legal review** of the engine's LGPL compliance (license texts ship in `licenses/`; source is CodeWeavers' public tarball plus `Scripts/engine/`) and of using a third-party client against Steam's Subscriber Agreement.

