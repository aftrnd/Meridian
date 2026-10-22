import Foundation

// ─── Custom Engine Games ────────────────────────────────────────────────────
//
// Games with proprietary or uncommon engines that don't match Unity/Unreal/Godot.
//
// Steam DRM (steam_api64.dll) is detected automatically by gameRequiresSteamAPI()
// at launch time — no explicit entry needed here for DRM handling alone.

extension GameCompatibilityDB {

    static let customEngineProfiles: [GameProfile] = [

        .custom(
            appID: 813230,
            name: "ANIMAL WELL",
            status: .verified,
            graphicsAPI: .dx12,
            verifiedWith: "v4.3.1-engine",
            notes: """
            Custom engine game. Ships only Animal Well.exe + steam_api64.dll. \
            DRM requires running Steam client (SteamAPI_Init via IPC). \
            \
            Rendering stack (CLI-verified April 10, 2026): \
            Wine's integrated vkd3d → MoltenVK → Metal. \
            d3d12.dll = system32 Wine builtin (vkd3d, NOT GPTK/D3DMetal). \
            dxgi.dll = system32 Wine builtin (wined3d). \
            Works correctly with a clean prefix. \
            Root fix: mtime-based prefix refresh (stale prefix broke vkd3d init). \
            \
            v4.3.1-engine (Oct 22, 2026): "fails to create d3d12 device". \
            The DX11 default gave it DXMT's dxgi, which lacks Wine's \
            IWineDXGIAdapter that Wine's d3d12 requires. DX12 games without \
            GPTK now get Wine's own dxgi (Pattern 65); user-verified running \
            on v4.3.1 the same day (vkd3d → MoltenVK → Metal). \
            Steam's "Grab a controller" screen for it stays closed (Pattern 64).
            """
        ),

        .custom(
            appID: 881100,
            name: "Noita",
            status: .verified,
            verifiedWith: "v4.3.2-engine",
            notes: """
            Nolla Games' own engine (Falling Everything), OpenGL, 32-bit, \
            SDL 2.0.7. Manifest dpiAware=true. Fullscreen is the game's own \
            routine: window sized to GetDeviceCaps' screen size, \
            ChangeDisplaySettings, borderless popup at (0,0). \
            \
            v4.3.1-engine on a 5K Retina display (Oct 22, 2026): fullscreen \
            was twice the screen, anchored mid-screen: winemac doubled \
            HORZRES/VERTRES in Retina mode (patch 0010). The window had no \
            visible title bar: OpenGL windows never turned opaque (patch \
            0011). User-verified fixed on v4.3.2: fullscreen measured \
            0,0 2560x1440 pt with Retina on (Pattern 67). \
            \
            Saves are over 50 MB (thousands of files): the first Steam Cloud \
            sync is long, and launches report "Unable to Sync" until it \
            finishes (Pattern 66).
            """
        ),

    ]
}
