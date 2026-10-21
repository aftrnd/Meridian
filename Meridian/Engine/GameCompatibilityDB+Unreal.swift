import Foundation

// ─── Unreal Engine Games ─────────────────────────────────────────────────────
//
// Games running on Epic's Unreal Engine (UE4 / UE5). Unreal titles ship a
// launcher exe that spawns the real `<Game>-Win64-Shipping.exe` with engine
// args, so DRM (steam_api64.dll) detection + the gbe_fork shim (Offline mode)
// or steam.exe -applaunch (Online mode) is the reliable launch path — the
// launch-mode branch in Launcher handles both.
//
// ## Engine-level defaults (via GameProfile.unreal factory)
//   graphicsAPI: .dx11   — DX11 → DXMT → Metal. The shipped engine has no
//                          D3D12 path (WineEngine); a DX12-default UE game
//                          falls back to D3D11 SM5 by itself when
//                          D3D12CreateDevice fails, so its entry says .dx11.
//   gameEngine:  .unreal
//
// A per-game entry only specifies what DIFFERS from these defaults. A fix
// proven on one UE title (e.g. a `-dx11` launch arg) is expressed the same
// way on any other UE title — the point of the tech-stack-level factory.
//
// GameStackResolver also auto-detects Unreal from install-dir fingerprints
// (Engine/Binaries, *-Win64-Shipping.exe) and merges PCGamingWiki's Direct3D
// version. Add an explicit entry when a title needs a hand-verified override
// or to record a verified status.
//
// Shared traits:
// - UE 5.6+ starts through a bootstrapper (`<Game>.exe` in the install root,
//   UE's BootstrapPackagedGame) that wants VC++ 14.50.35719 or newer: the
//   registry key HKLM\Software\Microsoft\VisualStudio\14.0\VC\Runtimes\x64
//   and the file versions of system32\msvcp140_2.dll and vcruntime140_1.dll.
//   Wine answers file-version queries with its builtins, so engines before
//   engine patch 0007 asked to install the redistributable on every launch
//   (engine-research-findings Pattern 55).
// - Borderless "Fullscreen" covers the Wine desktop, which is the display's
//   native pixel size with RetinaMode=y; `-ResX/-ResY` don't size it.

extension GameCompatibilityDB {

    static let unrealProfiles: [GameProfile] = [

        .unreal(
            appID: 3124540,
            name: "Far Far West",
            status: .playable,
            // Straight to the D3D11 RHI it falls back to anyway.
            launchArgs: ["-dx11"],
            verifiedWith: "v4.2.0-engine",
            notes: """
            Unreal Engine 5.8.1 (Evil Raptor's "CanyonEngine" branch, build \
            0.2.0.20 CL 915; PCGamingWiki still lists 5.7.3), 64-bit, Direct3D 12 \
            only on PCGamingWiki (minimum DX12). Render path on this engine: \
            D3D12CreateDevice fails (0x80004002, no D3D12 path) and UE falls back \
            to D3D11 SM5 on its own → DXMT → Metal, feature level 11_1 on an M5 \
            Ultra. Ships DLSS/Streamline and FSR plugins (hidden without the \
            hardware), EOS (EpicWebHelper.exe), crashpad. ProtonDB Platinum (115 \
            reports, via Proton's D3D12); no AppleGamingWiki page. \
            \
            VC++ PROMPT ON EVERY LAUNCH (Oct 20 2026): FarFarWest.exe is UE's \
            bootstrapper. It asks to install "Microsoft Visual C++ 2015-2022 \
            Redistributable (x64)" unless the VC runtime is 14.50.35719 or newer. \
            The prefix had Microsoft's 14.51.36247 files in system32 and the \
            registry key, but a +ver trace showed Wine reporting system32's \
            msvcp140_2.dll as 14.42.34433: version queries map Wine's builtin in \
            place of the native file. Yes ran Engine\\Extras\\Redist\\en-us\\ \
            vc_redist.x64.exe, which found it installed and exited; then the \
            game started. Fixed in the engine for every UE 5.6+ game: patch 0007 \
            backports Wine 11.1's 14.50.35719 version numbers (Pattern 55). \
            Trace with the patched DLLs: both checks pass and the bootstrapper \
            starts FarFarWest-Win64-Shipping.exe with no prompt. \
            \
            DISPLAY: "Fullscreen" in its menu is borderless (PCGamingWiki), so it \
            fills the 5120×2880 Retina-mode desktop at r.ScreenPercentage 100 \
            whatever -ResX/-ResY say; the resolution slider (TSR/TAAU) is the \
            in-game way down. First launch got -ResX=2560 -ResY=1440 -fullscreen; \
            after it GameUserSettings.ini held 2560×1440 FullscreenMode=2 \
            (windowed). Settings: %LOCALAPPDATA%\\FarFarWest\\Saved\\Config\\Windows; \
            logs: ...\\Saved\\Logs. \
            \
            SPEED (Oct 20, M5 Ultra, 5K): about 50 fps windowed 2560×1440, 18-40 \
            borderless 5120×2880 at TSR 100% (frame counter in the UE log), 45-50 \
            with the resolution slider lowered (player's Metal HUD). A Slate \
            "FontCache flush requested. Reason: Large atlases out of space; 2/1 \
            Textures" repeats every 2-10 s at 5K (18 in 2.5 min): a glyph-cache \
            rebuild each time. The display is a 60 Hz Studio Display (NSScreen \
            maximumFramesPerSecond 60, no VRR) and GameUserSettings has \
            bUseVSync=True, so under 60 the frames alternate 60/30. 50% at 5K \
            renders 2560×1440, the same pixels as the windowed 1440p run, and both \
            sit near 50, which points away from output resolution; CPU \
            (Rosetta) vs GPU is unmeasured (Metal HUD GPU time vs frame time). \
            \
            DLSS: the DLSS-SR 8.7.0 plugin (NGX 310.6) said "requires an NVIDIA \
            RTX series graphics card ... DLSS-SR=0" on DXMT's Apple adapter. \
            DXMT_ENABLE_NVEXT=1 (Oct 20 17:03, v4.1.1 local engine, through \
            engine patch 0008) made DXMT report vendor 10de and the RHI "NVIDIA \
            D3D11", but NGX still refused: "NGXGetPathUsingQAI: no matching \
            adapter found", then "failed to load C:\\Windows\\System32\\nvngx.dll" \
            (and _nvngx.dll), Init -> NVSDK_NGX_Result_FAIL_FeatureNotSupported, \
            DLSS-SR=0. Wine itself loads DXMT's nvngx.dll from that path with its \
            exports (mingw LoadLibrary probe, same engine), so the game's NGX SDK \
            (310.6) rejects it, most likely for lacking NVIDIA's code signature \
            (DXMT's file is unsigned). Removed the variable: an NVIDIA vendor ID \
            with no DLSS only risks NVIDIA-specific paths. -dx11 kept (the log \
            goes straight to D3D11). The VC++ prompt is gone in the app on the \
            same engine (bootstrapper to -Shipping.exe in 0.2 s).
            """
        ),

    ]
}
