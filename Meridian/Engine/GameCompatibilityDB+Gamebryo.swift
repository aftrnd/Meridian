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
            verifiedWith: "v4.3.1-engine",
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
            Root fix in Wine (engine patch 0006, Pattern 54), verified Oct 21 2026 on v4.3.1-engine: fullscreen 2560×1440 filled the 5K screen. \
            Meridian now also activates the game a launcher starts (activation \
            alone did not fix the frame, 00:06 run). \
            \
            STALL (Oct 21 2026, v4.2.0-engine, 1920×1080 windowed): menus ~118 \
            fps, then 1-3 fps about ten seconds into the world. The game's main \
            thread waited on Wine's DirectSound mixer, which used a full core: \
            every 32-bit Wine DLL was compiled to x87, which Rosetta runs slowly, \
            and dsound resamples each 44.1/22.05 kHz sound to the 48 kHz mix. \
            Fixed for every 32-bit game by building them with SSE math \
            (Pattern 60): 26-30 fps in the world on v4.2.1, 0 audio underruns. \
            \
            THE CEILING (Pattern 62): FalloutNV.exe is x87 code (69,791 x87 vs \
            740 SSE instructions), which Rosetta emulates in software, and its \
            Main thread was 100% busy on every renderer. DXVK → KosmicKrisp \
            (Pattern 61) ran it at 8-25 fps with pipeline-compile drops, worse \
            than wined3d, so it stays on wined3d. Best so far (v4.3.1-engine, \
            fullscreen 2560×1440, MSAA 2×, transparency MSAA off): 30-44 fps \
            between stalls; "most playable it's been", still choppy. Stalls of \
            2-3 s every 10-20 s on area changes and the Pip-Boy, and a long \
            quit, are the game's own Main-thread work (a +quartz trace shows no \
            DirectShow call blocking it longer than 0.8 s). The game polls its \
            music graphs every frame (IMediaControl::Run, GetCurrentPosition). \
            A winegstreamer quartz_parser deadlock (pin.flushing_cs) still hits \
            a background music thread in some sessions; open. \
            \
            SETTINGS: FalloutPrefs.ini overrides Fallout.ini, and on launch the \
            game copies Fallout_default.ini over Fallout.ini (byte-identical, \
            original timestamp), so tweaks belong in FalloutPrefs.ini, which the \
            launcher rewrites only when it re-detects the adapter (it did when \
            DXVK's Radeon replaced wined3d's GeForce). Threading switches \
            (bUseThreadedAI, bMultiThreadAudio, threaded particles, blood, \
            morpher) set there on Oct 21; not yet measured. Options › Windowed \
            lists only resolutions up to 1920×1080 (PCGamingWiki). Radio not yet \
            checked.
            """
        ),

    ]
}
