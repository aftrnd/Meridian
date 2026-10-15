import Foundation

// ─── Gamebryo Engine Games ──────────────────────────────────────────────────
//
// Bethesda's Gamebryo titles (Oblivion, Fallout 3, Fallout: New Vegas):
// "Gamebryo (TES Engine)" on PCGamingWiki, 32-bit, Direct3D 9.0c, so they
// render through Wine's wined3d → OpenGL until a d3d9 → Metal backend draws
// (engine-research-findings Patterns 27, 31, 32). Skyrim and Fallout 4 are
// Creation Engine, not this file.
//
// Shared traits found on New Vegas (Oct 14 2026), likely across the family:
// - Steam starts a launcher (Play / Data Files / Options), not the game.
//   It greys out Play without HKLM\Software\Wow6432Node\Bethesda Softworks\
//   <Game>\Installed Path (PCGamingWiki); Steam's install script writes it.
// - First launch runs DirectX June 2010 + VC++ from the game's `Redists\`
//   (Pattern 51).
// - Music is loose MP3 played through DirectShow. Fallout 3's silent radio
//   (Wine bug 42033: an MP3 seek gave negative GStreamer timestamps) was
//   fixed in Wine 10.11; the engine is Wine 11.
// - The 32-bit exes are not large-address-aware. Meridian sets
//   WINE_LARGE_ADDRESS_AWARE=1 for every game, which the engine's ntdll.so
//   reads, so they get the 4 GB space the community "4GB patch" gives.

extension GameCompatibilityDB {

    static let gamebryoProfiles: [GameProfile] = [

        .gamebryo(
            appID: 22380,
            name: "Fallout: New Vegas",
            status: .launches,
            verifiedWith: "v4.1.0-engine",
            notes: """
            Gamebryo (TES Engine), 32-bit FalloutNV.exe, Direct3D 9.0c, shader \
            model 3.0; Havok physics, SpeedTree, DirectSound audio, Bink video \
            (PCGamingWiki, Oct 14 2026). Render path: Wine builtin d3d9 (wined3d) → \
            OpenGL. PCGamingWiki's top Windows fix (DXVK d3d9 for speed and \
            stability) does not apply: DXVK d3d9 doesn't draw on this engine yet. \
            \
            LAUNCH: `-applaunch 22380` starts FalloutNVLauncher.exe; its Play \
            starts FalloutNV.exe. The launcher needs \
            HKLM\\Software\\Wow6432Node\\Bethesda Softworks\\FalloutNV "Installed \
            Path" (present: written by Steam's install script). On first run it detects video settings and \
            writes Documents\\My Games\\FalloutNV\\*.ini (defaults: \
            Fallout_default.ini). Settings and saves live there in the prefix. \
            \
            FIRST LAUNCH (console_log Oct 14 2026): Steam's install script runs \
            Redists\\directx\\DXSETUP.exe /silent (xactengine2_0…3_5, XAudio2_0…5) \
            then vcredist_x86/x64 /q, about 20 s on an M3 Pro (RunningInstallScript \
            23:14:44 → SynchronizingCloud 23:15:04), recorded in \
            HKLM\\Software\\Wow6432Node\\Valve\\Steam\\Apps\\22380 (directx, \
            visualcredist = 1). Meridian took the installers for the game and \
            showed it running; the player pressed Stop and killed the setup twice. \
            Fixed for every game (Pattern 51). \
            \
            AUDIO: radio and score are 247 loose MP3s in Data\\Music. Fallout 3's \
            silent-radio bug (Wine 42033) is fixed in Wine 10.11; this engine \
            (v4.1.0-engine) is Wine 11. MP3 decode: the engine's GStreamer has no \
            mpg123 plugin, but applemedia's atdec takes audio/mpeg layer 1-3, and \
            Wine's l3codeca.acm / l3codecx.ax / mp3dmod are present. Radio not yet \
            heard in Meridian. \
            \
            MEMORY: not large-address-aware (PCGamingWiki recommends the 4GB \
            patcher); WINE_LARGE_ADDRESS_AWARE=1 is set for it (22380.log header) \
            and read by the engine's ntdll.so, which gives the same 4 GB. \
            \
            OTHER MAC REPORTS (AppleGamingWiki): CrossOver 21.2 playable but ~15 \
            fps on a base M1; Wine via Porting Kit playable, "good" on M3. \
            \
            FIRST PLAY (Oct 14 2026 23:49-23:51, M5 Ultra, 5K Studio Display at \
            "looks like 2560×1440"): launcher → Play → FalloutNV.exe pid 20197 \
            rendered, but its frame filled only the top-left quarter of the screen, \
            and the player called the speed "not great". FalloutPrefs.ini: iSize \
            3840×2160 fullscreen, iMultiSample=4, bTransparencyMultisampling=1, \
            iMaxAnisotropy=15, iPresentInterval=1; RendererInfo.txt: wined3d's \
            stand-in adapter "NVIDIA GeForce 8800 GTX" (the game sizes its \
            defaults from it). With RetinaMode=y Wine lists the desktop as \
            5120×2880 and every other mode at its point size, so "3840×2160" is the \
            1× 3840×2160 mode (the screenshot's menu bar is 1×). Quarter frame \
            (trace Oct 15 00:11): the game asks for the mode ~1.5 s after it \
            starts, before it is active, so winemac defers the switch; when it \
            lands, winemac's cached desktop rect and Retina flag stay on the old \
            5120×2880 desktop and it halves the 3840×2160 window to 1920×1080 pt. \
            Root fix in Wine (engine patch 0006, Pattern 54), not yet in an engine. \
            Meridian now also activates the game a launcher starts (activation \
            alone did not fix the frame, 00:06 run). \
            \
            SETTINGS FOR SPEED until the D3D9 → Metal path lands (Pattern 32): \
            2560×1440 (exactly half the 5K panel each way, so it scales sharp; \
            the same 1× path Half-Life 2 runs well on) and antialiasing off or 2×. \
            Not yet measured. Radio not yet checked.
            """
        ),

    ]
}
