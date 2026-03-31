import Foundation

// ─── Unity Games ────────────────────────────────────────────────────────────
//
// Unity games are launched directly via wine64. The .unity() factory encodes
// engine-specific defaults. Individual games only need to specify what differs
// (e.g. graphicsAPI, dxmtMode).

extension GameCompatibilityDB {

    static let unityProfiles: [GameProfile] = [

        .unity(
            appID: 3180070,
            name: "No, I'm not a Human",
            status: .verified,
            verifiedWith: "v1.0.11-engine",
            notes: """
            Unity 2021. Direct launch via wine64. DXMT (builtin) handles D3D11. \
            No steam_api64.dll — no Steam DRM, launches directly.
            """
        ),

        .unity(
            appID: 3527290,
            name: "PEAK",
            status: .broken,
            graphicsAPI: .dx12,
            dxmtMode: .auto,
            verifiedWith: "v1.0.11-engine",
            notes: """
            Unity game. Requires DX12 per system requirements. \
            UnityCrashHandler64.exe spawns alongside main exe. \
            No steam_api64.dll — no Steam DRM.
            """
        ),

        .unity(
            appID: 4069520,
            name: "Super Battle Golf",
            status: .broken,
            graphicsAPI: .dx12,
            verifiedWith: "v1.0.11-engine",
            notes: """
            Unity game. Shader Model 6.0 required — SM6 is DX12-only per \
            Microsoft DirectX documentation (SM5.1 is the DX11 maximum). \
            No steam_api64.dll — no Steam DRM.
            """
        ),

    ]
}
