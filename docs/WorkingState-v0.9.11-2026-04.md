# Meridian v0.9.11 — Verified Working State (April 25, 2026)

This document captures the **complete arc of fixes** that brought Meridian
to a user-confirmed working state on app `v0.9.11` paired with
**Meridian Engine v3.0.6** (release tag `v3.0.6-engine`). It is the
answer to "what changed, what worked, why".

**User-verified outcome (April 25, 2026):**

> "I could install a game and it launched … downloaded and launched two games,
> No, I'm not a Human and Animal Well."

This is the first session in the post-`config.vdf` era where the **entire
chain — sign-in → install → launch — runs end-to-end with all UI inside
Meridian and Steam invisible**. UI polish and complete window suppression
are the remaining open items; core architecture is correct.

---

## Pairing

| Component | Tag | Source of truth |
|---|---|---|
| Meridian app | **v0.9.11** | `MARKETING_VERSION` in `Meridian.xcodeproj/project.pbxproj`; GitHub Releases |
| Meridian Engine | **v3.0.6** (`v3.0.6-engine` tag) | `~/Library/Application Support/com.meridian.app/engine/wine/meridian-engine-version.txt`; GitHub Releases |

Meridian Engine v3.0.6 is unchanged from release tag `v3.0.6-engine`
(published April 24 2026). All fixes since then are **app-side**.
`Scripts/release-engine.sh` was last touched in commit `4d6add0` which
is included in `v3.0.6-engine`.

---

## The arc — every commit since the last solid baseline

Listed newest-first. All on branch `v0.9.8.1`, tagged `v0.9.11` at HEAD.

| Commit | What it fixed | Why |
|---|---|---|
| `0053212` | `local.vdf` flush wait after `-login` | `[Logged On,]` log line could appear before Steam wrote `local.vdf`; backups + restart-driven `installGame` then had nothing to load. |
| `186e9fb` | Switched auth from JWT-injection to **`steam.exe -login`** | Valve's CM rejects API-issued JWTs that lack a `machine_id` HMAC matching the Wine bottle's WMI fingerprint. Steam derives its own `machine_id` correctly when invoked with `-login user pass`. |
| `2aa8cf0` | Fast-fail on `LogonFailureReceived` / `Invalid Password` in `connection_log.txt`; pkill `steamwebhelper` before throwing `authenticationFailed` | A 60-second silent timeout on bad credentials looked like a hang; the "Who's Playing" WebKit picker could leak through when auth ended. |
| `9e1568b` | (Historical) Added `device_friendly_name` to `BeginAuthSessionViaCredentials` (later moot once `-login` replaced JWT injection) | Attempt to bind the API-issued JWT to a SteamClient platform identity. Did not solve the `machine_id` mismatch. |
| `951c6ad` | Registered **`nsiproxy`** service in `system.reg`; set DPAPI descriptor to **`L"BObfuscateBuffer"`**; added a no-op guard so engine auto-update won't re-extract over a running Wine | Without `nsiproxy`, Wine's `iphlpapi.dll` `GetAdaptersAddresses` returns error 2; Steam's `WebUITransportController` rejects the loopback handshake and the main process asserts and restarts in a loop. Wrong DPAPI descriptor caused Steam to silently reject `local.vdf` even though decryption succeeded. Engine auto-update racing with `wine64 SteamSetup.exe` was wiping `wine64` mid-execution. |
| `7f42f8a` `4d6add0` `d6345dd` | Window suppression dylib: `meridian-wine-accessory.dylib` (`DYLD_INSERT_LIBRARIES`) with `setActivationPolicy:` swizzling; `wine64` re-signed with `com.apple.security.cs.allow-dyld-environment-variables`; **drop** `--preserve-metadata=team-identifier` (was causing `exit 9` SIGKILL). | Wine processes (`steamwebhelper.exe`, etc.) were registering Dock tiles and notifications. The dylib forces `NSApplicationActivationPolicyAccessory` for every Wine-spawned app; method swizzling prevents `winemac.drv` from resetting it back to regular. |
| `ef985f4` `2eddbc9` | Live disk-usage progress for installs; `libproc`-based Wine PID enumeration | `BytesDownloaded` from `appmanifest.acf` is unreliable; polling `steamapps/downloading/<APPID>/` directory size gives true live progress. `NSWorkspace.runningApplications` misses CEF children of Wine; `proc_listpids` finds them all. |
| `97436b6` | Wait for old Steam to fully exit before restarting for install | Race in `installGame` was leaving stale wineserver state. |
| `9e3c104` | Bundle `meridian-dpapi.exe` in app Resources; `WinePrefix.installDpapiHelperFromBundle` self-heals after engine wipes | Engine auto-update was overwriting the helper. |
| `a289f28` | Replace hard-coded "Updating Steam…" UI text with `launcher.currentActivity`; `waitUntilReady` reads `bootstrap_log.txt` from a snapshot offset | Old cumulative log lines were producing spurious "Steam Updating" toasts during ordinary installs. |
| `361f2a1` | Pre-seed `appmanifest_<APPID>.acf` and restart Steam so the IPC `+app_update` path is silent | Avoids ever showing Steam's own UI for confirmation. |
| `60161d0` | (Historical) Silent Steam auto-login via DPAPI-encrypted `local.vdf` from Meridian-issued JWT | Worked for warm bottles but failed with "Invalid Password" on fresh bottles due to `machine_id` mismatch — superseded by `186e9fb`. |
| `2800632` | Library hero image support | UI / library polish. |
| `f1757fd` | Stop tracking `.cursor/` | Local-only rules and findings. |
| `84705d7` | Animal Well verified — vkd3d → MoltenVK → Metal | First D3D12 verification on the standalone engine. |

---

## Why the system works now — root cause walk-through

### 1. Auth: drive `steam.exe` directly, do not inject a JWT

`SteamExeSignIn` (`Meridian/Steam/SteamExeSignIn.swift`) launches:

```
wine64 steam.exe -silent -nofriendsui -login <user> <pass>
```

Steam itself runs `BeginAuthSessionViaCredentials` against Valve's CM with
its own `machine_id` derived from Wine's WMI tables. Mobile Authenticator
push lands on the user's phone — they tap Approve — Steam writes `local.vdf`
with the correct DPAPI binding. Meridian never sees the password again and
never touches Steam's token format.

Why this is the right architecture (vs the deleted JWT-injection path):

- Steam's `local.vdf` blob carries an internal `machine_id` HMAC. Tokens
  issued by `IAuthenticationService` from a non-Steam process do **not**
  carry the matching binding for the Wine bottle. CLI-verified April 22-25:
  injected tokens get `Invalid Password` from CM even when DPAPI decryption
  succeeds.
- `-login user pass` is exactly what Steam's own UI calls under the hood.
  We are using a public, supported entry point.
- Future Valve protocol changes don't break us; Steam handles its own
  upgrades.

### 2. Network plumbing: core Wine services registered via `wine64 reg add`

`WinePrefix.ensureCoreServices(engine:)`
(`Meridian/Engine/WinePrefix.swift`) registers `nsiproxy`, `RpcSs`,
`EventLog`, and `PlugPlay` via `wine64 reg add
HKLM\System\CurrentControlSet\Services\<svc>` on every fresh prefix.
Without `nsiproxy`, Wine's `\\.\Nsi` device is never created,
`iphlpapi::GetAdaptersAddresses` returns `ERROR_FILE_NOT_FOUND`, Steam's
`CalcUnIPThisBox` (`net_misc.cpp:252`) asserts, and the
`WebUITransportController` (`webuitransportcontroller.cpp:165`) websocket
handshake fails — Steam's main process enters an assert/auto-restart loop
that produces a macOS "wine64 unexpected error" dialog before reaching
auth. See `engine-research-findings.mdc` "Pattern 7" for the full failure
signature.

The runtime self-heal exists because `Scripts/release-engine.sh`'s
`wineboot --init` step is killed by its 180 s timeout
(`rundll32 setupapi InstallHinfSection` runaway recursion in `ntdll.so`
on macOS hosts), leaving the shipped prefix template with only 2
services (`MountMgr`, `Tcpip\Parameters`) instead of the 12+ a
Linux-host wineboot would register.

`wine64 reg add` is required (instead of file-surgery on `system.reg`)
because Wine's `[System\\CurrentControlSet]` is a registry symlink to
`[System\\ControlSet001]`. Direct file writes under
`CurrentControlSet\Services\<svc>` are dropped on the next `wineserver`
save when the symlink is resolved. The legacy `ensureNsiproxyService`
(file-surgery) approach was unreliable for exactly this reason.

Guard tests in `MeridianTests/EnsureCoreServicesTests.swift` keep this
invariant in place.

### 3. Session persistence: wait for `local.vdf` to actually flush

The remaining failure mode after `186e9fb` was a **race**:

- `connection_log.txt` writes `[Logged On,` from the network thread.
- `local.vdf` writes from a different thread, possibly seconds later.
- `AuthView` immediately called `prefix.backupSteamSession()` which silently
  no-oped because the file wasn't there yet.
- `installGame` then `stopPersistent` + `startPersistent -silent` — Steam
  had no token to load, `waitUntilReady` timed out, install path failed
  with `authenticationFailed`.

The fix in `0053212` (`SteamExeSignIn.ensureLocalVdfOnDisk`):

1. After `[Logged On,]`, poll up to **60s** for a `local.vdf` ≥ **64 bytes**
   (`hasPlausibleLocalVdf`).
2. If still missing, do a graceful `stopPersistent` to flush, poll up to
   **25s** more.
3. If found, optionally `startPersistent` + `waitUntilReady` to prove the
   silent path the install pipeline uses actually works.
4. If never found → throw a typed `AuthError` so the user sees a real
   message, not a 60s spinner.

Plus belt-and-suspenders:

- `SteamSessionBridge.prepare`: if `steamSelfManagedSession` is true but
  `local.vdf` is missing in the prefix (e.g. the bottle was reset),
  call `prefix.restoreSteamSession()` from the
  `…/com.meridian.app/steam-session-backup/` mirror.
- `BootstrapManager`: on `WineSteamManager.SteamError.authenticationFailed`
  from `waitUntilReady`, set `settings.steamSelfManagedSession = false` so
  the next launch re-enters the sign-in sheet rather than looping on a
  dead self-managed strategy.

### 4. Install path: pre-seed ACF + IPC, never show Steam UI

Verified working (April 25, 2026, both DX11 + D3D12 games):

- Meridian writes `appmanifest_<APPID>.acf` with minimal "ready to download"
  state.
- `stopPersistent` → `startPersistent -silent`. Now that `ensureLocalVdfOnDisk`
  has guaranteed a real session on disk, Steam silently reaches `[Logged On,`.
- `WineSteamManager.installGame` dispatches `+app_update <APPID>` over
  Steam's IPC.
- Live progress: poll `steamapps/downloading/<APPID>/` directory bytes (the
  same source Steam Desktop's progress bar reads).
- Completion: poll `WinePrefix.isGameFullyInstalled(appID:)` parsed from
  the manifest's `StateFlags`.

### 5. Window suppression: dylib + AX poller

`meridian-wine-accessory.dylib` is `DYLD_INSERT`-ed into every Wine process
(`wine64` re-signed in `release-engine.sh` with
`com.apple.security.cs.allow-dyld-environment-variables`). It:

- Forces `NSApplicationActivationPolicyAccessory` on `applicationDidFinishLaunching`.
- Swizzles `-[NSApplication setActivationPolicy:]` to ignore subsequent
  resets from `winemac.drv`.

`SteamWindowSuppressor` (`Meridian/Engine/SteamWindowSuppressor.swift`):

- Enumerates Wine PIDs via `proc_listpids` (catches CEF children
  `NSWorkspace` misses).
- Installs an `AXObserver` per PID and calls `AXUIElementSetAttributeValue`
  to hide windows that slip through the dylib net.
- `pkill steamwebhelper` is called whenever a transient WebKit picker
  ("Who's Playing", post-install confirmation) needs to be killed.

Status: **partially working**. Some windows still flash briefly. This is
acknowledged as remaining UX polish, not a regression.

---

## File index — where each piece lives

| Concern | File |
|---|---|
| `-login` driver, post-login flush wait, fast-fail, ID parse | `Meridian/Steam/SteamExeSignIn.swift` |
| Self-managed strategy + backup restore | `Meridian/Steam/SteamSessionBridge.swift` |
| `nsiproxy` injection, DPAPI helper bundle, prefix paths | `Meridian/Engine/WinePrefix.swift` |
| Persistent Steam start/stop, `waitUntilReady`, kill webhelper | `Meridian/Engine/WineSteamManager.swift` |
| Engine env, dylib injection, `DYLD_INSERT_LIBRARIES` setup | `Meridian/Engine/WineEngine.swift` |
| AX-based window hiding | `Meridian/Engine/SteamWindowSuppressor.swift` |
| Bootstrap pipeline, auth-failure self-managed clear | `Meridian/App/BootstrapManager.swift` |
| Install pipeline, `currentActivity`, ACF pre-seed, progress | `Meridian/Launch/GameLauncher.swift` |
| Sign-in sheet, post-success backup call | `Meridian/Views/Auth/AuthView.swift` |
| Persisted flags (`steamSelfManagedSession`, `lastPrefixEngineModTime`, etc.) | `Meridian/Models/AppSettings.swift` |
| DPAPI helper (encrypt/decrypt CryptProtectData) | `Scripts/dpapi/meridian_dpapi.c` |
| Wine accessory dylib (Dock + activation policy) | `Scripts/wine-accessory/meridian_wine_accessory.m` |
| Engine packaging, dylib build + `wine64` re-sign | `Scripts/release-engine.sh` |
| Mirror tests for `local.vdf` heuristic + Steam ID parse | `MeridianTests/SteamExeSignInTests.swift` |

---

## Test status

`swift test` — **267 tests, 0 failures** at `0053212`. Unit tests cannot
prove the timing of Wine's `local.vdf` flush in production; the
user-verified install + launch of two games at this commit is the
authoritative integration signal.

---

## Open items (UX polish, non-blocking)

- **Window suppression coverage**: persistent residual flashes from
  CEF/webhelper transient windows. Investigate whether to add additional
  pkill timing or use SkyLight/CGSPrivate APIs to hide more aggressively.
- **Sign-in / install messaging**: "Steam Updating", spinner phases, and
  some toasts still drift behind real Steam state. `currentActivity`
  rewiring covered the worst, but one more pass on `GameLauncher` phase
  copy is warranted.
- **First-run UX**: the 30-60 second post-install initial Steam start is
  acceptable but feels long; further optimisation of warm-up cache vs
  pre-extracted state could halve it.
- **Tests for `ensureLocalVdfOnDisk` flush behavior**: only the
  `hasPlausibleLocalVdf` heuristic is unit-tested. The full `runFlow` →
  `ensureLocalVdfOnDisk` happy path is verified manually.

---

## How to reproduce the verified state

1. Install **app v0.9.11** from
   <https://github.com/aftrnd/Meridian/releases/tag/v0.9.11>.
2. **Meridian Engine v3.0.6** auto-downloads on first launch (release tag
   `v3.0.6-engine`, or pull from
   <https://github.com/aftrnd/Meridian/releases/tag/v3.0.6-engine>).
3. Sign in via the Meridian sheet (username + password; tap Approve on
   Steam Mobile).
4. Click Install on a game (e.g. *No, I'm not a Human* `3180070` or
   *Animal Well* `813230`). Progress bar tracks live disk-usage in
   `steamapps/downloading/`.
5. Click Play. Game window appears; Steam stays invisible.

If sign-in fails with "Steam could not sign in with the saved session", the
self-managed flag now clears automatically and the next launch returns to
the sign-in sheet — see `BootstrapManager` `authenticationFailed` branch.

---

*Working-state document for Meridian v0.9.11 paired with Meridian Engine
v3.0.6 (release tag `v3.0.6-engine`). Generated April 25 2026 from the
file diffs and commit history at HEAD `0053212`.*
