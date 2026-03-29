import Foundation

// ─── Unity Games ────────────────────────────────────────────────────────────
//
// Unity games on Wine 8.0.1 crash on IsMouseInPointerEnabled (USER32.dll).
// Root cause: Unity calls GetProcessMitigationPolicy / IsMouseInPointerEnabled
// for pointer input detection. Wine 8.0.1 has these as abort() stubs.
// CrossOver 24+ properly stubs them as return-FALSE functions.
// Fix: use CX engine. DXMT goes in system32 so CX wineloader picks it up.
//
// The .unity() factory encodes these defaults. Individual games only need to
// specify what differs (e.g. graphicsAPI, dxmtMode).

extension GameCompatibilityDB {

    static let unityProfiles: [GameProfile] = [

        .unity(
            appID: 3180070,
            name: "No, I'm not a Human",
            status: .verified,
            verifiedWith: "v1.0.11-engine",
            notes: """
            Unity 2021. Crashes on IsMouseInPointerEnabled abort stub in \
            Wine 8.0.1. CX engine eliminates the crash. DXMT works when \
            placed in system32 (CX wineloader ignores WINEDLLPATH for d3d11). \
            Verified: renders frames. No steam_api64.dll — no Steam DRM, \
            launches directly.
            """
        ),

        .unity(
            appID: 3527290,
            name: "PEAK",
            status: .broken,
            graphicsAPI: .dx12,
            dxmtMode: .required,
            verifiedWith: "v1.0.11-engine",
            notes: """
            Unity game. Requires DX12 per system requirements. \
            UnityCrashHandler64.exe spawns alongside main exe. \
            CX engine needed for IsMouseInPointerEnabled + Win8+ stubs. \
            DXMT required in system32 (CX wineloader ignores WINEDLLPATH). \
            Known CrossOver issues: D3D11On12CreateDevice unimplemented, \
            mouse input registration bugs. No steam_api64.dll — no Steam DRM.
            """
        ),

        .unity(
            appID: 4069520,
            name: "Super Battle Golf",
            status: .broken,
            verifiedWith: "v1.0.11-engine",
            notes: """
            Unity game. Requires Shader Model 6.0. \
            UnityCrashHandler64.exe spawns alongside main exe. \
            CX engine needed for IsMouseInPointerEnabled + Win8+ stubs. \
            DXMT in system32 for CX wineloader compatibility. \
            CodeWeavers reports 'runs great' on CrossOver 26.0+. \
            Shows splash screens; crash before menu without CX + DXMT. \
            No steam_api64.dll — no Steam DRM.
            """
        ),

    ]
}
