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
            Launched via direct-exec (wine64 hl2.exe). Steam DRM (bin/steam_api.dll, \
            32-bit) is satisfied by the gbe_fork Steamworks API shim (Phase 4) — \
            `installSteamEmulator` copies the x86 emu over the Valve dll; no steam.exe. \
            The `-game hl2_complete` arg selects the Anniversary Edition unified content \
            folder (ep1/ep2/lostcoast bundled). CLI-verified April 26 2026: HL2 reaches \
            main menu and is playable WHEN the WoW64 crypto keys are present. \
            \
            Root cause of the crash (Pattern 11): the Anniversary `filesystem_stdio.dll` \
            (689 KB, Nov 2024) calls `CryptAcquireContextA` in DllMain — Portal 2's older \
            version (370 KB) does not. `CryptAcquireContextA` (32-bit/WoW64) reads from \
            HKLM\\WOW6432Node\\Microsoft\\Cryptography\\Defaults\\Provider Types. Without \
            those keys it returns NTE_PROV_TYPE_NOT_DEF, DllMain returns FALSE, \
            `FreeLibrary` runs immediately, and a background thread page-faults in the \
            freed DLL range (offset 0x1DDE0 — e.g. 0x79BFDDE0). \
            \
            RECURRENCE found Jun 19 2026: the keys were missing AGAIN. The earlier fix \
            (bump 2→3 + reset counters after a prefix RESET) did not cover the fresh-CREATE \
            path. A prefix recreated via `!prefix.exists` (manual `bottles/` wipe or the \
            Phase-2/3 refactor) inherited `steamInstallPathRegistrationVersion == 3` and \
            SKIPPED `writeSteamInstallPathRegistryKeys`, so the WoW64 hive only ever had \
            the 64-bit `Provider Types` wine.inf writes — the WOW6432Node ones were absent \
            (CLI-verified: present `Software\\Microsoft\\Cryptography\\Defaults`, absent \
            `Software\\Wow6432Node\\Microsoft\\Cryptography\\Defaults`). Fixed by: \
            (1) bumping steamInstallPathRegistrationVersion 3→4 to re-apply to the live \
            prefix without a wipe; (2) `BootstrapManager.resetVersionedRegistryCounters()` \
            now zeros ALL four versioned counters on BOTH prefix create AND engine reset, \
            so the registry and the counters can never drift out of sync again. \
            Re-verification on the Jun 19 2026 build pending. \
            \
            RENDER PATH (CLI-verified Sep 16 2026, M3 Pro, v3.1.0-engine): 32-bit DX9 \
            via `bin/shaderapidx9.dll` → Wine builtin d3d9 (wined3d) → Apple OpenGL. \
            78 fps at 1280x800 with fps_max 0 in d1_trainstation_01, ~220% CPU (Rosetta). \
            Every Vulkan-backed alternative renders black on this engine: CX DXVK d3d9 \
            (`CX_GRAPHICS_BACKEND=dxvk`) fails MSL compile with duplicate resource \
            bindings, Valve's `-vulkan` (bundled dxvk_d3d9) the same, wined3d \
            `renderer=vulkan` fails every SM2/3 shader (`shader_spirv_compile_shader \
            ret -5`). 64-bit wined3d-vk works, so the 32-bit Vulkan thunk path is the \
            suspect. `mat_queue_mode 2` measured no gain. Do not add a d3d9 override \
            until a d3d9 backend is verified to draw — see docs/HL2-PERFORMANCE.md.
            """
        ),

    ]
}
