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
            preferD3DMetal: true,
            launchArgs: ["-force-d3d11"],
            skipSteamDRM: true,
            verifiedWith: "v3.0.6-engine",
            notes: """
            Unity 6000.3.10f1. Three fixes required (all engine-level): \
            (1) -force-d3d11: Unity defaults to DX12. VKD3D-proton is non-functional \
            on macOS/Apple Silicon (requires VK_EXT_transform_feedback, absent in \
            MoltenVK). Without -force-d3d11, the D3D12 path crashes with \
            0xc06d007e (E_DELAYLOAD_MOD_NOT_FOUND). -force-d3d11 routes through \
            D3D11 which is fully stable. \
            (2) Custom coremessaging.dll: Unity 6.3+ calls \
            RoGetActivationFactory("Windows.System.DispatcherQueue") for \
            IDispatcherQueueStatics::GetForCurrentThread(). Wine 11.5's built-in \
            coremessaging.dll only handles DispatcherQueueController, not \
            DispatcherQueue. Our stub DLL (Scripts/coremessaging/coremessaging_stub.c, \
            cross-compiled via mingw-w64) adds the missing IDispatcherQueueStatics \
            activation factory. Installed into prefix system32 by \
            registerWinRTClasses(). Built into engine by release-engine.sh. \
            (3) preferD3DMetal: the MF/Unity VideoPlayer intro+ending cutscenes \
            render BLACK under DXMT — DXMT cannot service the Media Foundation \
            video processor's D3D11 texture path (GStreamer/VideoToolbox decodes \
            the NV12 frame fine, but it never presents onto Unity's DXMT D3D11 \
            device). preferD3DMetal routes D3D11 through Apple GPTK (D3DMetal) via \
            CX_GRAPHICS_BACKEND=d3dmetal + CX_ROOT — the same complete D3D11 \
            implementation CrossOver 26 uses, which DOES service the video path. \
            CLI + user-verified June 19 2026: cutscenes show image+sound. \
            skipSteamDRM: steam_api64.dll is in Plugins/x86_64/ but the game \
            handles SteamAPI_Init() failure gracefully — running steam.exe first \
            causes wineserver conflicts. \
            Verified: launches+plays, video cutscenes work, on v3.0.6-engine. \
            User-confirmed June 19 2026 via Meridian.
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
            Unity DX12 game. Root cause of crash (0xc06d007e / E_DELAYLOAD_MOD_NOT_FOUND): \
            WineEngine.environment(for:) was globally setting WINEDLLOVERRIDES=d3d12,d3d12core=n \
            to load VKD3D-proton's native d3d12.dll. VKD3D-proton is non-functional on \
            macOS/Apple Silicon (requires VK_EXT_transform_feedback, absent in MoltenVK). \
            Unity probes D3D12 even with -force-d3d11, hitting the broken VKD3D-proton path. \
            Engine-wide fix (April 2026): removed the VKD3D-proton override from \
            WineEngine.environment(for:). -force-d3d11 routes through DXMT->Metal. \
            No per-game WINEDLLOVERRIDES needed. Untested post-fix — verify and update status.
            """
        ),

    ]
}
