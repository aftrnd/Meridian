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
            status: .launches,
            graphicsAPI: .dx12,
            verifiedWith: "v3.0.1-engine",
            notes: """
            Custom engine game. Ships only Animal Well.exe + steam_api64.dll. \
            DRM requires running Steam client (SteamAPI_Init via IPC). \
            Uses D3D12 via Apple GPTK (D3DMetal.framework). \
            WineEngine.environment() sets d3d12=n,b;dxgi=n,b globally when \
            gptkPath is detected — loads CX d3d12.dll + GPTK dxgi.dll \
            (implements IDXGIAdapter4, prevents NULL deref crash). \
            Testing in progress with CX Wine 11.4 + GPTK.
            """
        ),

    ]
}
