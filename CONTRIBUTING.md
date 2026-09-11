# Branching & Release Strategy

Meridian uses **trunk-based development with short-lived branches** — the right weight for a small team shipping a pre-1.0 app.

## Branches

| Branch | Purpose | Rules |
|--------|---------|-------|
| `main` | The trunk. Always buildable; every commit could become a release. | Never force-push. All work merges here. |
| `<type>/<topic>` | Short-lived work branches, e.g. `perf/ui-main-thread`, `fix/steam-auth-retry`, `feat/cloud-saves`. | Branch from `main`, merge back with `--no-ff` (or a PR), delete after merge. Days not weeks. |
| `backup/*` | Ad-hoc safety snapshots before risky operations. | Fine to keep locally; prune when stale. |

Branch types mirror commit prefixes: `feat/`, `fix/`, `perf/`, `docs/`, `chore/`, `refactor/`.

**Do NOT create version-named branches** (`v0.9.13`). Versions are tags, not branches — a branch named like a tag shadows it and confuses `git checkout`. (Legacy `v0.9.13` / `v0.9.14.0` branches predate this doc and can be deleted; the tags preserve those points.)

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

The Wine engine tarball has its own lifecycle and its own tag suffix: `vX.Y.Z-engine` (created by `Scripts/release-engine.sh`). This is intentional — engine versions move independently of app versions. Keep the `-engine` suffix; never tag an app release with it.

## Release flow

The Xcode project (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) is the single source of truth for the version; `Scripts/check-version.sh` enforces 3-part semver and that both build configurations agree (runs in CI on every push).

1. Land work on `main` via merged branches. Working tree must be clean.
2. `bash Scripts/release-app.sh --minor --tag-only` (or `--patch`, `--major`, or an explicit `1.2.0`). This bumps the project, commits `chore: release X.Y.Z`, tags `vX.Y.Z` and pushes.
3. The **Release** GitHub Actions workflow (`.github/workflows/release.yml`) picks up the tag: verifies tag == project version, archives with the Developer ID certificate, notarizes and staples the app and DMG, and publishes the GitHub release with the DMG + SHA-256. It refuses to run unsigned.
4. `AppUpdateChecker` in installed copies sees the new release and offers the in-app update.

One-time setup for the workflow (repository secrets): `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` (a "Developer ID Application" certificate exported from Keychain Access), and `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_BASE64` (an App Store Connect API key with Developer access). Never tag without going through step 2 — a tag with no matching bump fails the workflow, and a tag with no release leaves users stranded on the previous version.

Running `release-app.sh` without `--tag-only` still builds locally (needs the cert + `meridian-notarize` keychain profile on your Mac) and creates a *draft* release you must publish by hand. Engine releases go through `Scripts/release-engine.sh` independently.

## One-time cleanup (recommended)

```bash
# Version-named branches duplicate their tags — safe to delete (tags remain):
git push origin --delete v0.9.13 v0.9.14.0
git branch -d v0.9.13 v0.9.14.0
```

## Issuing license keys

Keys are Ed25519-signed tokens of the form `MRDN1.<payload>.<signature>`, verified offline against the public key embedded in `LicenseManager.publicKeyBase64`.

```bash
swift Scripts/license-keygen.swift gen                                  # once: create the signing keypair
swift Scripts/license-keygen.swift sign --email buyer@example.com       # per sale (optional --exp yyyy-mm-dd)
swift Scripts/license-keygen.swift verify MRDN1...                      # sanity-check a key
```

The private key lives at `~/.config/meridian/license-signing.key` on the maintainer's machine. Back it up: a new keypair invalidates every issued key unless the old public key is also kept in the app. `sign` is meant to be called from the payment provider's post-purchase webhook (Paddle, Lemon Squeezy and Gumroad all work). `LicenseManager.purchaseURL` is the "Buy Meridian" target.

## Engine provenance

`Scripts/release-engine.sh` currently packages pre-built binaries from an installed CrossOver Preview (`/Applications/CrossOver Preview.app`): wineloader/wineserver, `lib/wine`, DXMT, DXVK, MoltenVK/GnuTLS/GStreamer dylibs, and Apple's D3DMetal. End users never install CrossOver; they only download the resulting tarball. This is a development convenience, not a from-source build, and it must be replaced before a paid release (see below).

## Release readiness

What still has to happen before Meridian can be sold as a 1.0:

1. **Engine from source.** Replace the CrossOver harvest in `release-engine.sh` with a reproducible build: CodeWeavers' LGPL Wine source for macOS arm64, plus DXMT, DXVK, MoltenVK, GnuTLS and GStreamer from upstream. Ship license texts and an SBOM inside the tarball. Drop `cxcompatdb.so` (CrossOver-specific; only used for the D3DMetal D3D11 video path).
2. **D3DMetal.** It is not part of macOS; it ships only inside Apple's Game Porting Toolkit (developer-login download, evaluation terms) and inside CrossOver under CodeWeavers' own arrangement with Apple. The copy currently staged is `com.apple.D3DMetal 4.0b1` from CrossOver Preview. Options for 1.0: drop Direct3D 12 support (DXMT + DXVK only), the Whisky model (user downloads GPTK with their own Apple developer account and Meridian imports it), or a redistribution agreement with Apple. Do not ship it in the tarball without one of those.
3. **Stop staging gbe_fork** (`build-steamemu.sh` step in `release-engine.sh`). The Local launch mode that uses it is already gated behind the `localLaunchMode` feature flag and is dev-only; release users get Online play through the real Steam client.
4. **Publish the DepotDownloader fork source** (GPL-2.0) alongside each engine release.
5. **Configure the Release workflow secrets** (see Release flow above) so tags produce signed, notarized DMGs. Tags `v0.9.8` through `v0.11.1` exist without artifacts; installed apps currently see `v0.9.7.1` as latest until a release is published.
6. **Legal copy.** EULA, privacy policy (Steam credentials are entered into the app; the refresh token is stored DPAPI-encrypted in the prefix), support contact. Prefer Steam QR / mobile-confirm login so no password ever passes through Meridian.
7. **Legal review** of items 1 to 3 and of using a third-party client against Steam's Subscriber Agreement.

