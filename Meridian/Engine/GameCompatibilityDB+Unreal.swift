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
//   graphicsAPI: .dx11   — UE defaults to DX11; DX12 titles set .dx12 to route
//                          through GPTK/D3DMetal.
//   gameEngine:  .unreal
//
// A per-game entry only specifies what DIFFERS from these defaults. A fix
// proven on one UE title (e.g. a DX12→GPTK route, a `-dx11`/`-d3d12` launch
// arg, a DLSS→MetalFX bridge opt-in) is expressed the same way on any other
// UE title — the point of the tech-stack-level factory.
//
// GameStackResolver also auto-detects Unreal from install-dir fingerprints
// (Engine/Binaries, *-Win64-Shipping.exe) and merges PCGamingWiki's Direct3D
// version, so a UE game with NO entry here still routes DX12→GPTK correctly.
// Add an explicit entry when a title needs a hand-verified override or to
// record a verified status.

extension GameCompatibilityDB {

    static let unrealProfiles: [GameProfile] = [

        // No hand-verified Unreal titles yet. Entries are added as titles are
        // CLI/in-app verified (per knowledge-preservation.mdc: every tested
        // game gets an entry, even when it works out of the box). Until then,
        // UE titles are handled by GameStackResolver auto-detection + the
        // engine-wide DXMT (DX11) / GPTK (DX12) defaults.
        //
        // Example shape for a future DX12 UE5 title needing the DLSS bridge:
        //
        //   .unreal(
        //       appID: 0,
        //       name: "Example UE5 Game",
        //       status: .untested,
        //       graphicsAPI: .dx12,
        //       enableDLSSBridge: true,          // route DLSS → MetalFX (GPTK 4)
        //       launchArgs: ["-dx12"],
        //       verifiedWith: nil,
        //       notes: "DX12 → GPTK → D3DMetal → Metal. DLSS bridged to MetalFX."
        //   ),

    ]
}
