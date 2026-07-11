import Foundation

// ─── Godot Games ────────────────────────────────────────────────────────────
//
// Godot 4 games render via Vulkan (Forward+ / Forward Mobile) → MoltenVK →
// Metal, or via OpenGL (Compatibility). No D3D translation layer (DXMT/DXVK/
// GPTK) is involved, so dllOverrides/dxmtMode rarely apply.
//
// KNOWN ENGINE-WIDE ISSUE — Forward+ black-square artifacts on Apple Silicon:
// Godot's Forward+ (clustered) renderer produces intermittent solid-black,
// screen-aligned squares on surfaces lit by positional lights (OmniLight3D /
// SpotLight3D) when running through MoltenVK on Apple GPUs. Upstream reports:
//   - godotengine/godot#104168 (Wine on macOS, positional lights, more lights
//     = more squares, squares move on window resize)
//   - godotengine/godot#121201 (native macOS Metal build, single static
//     OmniLight3D — so it's the clustered light path, not Wine)
// Both report the Mobile renderer eliminates the artifacts: Forward Mobile
// doesn't use the clustered light-culling compute path that mis-renders under
// MoltenVK/Metal.
//
// Fix pattern: launchArgs: ["--rendering-method", "mobile"] — Godot 4 honors
// this standard engine flag in exported games; it overrides the project's
// rendering method at startup.

extension GameCompatibilityDB {

    static let godotProfiles: [GameProfile] = [

        .godot(
            appID: 4450800,
            name: "Idols of Ash",
            status: .playable,
            launchArgs: ["--rendering-method", "gl_compatibility", "--rendering-driver", "opengl3"],
            verifiedWith: "v3.1.0-engine",
            notes: """
            Godot 4.6.3 (double-precision custom build). Ships gbe_fork \
            Steamworks shim (steam_api64.dll + steam_settings/) — launches \
            without steam.exe. \
            \
            Issue: with the default Forward+ renderer (Vulkan → MoltenVK → \
            Metal), intermittent solid-black screen-aligned squares flicker \
            over lit 3D surfaces (user-reported July 11 2026). This is the \
            known Godot Forward+ clustered-lighting artifact on Apple Silicon \
            (godotengine/godot#104168, #121201): the clustered positional-light \
            path mis-renders on Apple GPUs (reproduced upstream on the native \
            Metal backend too, so it is Godot's cluster path, not MoltenVK or \
            Wine). No errors are logged — draws complete with corrupt cluster \
            data. \
            \
            Attempts (all CLI-tested July 11 2026 on v3.1.0-engine): \
            (1) --rendering-method mobile: boots ("Forward Mobile" in log) but \
            user-verified BROKEN — 2D UI renders, 3D scene is solid black. \
            (2) MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0: no-op — MoltenVK \
            1.2.10 logs "Descriptor sets binding resources using discrete \
            resource indexes" by default, so argument buffers were never in \
            use; not the cause. \
            (3) --rendering-method gl_compatibility --rendering-driver opengl3: \
            boots cleanly, logs "OpenGL API 4.1 Metal - 91.7 - Compatibility". \
            Avoids the Vulkan clustered path entirely (Compatibility uses \
            per-pixel forward lighting, no clustering). CURRENT profile — \
            user-verified July 11 2026: black squares gone, 3D scene renders \
            correctly, gameplay works. Performance slightly degraded vs \
            Forward+ (expected — Compatibility is the lower-fidelity/lower- \
            overhead-ceiling renderer) but acceptable. This fix is per-game \
            by design: the artifact can't be detected from logs (corrupt \
            draws complete silently), so each affected Godot title gets its \
            own profile entry rather than an engine-wide default.
            """
        ),

    ]
}
