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
            status: .playable,
            graphicsAPI: .dx12,
            // No explicit dllOverrides needed — WineEngine.environment() now
            // sets d3d12,dxgi=n,b globally when GPTK is present, which handles
            // the IDXGIAdapter4 NULL deref that previously caused this game to crash.
            // CLI-verified March 2026: crash eliminated with GPTK dxgi=n,b global override.
            verifiedWith: "v2.0.0-engine",
            notes: """
            Custom engine game. Ships only Animal Well.exe + steam_api64.dll. \
            DRM requires running Steam client (SteamAPI_Init via IPC). \
            Uses D3D12 via Apple GPTK. Requires dxgi=n,b to use GPTK's \
            IDXGIAdapter4-capable dxgi.dll — DXMT's dxgi returns E_NOINTERFACE \
            for IDXGIAdapter4, which the game dereferences without null-checking.
            """
        ),

    ]
}
