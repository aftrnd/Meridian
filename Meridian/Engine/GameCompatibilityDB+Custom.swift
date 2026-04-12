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
            verifiedWith: "v3.0.5-engine",
            notes: """
            Custom engine game. Ships only Animal Well.exe + steam_api64.dll. \
            DRM requires running Steam client (SteamAPI_Init via IPC). \
            \
            Rendering stack (CLI-verified April 10, 2026): \
            Wine's integrated vkd3d → MoltenVK → Metal. \
            d3d12.dll = system32 Wine builtin (vkd3d, NOT GPTK/D3DMetal). \
            dxgi.dll = system32 Wine builtin (wined3d). \
            Works correctly with a clean prefix. \
            Root fix: mtime-based prefix refresh (stale prefix broke vkd3d init).
            """
        ),

    ]
}
