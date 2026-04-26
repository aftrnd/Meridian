import Foundation

// ─── Source Engine Games ─────────────────────────────────────────────────────
//
// Games running on Valve's Source engine (Half-Life 2, CS:GO, Portal, etc.).
//
// Steam DRM (steam_api64.dll) is detected automatically by gameRequiresSteamAPI()
// at launch time — no explicit entry needed here for DRM handling alone.

extension GameCompatibilityDB {

    static let sourceEngineProfiles: [GameProfile] = [

        .source(
            appID: 220,
            name: "Half-Life 2",
            status: .verified,
            graphicsAPI: .dx9,
            launchArgs: ["-game", "hl2_complete"],
            verifiedWith: "v3.0.6-engine",
            notes: """
            Launched via direct-exec (wine64 hl2.exe). Steam DRM (bin/steam_api.dll) \
            is handled by the persistent steam.exe -silent process. The `-game hl2_complete` \
            arg selects the Anniversary Edition unified content folder (ep1/ep2/lostcoast \
            bundled). CLI-verified April 26 2026: HL2 reaches main menu and is playable. \
            Root cause of earlier failure: the Anniversary `filesystem_stdio.dll` (689 KB, \
            Nov 2024) calls `CryptAcquireContextA` in DllMain — Portal 2's older version \
            (370 KB) does not. `CryptAcquireContextA` (32-bit/WoW64) reads from \
            HKLM\\WOW6432Node\\Microsoft\\Cryptography\\Defaults\\Provider Types. Those \
            keys were missing because `writeSteamInstallPathRegistryKeys` was not re-run \
            after a prefix reset (version counter wasn't cleared). Without the WoW64 crypto \
            provider types, `CryptAcquireContextA` returns NTE_PROV_TYPE_NOT_DEF, DllMain \
            returns FALSE, `FreeLibrary` is called immediately, and the Steam overlay's \
            background thread crashes in the freed address range (0x79B8DDE0). Fixed by: \
            (1) bumping steamInstallPathRegistrationVersion 2→3 to force a one-time re-run, \
            (2) resetting versioned counters to 0 after any prefix reset so keys are always \
            re-applied on the next launch.
            """
        ),

    ]
}
