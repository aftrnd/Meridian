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
            verifiedWith: "v3.0.5-engine",
            notes: """
            Custom engine game. Ships only Animal Well.exe + steam_api64.dll. \
            DRM requires running Steam client (SteamAPI_Init via IPC). \
            Uses D3D12 via Apple GPTK (D3DMetal.framework → Metal). \
            \
            The graphicsAPI=.dx12 profile causes WineSteamManager.launchGameDirectly() \
            to automatically override WINEDLLPATH to gptk/wine:lib/wine and set \
            WINEDLLOVERRIDES=d3d12=b;dxgi=b — routing both dxgi and d3d12 through \
            GPTK's implementations (which support IDXGIAdapter4) instead of DXMT's \
            (which do not, causing IDXGIAdapter4 NULL deref crash on startup).
            """
        ),

    ]
}
