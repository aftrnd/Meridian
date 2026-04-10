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
            graphicsAPI: .dx11,
            extraEnv: ["WINEDLLOVERRIDES": ""],
            launchArgs: ["-force-d3d11"],
            skipSteamDRM: true,
            verifiedWith: "v3.0.0-engine",
            notes: """
            Unity 6000.3.10f1. Three fixes required (all engine-level): \
            (1) -force-d3d11: Unity defaults to DX12. VKD3D-proton's DX12 path \
            crashes with 0xc06d007e (E_DELAYLOAD_MOD_NOT_FOUND). -force-d3d11 \
            routes through DXMT->Metal which is fully stable. \
            (2) Custom coremessaging.dll: Unity 6.3+ calls \
            RoGetActivationFactory("Windows.System.DispatcherQueue") for \
            IDispatcherQueueStatics::GetForCurrentThread(). Wine 11.5's built-in \
            coremessaging.dll only handles DispatcherQueueController, not \
            DispatcherQueue. Our stub DLL (Scripts/coremessaging/coremessaging_stub.c, \
            cross-compiled via mingw-w64) adds the missing IDispatcherQueueStatics \
            activation factory. Installed into prefix system32 by \
            registerWinRTClasses(). Built into engine by release-engine.sh. \
            (3) WINEDLLOVERRIDES="" clears the global VKD3D-proton d3d12 native \
            override. With -force-d3d11, the game never uses d3d12 — but the \
            VKD3D-proton override forces Wine to load vkd3d-proton's d3d12.dll \
            anyway, causing a second delay-load crash in UnityPlayer's D3D12 \
            feature probe. Clearing overrides lets Wine use its builtin d3d12 \
            stub (which safely returns E_NOINTERFACE). \
            skipSteamDRM: steam_api64.dll is in Plugins/x86_64/ but the game \
            handles SteamAPI_Init() failure gracefully — running steam.exe first \
            causes wineserver conflicts. \
            Verified: launches from Meridian, plays successfully on v3.0.0-engine. \
            User-confirmed April 9 2026 via Meridian v0.9.7.1 — first successful end-to-end game launch.
            """
        ),

        .unity(
            appID: 3527290,
            name: "PEAK",
            status: .verified,
            graphicsAPI: .dx11,
            dxmtMode: .auto,
            launchArgs: ["-force-d3d11"],
            verifiedWith: "v3.0.0-engine",
            notes: """
            Unity 6000.0 (DX12 default). Fix: -force-d3d11 routes through \
            DXMT->Metal. Does NOT need WINEDLLOVERRIDES="" (Unity 6000.0 doesn't \
            probe D3D12 as aggressively as 6000.3). Does NOT need custom \
            coremessaging.dll (Unity 6000.0 doesn't call DispatcherQueue). \
            Requires Steam DRM: steam_api64.dll in PEAK_Data/Plugins/x86_64/. \
            Recursive DRM detection finds it, startSteamForDRM() provides IPC. \
            Verified: launches from Meridian, runs well on v3.0.0-engine.
            """
        ),

        .unity(
            appID: 4069520,
            name: "Super Battle Golf",
            status: .untested,
            graphicsAPI: .dx11,
            dxmtMode: .auto,
            launchArgs: ["-force-d3d11"],
            verifiedWith: nil,
            notes: """
            Unity DX12 game. Applying same -force-d3d11 fix as PEAK (same root \
            cause suspected: VKD3D-proton delay-load failure). Untested — verify \
            and update status after launch test. No steam_api64.dll — no Steam DRM.
            """
        ),

    ]
}
