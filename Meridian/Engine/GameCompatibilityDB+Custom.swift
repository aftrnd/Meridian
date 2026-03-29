import Foundation

// ─── Custom Engine Games ────────────────────────────────────────────────────
//
// Games with proprietary or uncommon engines that don't match Unity/Unreal/Godot.
// The .custom() factory defaults requiresCXEngine=false — override per-game
// when the engine hits Wine abort stubs that CX fixes.
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
            requiresCXEngine: true,
            requiresDXMTInSystem32: true,
            verifiedWith: "v1.0.11-engine",
            notes: """
            Custom engine game. Ships only Animal Well.exe + steam_api64.dll. \
            DRM requires running Steam client (SteamAPI_Init via IPC). \
            Uses D3D12 → Apple GPTK D3DMetal (GPTK path added to WINEDLLPATH \
            in v0.9.6). Verified: window appears, game runs with Steam started \
            silently for DRM.
            """
        ),

    ]
}
