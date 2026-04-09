import Foundation

private let log = MeridianLog(category: "TerminationCleanup")

/// Kills all Wine/Steam processes owned by Meridian.
///
/// Called at both startup (to kill orphans from a previous session) and at
/// app termination. Uses an aggressive multi-sweep approach to ensure no
/// Wine processes are left behind.
///
/// Shutdown sequence:
///   1. `wineserver -k` with the correct WINEPREFIX — proper Wine shutdown that
///      tells every process attached to our bottle to exit cleanly.
///   2. Brief pause (0.5 s) for processes to drain.
///   3. Targeted `pkill -9` sweep for any survivors, keyed on our engine directory
///      path. macOS `pkill -f` matches against the actual exec binary path even when
///      Wine has replaced argv[0] with a Windows path (e.g. `C:\windows\...`), so
///      matching `com.meridian.app/engine` precisely catches our wine64 / wine-preloader
///      / wineserver processes without touching Wine processes from other applications.
///   4. Also kills any processes from `/tmp/meridian-engine/` — build artifacts from
///      `release-engine.sh` that can persist across reboots.
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
        /// The engine directory path (e.g. `.../com.meridian.app/engine`).
        /// Used as the `-f` pattern for the pkill sweep so we only kill
        /// processes whose binary lives inside our own engine tree.
        let engineDirPath: String
        /// Wine library path for DYLD_FALLBACK_LIBRARY_PATH — required so
        /// wineserver can locate its dynamic libraries at termination time.
        let libraryPath: String?
    }

    nonisolated(unsafe) static var context: Context?

    /// Terminates all Wine/Steam processes for Meridian's prefix.
    ///
    /// Shutdown sequence:
    ///   1. Kill `steamwebhelper` + `steam.exe` first — prevents "not responding" dialogs.
    ///   2. 100 ms micro-drain — let the kill signal land.
    ///   3. `wineserver -k` — proper Wine shutdown, signals all prefix clients to exit.
    ///   4. 1.5 s drain — time for processes to exit cleanly.
    ///   5. First pkill sweep — by engine path, bottles path, and /tmp/meridian-engine.
    ///   6. 1 s drain — time for late-spawning child processes to appear.
    ///   7. Second sweep — catches anything that respawned between steps 5 and 6.
    static func killAllWineProcesses() {
        let start = Date()
        log.info("[cleanup] starting Wine/Steam process cleanup")

        // 1. Kill steamwebhelper and steam.exe BEFORE wineserver -k.
        //    Killing steamwebhelper first prevents "steamwebhelper is not responding".
        //    Killing steam.exe prevents the "steamUI is not responding" window that
        //    appears when steam.exe is still alive after its webhelper dies.
        let swh1 = pkill(["-9", "-f", "steamwebhelper"])
        log.info("[cleanup] steamwebhelper pre-kill exit=\(swh1)")
        let stm1 = pkill(["-9", "-f", "steam.exe"])
        log.info("[cleanup] steam.exe pre-kill exit=\(stm1)")
        // Wine processes replace argv[0] with a Windows path after startup, so the
        // engine-path pkill below won't find them. Kill by the Windows path string
        // which still appears in their command line after the replacement.
        pkill(["-9", "-f", "steamservice.exe"])
        pkill(["-9", "-f", "winedevice.exe"])

        // 2. Brief pause — let the kill signal land before wineserver tears down.
        usleep(100_000) // 100 ms

        // 3. Proper Wine shutdown: wineserver -k tells every client process in
        //    the prefix to exit cleanly before tearing down the server itself.
        if let ctx = context {
            log.info("[cleanup] wineserver -k | prefix=\(ctx.winePrefix)")
            let t = Process()
            t.executableURL = URL(filePath: ctx.wineserverPath)
            t.arguments = ["-k"]
            var env: [String: String] = ["WINEPREFIX": ctx.winePrefix]
            if let lib = ctx.libraryPath {
                env["DYLD_FALLBACK_LIBRARY_PATH"] = lib
            }
            t.environment = env
            t.standardOutput = FileHandle.nullDevice
            t.standardError = FileHandle.nullDevice
            try? t.run()
            t.waitUntilExit()
            log.info("[cleanup] wineserver -k exit=\(t.terminationStatus)")
        } else {
            log.warning("[cleanup] no context — skipping wineserver -k (quit before engine was ready?)")
        }

        // 4. Extended drain — 1.5 s gives prefix processes time to exit after
        //    wineserver shuts down before the pkill sweep.
        usleep(1_500_000)

        // 5. First targeted pkill sweep.
        log.info("[cleanup] first pkill sweep")
        runSweep(context: context)

        // 6. Short pause — let late-spawning child processes appear before the
        //    second sweep catches them.
        usleep(1_000_000)

        // 7. Second sweep — catches anything that respawned between sweeps.
        log.info("[cleanup] second pkill sweep")
        runSweep(context: context)

        let elapsed = Date().timeIntervalSince(start)
        log.info("[cleanup] done — elapsed=\(String(format: "%.2f", elapsed))s")
    }

    private static func runSweep(context ctx: Context?) {
        if let ctx {
            pkill(["-9", "-f", ctx.engineDirPath])
            log.info("[cleanup] killed by engine path: \(ctx.engineDirPath)")
            pkill(["-9", "-f", "com.meridian.app/bottles"])
            log.info("[cleanup] killed by bottles path")
        } else {
            pkill(["-9", "-f", "com.meridian.app/engine"])
            pkill(["-9", "-f", "com.meridian.app/bottles"])
            log.info("[cleanup] killed by fallback bundle paths")
        }
        // Also kill any processes from the /tmp staging dir used by release-engine.sh.
        // These can persist after a build if the script was interrupted.
        pkill(["-9", "-f", "/tmp/meridian-engine"])
    }

    @discardableResult @inline(__always)
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
