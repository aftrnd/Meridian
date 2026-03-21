import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "TerminationCleanup")

/// Kills all Wine/Steam processes owned by Meridian.
///
/// Designed to be called from `applicationShouldTerminate` on a background
/// thread so the main thread never blocks.
///
/// Shutdown sequence:
///   1. `wineserver -k` with the correct WINEPREFIX — proper Wine shutdown that
///      terminates all processes attached to our bottle cleanly, letting
///      CrossOver close associated macOS windows.
///   2. Brief pause for CrossOver to process the Wine session teardown.
///   3. `pkill -9 -f` fallbacks for any survivors — uses `-f` (full command-line
///      match) instead of `-x` (exact process name), which is more reliable
///      under CrossOver where binaries live in a path with spaces.
enum TerminationCleanup {

    /// Paths needed to run `wineserver -k` for our specific prefix at quit time.
    ///
    /// Populated by `WineSteamManager.startPersistent` and early in
    /// `BootstrapManager.runPipeline`. Using `nonisolated(unsafe)` is safe
    /// here because it is written once on the main actor during setup and
    /// read once on a background thread during termination — these phases
    /// never overlap.
    struct Context: Sendable {
        let wineserverPath: String
        let winePrefix: String
    }

    nonisolated(unsafe) static var context: Context?

    /// Terminates all Wine/Steam processes for Meridian's prefix.
    static func killAllWineProcesses() {
        log.info("[cleanup] starting Wine/Steam process cleanup")

        // 1. Proper Wine shutdown: wineserver -k kills every process in the prefix.
        if let ctx = context {
            log.info("[cleanup] running wineserver -k for prefix=\(ctx.winePrefix)")
            let t = Process()
            t.executableURL = URL(filePath: ctx.wineserverPath)
            t.arguments = ["-k"]
            t.environment = ["WINEPREFIX": ctx.winePrefix]
            t.standardOutput = FileHandle.nullDevice
            t.standardError = FileHandle.nullDevice
            try? t.run()
            t.waitUntilExit()
            log.info("[cleanup] wineserver -k exit=\(t.terminationStatus)")
        } else {
            log.warning("[cleanup] no context set — skipping wineserver -k (quit during early startup?)")
        }

        // 2. Brief pause so CrossOver can clean up macOS windows attached to the
        //    now-dead Wine session before we fall through to the pkill sweep.
        usleep(500_000) // 0.5 s

        // 3. pkill fallbacks — belt-and-suspenders for any survivors.
        //    Use -f (full command-line match) instead of -x (exact process name)
        //    because under CrossOver the binaries live inside
        //    "CrossOver-Hosted Application/" which may cause -x to miss them.
        log.info("[cleanup] pkill fallbacks")
        pkill(["-9", "-f", "steam.exe"])
        pkill(["-9", "-f", "wineserver"])
        pkill(["-9", "-f", "wineloader"])
        log.info("[cleanup] done")
    }

    @discardableResult
    private static func pkill(_ args: [String]) -> Int32 {
        let t = Process()
        t.executableURL = URL(filePath: "/usr/bin/pkill")
        t.arguments = args
        t.standardOutput = FileHandle.nullDevice
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        return t.terminationStatus
    }
}
