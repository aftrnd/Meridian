# Steam `steam.exe -login` session persistence (April 2026)

This document records the **root cause**, **code changes**, **user-verified results**, and **open items** for the fix where Meridian drives `steam.exe -silent -login USER PASS` (see `Meridian/Steam/SteamExeSignIn.swift`) and must persist Steam’s on-disk `local.vdf` before later flows (`installGame`, bootstrap `waitUntilReady`) can succeed.

**Scope:** This write-up covers the **uncommitted / follow-up** work committed alongside app version **0.9.11** (see `Meridian.xcodeproj/project.pbxproj`). It does **not** change the Wine engine tarball or `Scripts/release-engine.sh`. Pair this app with whatever engine tag is already installed (Settings → Updates shows **Installed engine**; the on-disk source of truth is `~/Library/Application Support/com.meridian.app/engine/wine/meridian-engine-version.txt` after download). A typical public pairing at the time of this doc is **v3.0.6-engine** (or newer) on GitHub Releases—**verify on your machine** rather than assuming a tag from this file alone.

---

## Architecture context (unchanged by this fix)

- **Auth path:** `SteamExeSignIn` runs `steam.exe` with `-login` so Steam performs CM auth with its own `machine_id` (Wine/WMI) and writes **`local.vdf`** (DPAPI) itself. No JWT injection from Meridian.
- **Self-managed flag:** `AppSettings.steamSelfManagedSession` (see `Meridian/Models/AppSettings.swift`) is set to `true` in `AuthView` after a successful `SteamExeSignIn` flow (`Meridian/Views/Auth/AuthView.swift`).
- **Bootstrap:** `SteamSessionBridge.prepare(prefix:engine:)` (`Meridian/Steam/SteamSessionBridge.swift`) chooses strategy 1 when `steamSelfManagedSession` is set: refresh `loginusers.vdf` if needed, otherwise leave Steam’s files alone.
- **Install / DRM:** `WineSteamManager` stops and restarts persistent `steam.exe` for installs; readiness is gated on **`waitUntilReady`** (logs show `[Logged On,`).

---

## Root cause

### 1. Delayed `local.vdf` flush vs `[Logged On,` log line

Steam may print `[Logged On, …]` in `connection_log.txt` **before** the client has flushed a **plausible** `local.vdf` to  
`<prefix>/drive_c/users/crossover/AppData/Local/Steam/local.vdf`.

If Meridian treated “logged on in logs” as “session on disk,” the next step could see **no** or a **too-small** `local.vdf`.

### 2. Race with `AuthView` → `backupSteamSession()`

On success, `AuthView` calls `prefix.backupSteamSession()` (`Meridian/Views/Auth/AuthView.swift`).  
`WinePrefix.backupSteamSession()` (`Meridian/Engine/WinePrefix.swift`) **no-ops** if `local.vdf` does not exist yet (`[backupSteamSession] no local.vdf to back up`). So the user-facing success path could **miss** a backup of the real token if backup ran in that race window.

### 3. `installGame` / restart path without a token

The install pipeline stops the persistent Steam process and brings it back for IPC-driven installs. If `local.vdf` was never flushed, the restarted `steam.exe -silent` has **nothing valid to load**, `waitUntilReady` **never** observes `[Logged On,` (stuck at “Connected” or similar), and the user sees failures **after** a seemingly successful sign-in.

Together: **timing between log success, on-disk `local.vdf`, backup, and a cold restart** was the failure mode—not CM auth logic in isolation.

---

## What changed in code (file index)

| Area | File | Change |
|------|------|--------|
| **Wait for real `local.vdf` after log line** | `Meridian/Steam/SteamExeSignIn.swift` | After `.loggedOn`, call `ensureLocalVdfOnDisk(prefix:engine:steamManager:)` before returning `AuthResult`. Polls up to **60s** for a file **≥ 64 bytes** (`minimumLocalVdfByteCount`); if still missing, **`stopPersistent`** to encourage flush, poll up to **25s**; if present, optional **`startPersistent` + `waitUntilReady`** to prove the same path installs use. |
| **Public heuristics** | `Meridian/Steam/SteamExeSignIn.swift` | `hasPlausibleLocalVdf(steamLocalDir:)` and `minimumLocalVdfByteCount` (documented as loose guard for empty/partial files). |
| **Bootstrap: stale self-managed session** | `Meridian/App/BootstrapManager.swift` | On `SteamError.authenticationFailed` from `waitUntilReady`, set **`settings.steamSelfManagedSession = false`** so the next run does not assume Steam-owned session when auto-login is dead (alongside existing refresh token clear / stop persistent Steam). |
| **Prepare: restore from backup** | `Meridian/Steam/SteamSessionBridge.swift` | In strategy **steamSelfManagedSession**, if `local.vdf` is **missing** in the prefix, call **`prefix.restoreSteamSession()`** (restores from `…/com.meridian.app/steam-session-backup/local.vdf` per `WinePrefix.restoreSteamSession()`). |
| **Tests (mirror contract)** | `MeridianTests/SteamExeSignInTests.swift` | Tests for `hasPlausibleLocalVdf` (missing, too small, at minimum size); `extractSteamID` cases including skipping early `[U:1:0]` lines and rejecting zero account. |

**Intentionally unchanged in this diff:** `WinePrefix.backupSteamSession()` / `restoreSteamSession()` behavior (only new **call site** in `SteamSessionBridge`); `AuthView` still calls `backupSteamSession()` after the callback—**now** `ensureLocalVdfOnDisk` makes that backup much more likely to see a real file.

---

## User-verified outcome (as reported for this work)

- **No I’m not a Human** and **Animal Well:** install and launch verified working with this persistence layer.
- **Window suppression:** still **partial** in practice—some Wine/Steam windows may flash or remain imperfectly hidden; this is a **known caveat**, not regressed to “no suppressor” by this fix.

---

## What remains (non-blocking for core session stability)

- **UI polish** around auth and install where messaging or spinners do not match actual Steam sub-states.
- **Full `SteamWindowSuppressor` coverage** for all transient windows (see `Meridian/Engine/SteamWindowSuppressor.swift` and `development-standards.mdc` “Steam UI Is Never Shown”).

---

## Related paths (reference)

- `Meridian/Steam/SteamExeSignIn.swift` — `runFlow`, `ensureLocalVdfOnDisk`, `waitForAuthOutcome`, `extractSteamID`
- `Meridian/Steam/SteamSessionBridge.swift` — `prepare`, `steamSelfManagedSession` branch
- `Meridian/App/BootstrapManager.swift` — `startPersistent` / `waitUntilReady` / `authenticationFailed`
- `Meridian/Engine/WinePrefix.swift` — `localAppDataSteamDir`, `backupSteamSession`, `restoreSteamSession`
- `Meridian/Views/Auth/AuthView.swift` — `steamSelfManagedSession`, `backupSteamSession` after sign-in
- `MeridianTests/SteamExeSignInTests.swift` — mirrors for heuristics and SteamID parsing

---

*Document generated as part of the 0.9.11 release documentation; factual claims are tied to the files above and the diff that introduced this doc.*
