package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	vsockPort          = 1234
	steamUID           = 1000
	steamGID           = 1000
	depotDownloaderBin = "/opt/depotdownloader/DepotDownloader"
)

var steamBootstrapOnce sync.Once
var bwrapBinaryPath = "/usr/bin/bwrap"
var unshareBinaryPath = "/usr/bin/unshare"
var steamDisplayMu sync.RWMutex
var steamDisplay = ":0"

// ── Wire protocol ─────────────────────────────────────────────────────────────

type cmd struct {
	Cmd     string `json:"cmd"`
	AppID   int    `json:"appid,omitempty"`
	SteamID string `json:"steamid,omitempty"`
	W       int    `json:"w,omitempty"`
	H       int    `json:"h,omitempty"`
}

type event struct {
	Event     string  `json:"event"`
	PID       int     `json:"pid,omitempty"`
	Code      int     `json:"code"`
	Line      string  `json:"line,omitempty"`
	AppID     int     `json:"appid,omitempty"`
	Pct       float64 `json:"pct,omitempty"`
	Installed *bool   `json:"installed,omitempty"`
}

// ── Main ──────────────────────────────────────────────────────────────────────

func main() {
	log.SetPrefix("[meridian-agent] ")
	log.SetFlags(log.LstdFlags)

	// Use golang.org/x/sys/unix for vsock — the stdlib syscall package's
	// anyToSockaddr() has no AF_VSOCK case and returns EAFNOSUPPORT on every
	// accepted connection, silently closing the fd.
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Fatalf("socket: %v", err)
	}

	// SO_REUSEADDR so a quick restart after a crash doesn't need to wait for
	// TIME_WAIT on the listening socket.
	if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1); err != nil {
		log.Printf("setsockopt SO_REUSEADDR: %v (continuing)", err)
	}

	addr := &unix.SockaddrVM{
		CID:  unix.VMADDR_CID_ANY,
		Port: vsockPort,
	}
	if err := unix.Bind(fd, addr); err != nil {
		unix.Close(fd)
		log.Fatalf("bind: %v", err)
	}
	if err := unix.Listen(fd, 8); err != nil {
		unix.Close(fd)
		log.Fatalf("listen: %v", err)
	}

	log.Printf("starting on vsock port %d", vsockPort)
	log.Printf("listening on vsock port %d", vsockPort)

	for {
		log.Printf("waiting for host connection...")
		// unix.Accept uses x/sys's anyToSockaddr which handles AF_VSOCK correctly.
		nfd, _, err := unix.Accept(fd)
		if err != nil {
			log.Printf("accept error: %v", err)
			time.Sleep(time.Second)
			continue
		}
		go handleConnection(nfd)
	}
}

// ── Connection handler ────────────────────────────────────────────────────────

func handleConnection(fd int) {
	// Wrap in an os.File so we get buffered I/O; os.File.Close also closes the fd.
	f := os.NewFile(uintptr(fd), "vsock")
	defer f.Close()

	enc := json.NewEncoder(f)
	scanner := bufio.NewScanner(f)

	sendEvent := func(e event) {
		if err := enc.Encode(e); err != nil {
			log.Printf("send event error: %v", err)
		}
	}

	sendLog := func(line string) {
		sendEvent(event{Event: "log", Line: line})
	}

	sendLog("meridian-agent connected")
	log.Printf("host connected")

	var gameProc *os.Process

	killGame := func() {
		if gameProc == nil {
			return
		}
		pid := gameProc.Pid
		// Kill the entire process group (Wine spawns wineserver, wineboot, the
		// game process, etc. — killing only the proton script leaves orphans).
		// Setpgid:true in launchViaProton gives Proton its own process group.
		// Negative PID sends SIGKILL to the group.
		syscall.Kill(-pid, syscall.SIGKILL) //nolint:errcheck
		gameProc.Kill()                     //nolint:errcheck
		gameProc = nil
	}

	for scanner.Scan() {
		line := scanner.Bytes()
		var c cmd
		if err := json.Unmarshal(line, &c); err != nil {
			sendLog(fmt.Sprintf("bad json: %v", err))
			continue
		}

		switch c.Cmd {
		case "launch":
			killGame()
			go func(appID int) {
				proc, err := launchGame(appID, sendEvent)
				if err != nil {
					sendLog(fmt.Sprintf("launch error: %v", err))
					sendEvent(event{Event: "exited", Code: 1})
					return
				}
				gameProc = proc
			}(c.AppID)

		case "install":
			go func(appID int) {
				installGame(appID, sendEvent)
			}(c.AppID)

		case "is_installed":
			installed := isGameInstalled(c.AppID)
			sendEvent(event{Event: "installed", AppID: c.AppID, Installed: boolPtr(installed)})

		case "stop":
			killGame()
			sendEvent(event{Event: "exited", Code: 0})

		case "resize":
			// Future: send resize signal to sway/wayland compositor.

		default:
			sendLog(fmt.Sprintf("unknown command: %s", c.Cmd))
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("connection read error: %v", err)
	}
	log.Printf("host disconnected")
}

// ── Game launcher ─────────────────────────────────────────────────────────────

func launchGame(appID int, sendEvent func(event)) (*os.Process, error) {
	emitLaunchDiagnostics(appID, sendEvent)

	// Try direct Proton launch first — no Steam client UI needed.
	proc, err := launchViaProton(appID, sendEvent)
	if err == nil {
		return proc, nil
	}
	sendEvent(event{Event: "log", Line: fmt.Sprintf("direct proton launch unavailable: %v — falling back to Steam client", err)})

	return launchViaSteamClient(appID, sendEvent)
}

// launchViaSteamClient is the legacy launch path that bootstraps the full Steam
// client and hands off via steam:// protocol URL.
func launchViaSteamClient(appID int, sendEvent func(event)) (*os.Process, error) {
	env, err := prepareSteamEnvironment(sendEvent)
	if err != nil {
		return nil, err
	}

	logSelectedEnv("launch env", env, sendEvent)
	logSteamProcessSnapshot(sendEvent, "launch before bootstrap")

	steamPID, err := ensureSteamReadyForHandoff(env, sendEvent, "launch", 600*time.Second)
	if err != nil {
		if strings.Contains(err.Error(), "IPC-ready") {
			logSteamConsoleLog(sendEvent, 40)
		}
		return nil, err
	}

	if err := handoffToSteam(appID, env, sendEvent, 90*time.Second); err != nil {
		return nil, fmt.Errorf("steam handoff failed: %w", err)
	}
	steamPID = waitForSteamPID(15 * time.Second)
	if steamPID <= 0 {
		return nil, fmt.Errorf("steam handoff completed but steam client never became active")
	}
	sendEvent(event{Event: "log", Line: fmt.Sprintf("launch handed off to steam (pid=%d)", steamPID)})
	sendEvent(event{Event: "started", PID: steamPID})
	return nil, nil
}

// launchViaProton launches a game directly through Proton without the Steam
// client UI. It parses the ACF manifest to discover the game's install
// directory and executable, then invokes `proton run`.
//
// Display strategy: prefer Wayland (sway compositor → virtio-gpu, which is
// what the host VZVirtualMachineView shows). Falls back to sway's XWayland
// on DISPLAY=:0 if the Wayland socket is unavailable.
func launchViaProton(appID int, sendEvent func(event)) (*os.Process, error) {
	manifest, err := findAppManifest(appID)
	if err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}

	installDir := parseACFValue(manifest, "installdir")
	if installDir == "" {
		return nil, fmt.Errorf("installdir not found in manifest")
	}

	steamappsDir := filepath.Dir(manifest)
	gamePath := filepath.Join(steamappsDir, "common", installDir)
	if _, err := os.Stat(gamePath); err != nil {
		return nil, fmt.Errorf("game directory not found: %s", gamePath)
	}

	exe, err := discoverGameExe(gamePath, appID)
	if err != nil {
		return nil, fmt.Errorf("game exe: %w", err)
	}

	protonDir, err := findProtonDir()
	if err != nil {
		return nil, fmt.Errorf("proton: %w", err)
	}
	protonBin := filepath.Join(protonDir, "proton")
	if _, err := os.Stat(protonBin); err != nil {
		return nil, fmt.Errorf("proton binary not found: %s", protonBin)
	}

	// Wait up to 20s for sway's XWayland to be ready on :0.
	// Sway starts XWayland early but it may not be ready immediately.
	xwaylandSocket := "/tmp/.X11-unix/X0"
	for i := 0; i < 20; i++ {
		if _, err := os.Stat(xwaylandSocket); err == nil {
			break
		}
		time.Sleep(time.Second)
	}
	if _, err := os.Stat(xwaylandSocket); err != nil {
		sendEvent(event{Event: "log", Line: "proton: WARNING: XWayland :0 not ready — game may not render"})
	}

	// Preserve existing wineprefix across launches. On first-ever launch,
	// Proton's wineboot initializes the prefix. Some 32-bit Wine drivers
	// (wineusb, winebus) crash under qemu-i386 but this is non-fatal — the
	// prefix is still usable for 64-bit games. We disable those drivers below.
	// We never delete an existing prefix: wineboot does not rerun once the
	// drive_c directory exists, so crashes only happen on the very first init.
	compatData := filepath.Join(steamappsDir, "compatdata", fmt.Sprintf("%d", appID))
	if err := os.MkdirAll(compatData, 0o755); err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("proton: mkdir compatdata: %v", err)})
	}
	_ = os.Chown(compatData, steamUID, steamGID)

	steamRoot := "/home/meridian/.local/share/Steam"

	// amd64 system lib paths prepended so wine64 (x86-64, Rosetta) finds
	// libfreetype, libfontconfig, etc. before Proton's bundled libs.
	amd64LibPath := "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"

	// Wine renders to X11 via Wine's X11 driver → sway's XWayland on :0
	// → sway compositor → virtio-gpu → VZVirtualMachineView on host.
	// SDL_VIDEODRIVER=wayland is irrelevant here: Animal Well bundles its own
	// Windows SDL2.dll which Wine loads — only DISPLAY (X11) matters.
	env := []string{
		"HOME=/home/meridian",
		"USER=meridian",
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"XDG_RUNTIME_DIR=/run/user/1000",
		"DISPLAY=:0",
		"WAYLAND_DISPLAY=wayland-1",
		"XDG_SESSION_TYPE=x11",
		"STEAM_COMPAT_DATA_PATH=" + compatData,
		"STEAM_COMPAT_CLIENT_INSTALL_PATH=" + steamRoot,
		"LD_LIBRARY_PATH=" + amd64LibPath,
		// DXVK translates DirectX to Vulkan. mesa-vulkan-drivers:amd64 provides
		// lavapipe (software Vulkan) and virtio (hardware Vulkan via Apple Metal).
		"DXVK_LOG_LEVEL=warn",
		// Disable wineusb.sys and winebus.sys kernel drivers. These drivers
		// spawn a 32-bit winedevice.exe process that crashes under qemu-i386
		// because the backing .so is missing from this Proton build. Disabling
		// them prevents the QEMU segfaults during wineprefix initialization.
		// Animal Well (64-bit, keyboard/mouse only) does not need USB or bus input.
		"WINEDLLOVERRIDES=wineusb.sys=;winebus.sys=",
		// Force 1280x720 to reduce rendering load on software/virtual GPU.
		"WINERES=1280x720",
		// Wine debug to stderr — PROTON_LOG intentionally NOT set so Wine output
		// reaches our attachCommandLogs stream instead of a log file.
		"WINEDEBUG=warn,err",
		"TERM=dumb",
	}

	sendEvent(event{Event: "log", Line: fmt.Sprintf(
		"proton launch: exe=%s proton=%s display=:0 (xwayland→sway→virtio-gpu)",
		exe, protonBin,
	)})

	cmd := exec.Command(protonBin, "run", exe)
	cmd.Dir = gamePath
	cmd.Env = env
	// New process group so we can kill Wine and all child processes cleanly.
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
		Setpgid:    true,
	}

	// Fix Wine's seccomp install warning about unlimited stack size.
	// Wine's install_bpf skips seccomp BPF when stack is unlimited.
	// Set to 8 MiB (standard Linux default) before exec.
	if err := syscall.Setrlimit(syscall.RLIMIT_STACK, &syscall.Rlimit{
		Cur: 8 * 1024 * 1024,
		Max: ^uint64(0), // RLIM_INFINITY
	}); err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("proton: setrlimit stack: %v (non-fatal)", err)})
	}
	attachCommandLogs("proton", cmd, sendEvent)

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("proton start: %w", err)
	}

	pid := cmd.Process.Pid
	sendEvent(event{Event: "started", PID: pid})

	go func() {
		state, _ := cmd.Process.Wait()
		code := 0
		if state != nil {
			code = state.ExitCode()
		}
		sendEvent(event{Event: "exited", Code: code})
	}()

	return cmd.Process, nil
}

// findAppManifest locates the appmanifest_<appID>.acf file across all known
// Steam library directories.
func findAppManifest(appID int) (string, error) {
	manifestName := fmt.Sprintf("appmanifest_%d.acf", appID)
	for _, dir := range steamLibrarySteamappsDirs() {
		path := filepath.Join(dir, manifestName)
		if _, err := os.Stat(path); err == nil {
			return path, nil
		}
	}
	return "", fmt.Errorf("appmanifest_%d.acf not found in any steam library", appID)
}

// parseACFValue extracts a top-level key value from a Valve ACF/VDF file.
// ACF format: "key" "value" on a single line (tab-indented).
func parseACFValue(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	quoted := regexp.MustCompile(`"([^"]*)"`)
	target := fmt.Sprintf(`"%s"`, key)
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if !strings.Contains(strings.ToLower(trimmed), strings.ToLower(target)) {
			continue
		}
		matches := quoted.FindAllStringSubmatch(trimmed, -1)
		if len(matches) >= 2 {
			return matches[1][1]
		}
	}
	return ""
}

// discoverGameExe searches the game directory for a likely Windows executable.
// Priority: launch config from appmanifest > .exe files in root > recursive search.
func discoverGameExe(gamePath string, appID int) (string, error) {
	manifest, _ := findAppManifest(appID)
	if manifest != "" {
		if exe := parseACFValue(manifest, "executable"); exe != "" {
			candidate := filepath.Join(gamePath, exe)
			if _, err := os.Stat(candidate); err == nil {
				return candidate, nil
			}
		}
	}

	entries, err := os.ReadDir(gamePath)
	if err != nil {
		return "", fmt.Errorf("read game dir: %w", err)
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if strings.HasSuffix(strings.ToLower(e.Name()), ".exe") {
			name := strings.ToLower(e.Name())
			if strings.Contains(name, "unins") || strings.Contains(name, "setup") ||
				strings.Contains(name, "redist") || strings.Contains(name, "vcredist") ||
				strings.Contains(name, "dxsetup") {
				continue
			}
			return filepath.Join(gamePath, e.Name()), nil
		}
	}

	// Recursive fallback: walk up to 2 levels deep.
	var found string
	filepath.WalkDir(gamePath, func(path string, d os.DirEntry, err error) error {
		if err != nil || found != "" {
			return filepath.SkipDir
		}
		rel, _ := filepath.Rel(gamePath, path)
		if strings.Count(rel, string(filepath.Separator)) > 2 {
			return filepath.SkipDir
		}
		if d.IsDir() {
			return nil
		}
		if strings.HasSuffix(strings.ToLower(d.Name()), ".exe") {
			name := strings.ToLower(d.Name())
			if strings.Contains(name, "unins") || strings.Contains(name, "setup") ||
				strings.Contains(name, "redist") || strings.Contains(name, "vcredist") ||
				strings.Contains(name, "dxsetup") || strings.Contains(name, "crash") {
				return nil
			}
			found = path
			return filepath.SkipAll
		}
		return nil
	})
	if found != "" {
		return found, nil
	}

	return "", fmt.Errorf("no .exe found in %s", gamePath)
}

// findProtonDir locates the newest Proton installation. Searches both the
// custom compatibility tools directory and the Steam-managed common directory.
func findProtonDir() (string, error) {
	searchPaths := []string{
		"/home/meridian/.local/share/Steam/compatibilitytools.d",
		"/home/meridian/.local/share/Steam/steamapps/common",
	}

	var best string
	for _, base := range searchPaths {
		entries, err := os.ReadDir(base)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			name := strings.ToLower(e.Name())
			if !strings.Contains(name, "proton") {
				continue
			}
			candidate := filepath.Join(base, e.Name())
			protonBin := filepath.Join(candidate, "proton")
			if _, err := os.Stat(protonBin); err != nil {
				continue
			}
			if best == "" || e.Name() > filepath.Base(best) {
				best = candidate
			}
		}
	}

	if best == "" {
		return "", fmt.Errorf("no proton installation found")
	}
	return best, nil
}

// ── Game installer ────────────────────────────────────────────────────────────

func installGame(appID int, sendEvent func(event)) {
	if _, err := os.Stat(depotDownloaderBin); err == nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("install via DepotDownloader (native arm64) appid=%d", appID)})
		if err := installViaDepotDownloader(appID, sendEvent); err != nil {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("DepotDownloader failed: %v — falling back to Steam client", err)})
		} else {
			return
		}
	} else {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("DepotDownloader not found at %s — falling back to Steam client", depotDownloaderBin)})
	}

	sendEvent(event{Event: "log", Line: fmt.Sprintf("install via Steam client appid=%d (legacy fallback)", appID)})
	installViaSteamClient(appID, sendEvent)
}

// installViaDepotDownloader uses DepotDownloader (native linux-arm64) to
// download a game via the SteamPipe CDN. No emulation, no GLX, no GUI.
func installViaDepotDownloader(appID int, sendEvent func(event)) error {
	username, password, err := readSessionCredentials(sendEvent)
	if err != nil {
		return fmt.Errorf("credentials: %w", err)
	}

	steamappsDir := "/home/meridian/.local/share/Steam/steamapps"
	appIDStr := fmt.Sprintf("%d", appID)
	gameDir := filepath.Join(steamappsDir, "common", appIDStr)

	for _, d := range []string{
		filepath.Join(steamappsDir, "common"),
		gameDir,
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("depotdl: mkdir %s: %v", d, err)})
		}
		_ = os.Chown(d, steamUID, steamGID)
	}

	args := []string{
		"-app", appIDStr,
		"-os", "windows",
		"-username", username,
		"-password", password,
		"-dir", gameDir,
		"-remember-password",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(ctx, depotDownloaderBin, args...)
	cmd.Dir = "/opt/depotdownloader"
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
	}
	cmd.Env = []string{
		"HOME=/home/meridian",
		"USER=meridian",
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"TERM=dumb",
		"DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1",
	}

	attachCommandLogs("depotdl", cmd, sendEvent)
	sendEvent(event{Event: "log", Line: fmt.Sprintf("depotdl: downloading to %s", gameDir)})

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("depotdl start: %w", err)
	}

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case err := <-done:
			if err != nil {
				return fmt.Errorf("depotdl exited: %w", err)
			}
			writeAppManifest(appID, appIDStr, steamappsDir, sendEvent)
			sendEvent(event{Event: "progress", AppID: appID, Pct: 100})
			sendEvent(event{Event: "installed", AppID: appID, Installed: boolPtr(true)})
			sendEvent(event{Event: "log", Line: fmt.Sprintf("depotdl: download complete appid=%d", appID)})
			return nil
		case <-ticker.C:
			sendEvent(event{Event: "log", Line: fmt.Sprintf("depotdl: download in progress appid=%d", appID)})
		}
	}
}

// writeAppManifest creates a minimal appmanifest ACF file so the Proton
// launcher can discover the game's install directory.
func writeAppManifest(appID int, installDir, steamappsDir string, sendEvent func(event)) {
	manifest := fmt.Sprintf(`"AppState"
{
	"appid"		"%d"
	"installdir"		"%s"
	"StateFlags"		"4"
}
`, appID, installDir)

	path := filepath.Join(steamappsDir, fmt.Sprintf("appmanifest_%d.acf", appID))
	if err := os.WriteFile(path, []byte(manifest), 0o644); err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("depotdl: write appmanifest failed: %v", err)})
		return
	}
	_ = os.Chown(path, steamUID, steamGID)
	sendEvent(event{Event: "log", Line: fmt.Sprintf("depotdl: wrote %s", path)})
}

// readSessionCredentials reads Steam username and password from the
// credentials.env file staged by the host via virtiofs.
func readSessionCredentials(sendEvent func(event)) (string, string, error) {
	const sessionMount = "/mnt/steam-session"

	if err := exec.Command("mountpoint", "-q", sessionMount).Run(); err != nil {
		if out, merr := exec.Command(
			"mount", "-t", "virtiofs", "meridian-steam-session", sessionMount,
		).CombinedOutput(); merr != nil {
			sendEvent(event{Event: "log", Line: fmt.Sprintf(
				"session mount failed: %v (%s)", merr, strings.TrimSpace(string(out)),
			)})
		}
	}

	credPath := filepath.Join(sessionMount, "credentials.env")
	data, err := os.ReadFile(credPath)
	if err != nil {
		return "", "", fmt.Errorf("no credentials.env: %w", err)
	}

	var steamUser, steamPass string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if u, ok := strings.CutPrefix(line, "STEAM_USER="); ok {
			steamUser = strings.Trim(u, `"'`)
		}
		if p, ok := strings.CutPrefix(line, "STEAM_PASS="); ok {
			steamPass = strings.Trim(p, `"'`)
		}
	}
	if steamUser == "" || steamPass == "" {
		return "", "", fmt.Errorf("STEAM_USER or STEAM_PASS missing in credentials.env")
	}
	return steamUser, steamPass, nil
}

// installViaSteamClient is the legacy install path using the full Steam client.
// Known broken: Steam's VGUI2 crashes at glXChooseVisual inside pressure-vessel.
// Kept only as a last-resort fallback.
func installViaSteamClient(appID int, sendEvent func(event)) {
	env, err := prepareSteamEnvironment(sendEvent)
	if err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("install error: %v", err)})
		sendEvent(event{Event: "installed", AppID: appID, Installed: boolPtr(false)})
		return
	}
	logSelectedEnv("install env", env, sendEvent)
	logSteamProcessSnapshot(sendEvent, "install before bootstrap")

	if _, err := ensureSteamReadyForHandoff(env, sendEvent, "install", 1800*time.Second); err != nil {
		if strings.Contains(err.Error(), "IPC-ready") {
			logSteamConsoleLog(sendEvent, 40)
		}
		sendEvent(event{Event: "log", Line: fmt.Sprintf("install error: %v", err)})
		sendEvent(event{Event: "installed", AppID: appID, Installed: boolPtr(false)})
		return
	}

	installTarget := fmt.Sprintf("steam://install/%d", appID)
	if err := handoffToSteamTarget(installTarget, env, sendEvent, 90*time.Second); err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("install error: steam install handoff failed: %v", err)})
		sendEvent(event{Event: "installed", AppID: appID, Installed: boolPtr(false)})
		return
	}

	const installTimeout = 20 * time.Minute
	deadline := time.Now().Add(installTimeout)
	lastHeartbeat := time.Now()
	lastReassert := time.Now()
	lastManifestDiag := time.Now()
	steamWasAlive := true
	var steamLogDumped bool
	for time.Now().Before(deadline) {
		if isGameInstalled(appID) {
			sendEvent(event{Event: "progress", AppID: appID, Pct: 100})
			sendEvent(event{Event: "installed", AppID: appID, Installed: boolPtr(true)})
			return
		}
		if time.Since(lastHeartbeat) >= 15*time.Second {
			elapsed := int(time.Since(deadline.Add(-installTimeout)).Seconds())
			sendEvent(event{Event: "log", Line: fmt.Sprintf("install waiting for appmanifest appid=%d elapsed=%ds", appID, elapsed)})
			logSteamProcessSnapshot(sendEvent, fmt.Sprintf("install wait elapsed=%ds", elapsed))
			lastHeartbeat = time.Now()
			nowAlive := isSteamActive()
			if steamWasAlive && !nowAlive && !steamLogDumped {
				sendEvent(event{Event: "log", Line: "steam exited unexpectedly during install wait — dumping steam log"})
				logSteamConsoleLog(sendEvent, 60)
				steamLogDumped = true
			}
			steamWasAlive = nowAlive
		}
		if time.Since(lastManifestDiag) >= 30*time.Second {
			logManifestCandidates(appID, sendEvent)
			lastManifestDiag = time.Now()
		}
		if time.Since(lastReassert) >= 30*time.Second {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("install handoff reassert appid=%d target=%s", appID, installTarget)})
			if err := handoffToSteamTarget(installTarget, env, sendEvent, 20*time.Second); err != nil {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("install handoff reassert failed appid=%d: %v", appID, err)})
			}
			lastReassert = time.Now()
		}
		time.Sleep(2 * time.Second)
	}

	sendEvent(event{Event: "log", Line: fmt.Sprintf("install completed but appmanifest missing for appid=%d", appID)})
	sendEvent(event{Event: "installed", AppID: appID, Installed: boolPtr(false)})
}

func prepareSteamEnvironment(sendEvent func(event)) ([]string, error) {
	if err := runSteamPreflight(sendEvent); err != nil {
		return nil, err
	}
	if err := waitForWaylandSocket(30 * time.Second); err != nil {
		return nil, err
	}
	// Ensure we have an X11 display with functional GLX visuals. A mere socket
	// file is not enough: Steam crashes if glXChooseVisual fails.
	display, err := ensureXDisplay(30*time.Second, sendEvent)
	if err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: X display not ready: %v — Steam GLX may fail", err)})
	} else {
		setSteamDisplay(display)
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: selected X display %s for Steam", display)})
	}

	// Emit preflight status here — after ensureXDisplay — so xdisplay_glx
	// reflects the actual state Steam will see, not a pre-Xvfb snapshot.
	emitSteamPreflightStatus(sendEvent)

	// Give meridian-session.sh time to start Steam; this avoids creating
	// duplicate wrappers while sway/session startup is still in flight.
	waitForSessionSteam(60*time.Second, sendEvent)
	return steamEnvironment(), nil
}

// ensureXDisplay returns a display name (e.g. :0 or :1) that has functional
// GLX visuals for Steam's VGUI2 path.
func ensureXDisplay(timeout time.Duration, sendEvent func(event)) (string, error) {
	if err := waitForXDisplay(timeout, sendEvent); err == nil {
		if probeXDisplayGLXOn(":0") {
			return ":0", nil
		}
		sendEvent(event{Event: "log", Line: "steam preflight: DISPLAY=:0 socket exists but GLX probe failed"})
	}
	// DISPLAY=:0 is missing or GLX-broken. Start a dedicated Xvfb display and
	// run Steam on it (without clobbering any existing X server on :0).
	sendEvent(event{Event: "log", Line: "steam preflight: no usable GLX display on :0; starting dedicated Xvfb display"})
	display, err := startXvfbDisplay(sendEvent)
	if err != nil {
		return "", err
	}
	return display, nil
}

// startXvfbDisplay picks a free display number and starts Xvfb with 24-bit
// depth + GLX + llvmpipe. It avoids killing existing X servers.
func startXvfbDisplay(sendEvent func(event)) (string, error) {
	for _, display := range []string{":1", ":2", ":3", ":4"} {
		socketPath := xDisplaySocketPathFor(display)
		if _, err := os.Stat(socketPath); err == nil {
			if probeXDisplayGLXOn(display) {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: reusing existing GLX-capable X display %s", display)})
				return display, nil
			}
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: display %s already present but GLX probe failed; trying another display", display)})
			continue
		}
		if started, err := startXvfbOnDisplay(display, sendEvent); started {
			return display, nil
		} else if err != nil {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: Xvfb start on %s failed: %v", display, err)})
		}
	}
	return "", fmt.Errorf("unable to provision a GLX-capable X display with Xvfb")
}

func startXvfbOnDisplay(display string, sendEvent func(event)) (bool, error) {
	socketPath := xDisplaySocketPathFor(display)
	lockPath := "/tmp/.X" + strings.TrimPrefix(display, ":") + "-lock"
	compatLockPath := "/tmp/.X11-unix/.X" + strings.TrimPrefix(display, ":") + "-lock"
	os.Remove(socketPath)     //nolint:errcheck
	os.Remove(lockPath)       //nolint:errcheck
	os.Remove(compatLockPath) //nolint:errcheck

	if err := os.MkdirAll("/tmp/.X11-unix", 0o1777); err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: mkdir /tmp/.X11-unix: %v", err)})
	}
	syscall.Chmod("/tmp/.X11-unix", 0o1777) //nolint:errcheck

	var stderrBuf bytes.Buffer
	cmd := exec.Command("/usr/bin/Xvfb", display,
		"-screen", "0", "1920x1080x24",
		"-ac",
		"+extension", "GLX",
		"-nolisten", "tcp",
	)
	cmd.Env = []string{
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"LIBGL_ALWAYS_SOFTWARE=1",
		"MESA_LOADER_DRIVER_OVERRIDE=llvmpipe",
		"GALLIUM_DRIVER=llvmpipe",
	}
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		return false, fmt.Errorf("failed to start Xvfb: %w", err)
	}
	pid := cmd.Process.Pid
	sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: started Xvfb %s pid=%d; waiting for socket", display, pid)})

	// Monitor for early exit in background so we can report it immediately.
	type waitResult struct{ err error }
	waitCh := make(chan waitResult, 1)
	go func() { waitCh <- waitResult{cmd.Wait()} }()

	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		// Did Xvfb exit before the socket appeared?
		select {
		case res := <-waitCh:
			stderr := strings.TrimSpace(stderrBuf.String())
			msg := fmt.Sprintf("Xvfb %s (pid=%d) exited before socket appeared", display, pid)
			if res.err != nil {
				msg += fmt.Sprintf(" (%v)", res.err)
			}
			if stderr != "" {
				msg += ": " + stderr
			}
			return false, fmt.Errorf("%s", msg)
		default:
		}

		if _, err := os.Stat(socketPath); err == nil {
			if probeXDisplayGLXOn(display) {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: Xvfb %s socket ready and GLX probe passed (pid=%d)", display, pid)})
				return true, nil
			}
			_ = cmd.Process.Kill()
			_, _ = cmd.Process.Wait()
			return false, fmt.Errorf("Xvfb %s socket ready but GLX probe failed", display)
		}
		time.Sleep(500 * time.Millisecond)
	}

	// One last wait-result drain and socket check.
	select {
	case res := <-waitCh:
		stderr := strings.TrimSpace(stderrBuf.String())
		msg := fmt.Sprintf("Xvfb %s (pid=%d) exited after 20s wait", display, pid)
		if res.err != nil {
			msg += fmt.Sprintf(" (%v)", res.err)
		}
		if stderr != "" {
			msg += ": " + stderr
		}
		return false, fmt.Errorf("%s", msg)
	default:
	}
	if _, err := os.Stat(socketPath); err == nil {
		if probeXDisplayGLXOn(display) {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: Xvfb %s socket ready and GLX probe passed (pid=%d)", display, pid)})
			return true, nil
		}
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
		return false, fmt.Errorf("Xvfb %s socket ready but GLX probe failed", display)
	}

	stderr := strings.TrimSpace(stderrBuf.String())
	msg := fmt.Sprintf("Xvfb %s started (pid=%d) but socket %s not ready after 20s", display, pid, socketPath)
	if stderr != "" {
		msg += ": " + stderr
	}
	_ = cmd.Process.Kill()
	_, _ = cmd.Process.Wait()
	return false, fmt.Errorf("%s", msg)
}

// xDisplaySocketPath is the canonical location of the X11 UNIX socket for
// DISPLAY=:0.  It is a variable (not a const) so tests can override it with
// a temp path without touching the real filesystem.
var xDisplaySocketPath = "/tmp/.X11-unix/X0"

func xDisplaySocketPathFor(display string) string {
	if display == ":0" {
		return xDisplaySocketPath
	}
	return "/tmp/.X11-unix/X" + strings.TrimPrefix(display, ":")
}

// waitForXDisplay polls xDisplaySocketPath until the X server socket appears
// or the timeout elapses. Steam's VGUI2 calls glXChooseVisual on DISPLAY=:0
// even during headless install/bootstrap; a missing socket causes an immediate
// fatal assert ("glXChooseVisual failed").
func waitForXDisplay(timeout time.Duration, sendEvent func(event)) error {
	return waitForXDisplayAt(xDisplaySocketPath, timeout, sendEvent)
}

// waitForXDisplayAt is the testable core of waitForXDisplay.
func waitForXDisplayAt(path string, timeout time.Duration, sendEvent func(event)) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			logXDisplayOwner(sendEvent)
			return nil
		}
		time.Sleep(time.Second)
	}
	if _, err := os.Stat(path); err == nil {
		logXDisplayOwner(sendEvent)
		return nil
	}
	return fmt.Errorf("X display socket %s not found after %s (XWayland/Xvfb may not be running)", path, timeout.Round(time.Second))
}

// logXDisplayOwner identifies what process is serving DISPLAY=:0 and emits it
// as a preflight log line. This makes it easy to see in launch/install logs
// whether GLX-capable XWayland or bare Xvfb is serving the display.
func logXDisplayOwner(sendEvent func(event)) {
	const xSocket = "/tmp/.X11-unix/X0"

	// Walk /proc to find any process that has the socket open.
	entries, err := os.ReadDir("/proc")
	if err != nil {
		sendEvent(event{Event: "log", Line: "steam preflight: X display :0 socket ready (owner unknown)"})
		return
	}

	// Resolve the device+inode of the unix socket we care about.
	var targetIno uint64
	if fi, err := os.Stat(xSocket); err == nil {
		if st, ok := fi.Sys().(*syscall.Stat_t); ok {
			targetIno = st.Ino
		}
	}

	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pid := e.Name()
		if pid == "" || pid[0] < '1' || pid[0] > '9' {
			continue
		}
		// Check /proc/<pid>/fd/* for a link to the target socket.
		fds, err := os.ReadDir("/proc/" + pid + "/fd")
		if err != nil {
			continue
		}
		for _, fd := range fds {
			fdPath := "/proc/" + pid + "/fd/" + fd.Name()
			fi, err := os.Stat(fdPath)
			if err != nil {
				continue
			}
			st, ok := fi.Sys().(*syscall.Stat_t)
			if !ok {
				continue
			}
			if targetIno > 0 && st.Ino != targetIno {
				continue
			}
			// Found the owning process; read its comm.
			comm := strings.TrimSpace(readFileString("/proc/" + pid + "/comm"))
			if comm == "" {
				comm = "unknown"
			}
			sendEvent(event{Event: "log", Line: fmt.Sprintf(
				"steam preflight: X display :0 socket ready — served by pid=%s comm=%s",
				pid, comm,
			)})
			return
		}
	}

	sendEvent(event{Event: "log", Line: "steam preflight: X display :0 socket ready (owner not found in /proc)"})
}

func readFileString(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

func runSteamPreflight(sendEvent func(event)) error {
	if err := ensureSteamCDNReachable(sendEvent); err != nil {
		return err
	}
	if err := ensureRosettaTranslation(sendEvent); err != nil {
		return err
	}
	if err := ensureUserNamespaces(sendEvent); err != nil {
		return err
	}
	if err := ensureSteamSandboxReady(sendEvent); err != nil {
		return err
	}
	if err := ensureSteamRuntime(sendEvent); err != nil {
		return err
	}
	// emitSteamPreflightStatus is intentionally NOT called here — it is called
	// in prepareSteamEnvironment after ensureXDisplay, so xdisplay_glx reflects
	// the state that Steam will actually see (Xvfb may be started by ensureXDisplay).
	return nil
}

func waitForWaylandSocket(timeout time.Duration) error {
	const waylandSocket = "/run/user/1000/wayland-1"
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(waylandSocket); err == nil {
			return nil
		}
		time.Sleep(time.Second)
	}
	if _, err := os.Stat(waylandSocket); err != nil {
		return fmt.Errorf("wayland socket not found after %s: %w", timeout.Round(time.Second), err)
	}
	return nil
}

func steamEnvironment() []string {
	display := getSteamDisplay()
	// Preserve baseline environment (especially PATH) then override session vars.
	// Steam is a shell launcher script and will fail quickly if PATH is missing.
	return mergedEnv(
		os.Environ(),
		map[string]string{
			"HOME":                                "/home/meridian",
			"USER":                                "meridian",
			"DISPLAY":                             display,
			"WAYLAND_DISPLAY":                     "wayland-1",
			"XDG_RUNTIME_DIR":                     "/run/user/1000",
			"DBUS_SESSION_BUS_ADDRESS":            "unix:path=/run/user/1000/bus",
			"STEAM_RUNTIME":                       "1",
			// Prefer host Mesa GL/DRM so steam-runtime does not use old pinned libs
			// that trigger glXChooseVisual failures.
			"STEAM_RUNTIME_PREFER_HOST_LIBRARIES": "1",
			"STEAM_DISABLE_ZENITY":                "1",
			"STEAM_SKIP_LIBRARIES_CHECK":          "1",
			"STEAMOS":                             "1",
			"GTK_A11Y":                            "none",
			"LIBGL_ALWAYS_SOFTWARE":       "1",
			"MESA_LOADER_DRIVER_OVERRIDE": "llvmpipe",
			"GALLIUM_DRIVER":              "llvmpipe",
			"__GLX_VENDOR_LIBRARY_NAME":   "mesa",
			// Prefer host i386 GL/DRM first, then Steam runtime fallback paths.
			"LD_LIBRARY_PATH": "/usr/lib/i386-linux-gnu:/lib/i386-linux-gnu:" +
				"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu:" +
				"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib32:" +
				"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/pinned_libs_32",
			"LIBGL_DRIVERS_PATH": "/usr/lib/i386-linux-gnu/dri:/usr/lib/x86_64-linux-gnu/dri:/usr/lib/aarch64-linux-gnu/dri",
			"XDG_SESSION_TYPE":         "wayland",
			"DEBIAN_FRONTEND":          "noninteractive",
			"APT_LISTCHANGES_FRONTEND": "none",
			"TERM":                     "dumb",
		},
	)
}

func ensureSteamReadyForHandoff(env []string, sendEvent func(event), purpose string, ipcTimeout time.Duration) (int, error) {
	selectedDisplay := getSteamDisplay()
	steamRunning := isSteamRunning()
	steamActive := isSteamActive()
	if steamRunning || steamActive {
		if selectedDisplay == ":0" {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam client already running; using existing session for %s", purpose)})
		} else {
			// Preflight selected a fallback display (:1 etc) because :0's GLX failed.
			// Session Steam was started with DISPLAY=:0 and will crash at glXChooseVisual.
			// Kill it and start fresh with our validated display.
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: killing session Steam (was on :0) to use validated display %s for %s", selectedDisplay, purpose)})
			terminateSteamProcesses(sendEvent, "display-mismatch")
			time.Sleep(2 * time.Second) // allow processes to exit
			loginArgs := setupSteamSessionFiles(sendEvent)
			args := append([]string{"-silent"}, loginArgs...)
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam process not running; starting client for %s (args: %v)", purpose, args)})
			if err := startSteamBootstrap(args, env, sendEvent, purpose); err != nil {
				return 0, err
			}
		}
	} else {
		loginArgs := setupSteamSessionFiles(sendEvent)
		args := append([]string{"-silent"}, loginArgs...)
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam process not running; starting client for %s (args: %v)", purpose, args)})
		if err := startSteamBootstrap(args, env, sendEvent, purpose); err != nil {
			return 0, err
		}
	}

	steamPID := findSteamBinaryPID()
	if steamPID <= 0 || !steamPipeExists() {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam %s bootstrap started; waiting for IPC socket before handoff", purpose)})
		steamPID = waitForSteamIPC(ipcTimeout, sendEvent)
		if steamPID <= 0 {
			return 0, fmt.Errorf("steam client did not become IPC-ready within %s", ipcTimeout.Round(time.Second))
		}
	}
	return steamPID, nil
}

func startSteamBootstrap(args []string, env []string, sendEvent func(event), purpose string) error {
	boot := exec.Command("/usr/bin/steam", args...)
	boot.Env = env
	boot.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
	}
	attachCommandLogs("steam-"+purpose+"-boot", boot, sendEvent)
	// steamdeps sometimes prompts for "press return" on first run; provide
	// non-interactive stdin so boot does not hit EOF and abort early.
	boot.Stdin = strings.NewReader("\n\n\n\n")
	if err := boot.Start(); err != nil {
		return fmt.Errorf("start steam bootstrap: %w", err)
	}
	go func() {
		if err := boot.Wait(); err != nil {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam %s bootstrap exited: %v", purpose, err)})
		}
	}()
	return nil
}

func isGameInstalled(appID int) bool {
	manifestName := fmt.Sprintf("appmanifest_%d.acf", appID)
	for _, steamappsDir := range steamLibrarySteamappsDirs() {
		manifest := filepath.Join(steamappsDir, manifestName)
		if _, err := os.Stat(manifest); err == nil {
			return true
		}
	}
	return false
}

func steamLibrarySteamappsDirs() []string {
	roots := []string{
		"/home/meridian/.local/share/Steam",
		"/home/meridian/.steam/steam",
		"/home/meridian/.steam/root",
	}
	seen := make(map[string]struct{})
	var dirs []string
	for _, root := range roots {
		// Primary library for this Steam root.
		addUniquePath(filepath.Join(root, "steamapps"), seen, &dirs)

		// Additional libraries configured by Steam.
		libraryVDF := filepath.Join(root, "steamapps", "libraryfolders.vdf")
		paths := parseLibraryFolders(libraryVDF)
		for _, libPath := range paths {
			addUniquePath(filepath.Join(libPath, "steamapps"), seen, &dirs)
		}
	}
	return dirs
}

func addUniquePath(path string, seen map[string]struct{}, out *[]string) {
	if path == "" {
		return
	}
	clean := filepath.Clean(path)
	if _, ok := seen[clean]; ok {
		return
	}
	seen[clean] = struct{}{}
	*out = append(*out, clean)
}

func parseLibraryFolders(vdfPath string) []string {
	b, err := os.ReadFile(vdfPath)
	if err != nil {
		return nil
	}
	quoted := regexp.MustCompile(`"([^"]*)"`)
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.Contains(line, `"path"`) {
			continue
		}
		matches := quoted.FindAllStringSubmatch(line, -1)
		if len(matches) < 2 {
			continue
		}
		// Expected line shape: "path" "/mnt/games"
		path := matches[1][1]
		path = strings.ReplaceAll(path, `\\`, `\`)
		path = strings.TrimSpace(path)
		if path == "" {
			continue
		}
		out = append(out, path)
	}
	return out
}

func boolPtr(v bool) *bool { return &v }

func emitLaunchDiagnostics(appID int, sendEvent func(event)) {
	sendEvent(event{Event: "log", Line: fmt.Sprintf("launch preflight appid=%d", appID)})

	if _, err := os.Stat("/dev/dri/renderD128"); err == nil {
		sendEvent(event{Event: "log", Line: "gpu: /dev/dri/renderD128 present"})
	} else {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("gpu: render node missing (%v)", err)})
	}

	protonPath := "/home/meridian/.local/share/Steam/compatibilitytools.d"
	if entries, err := os.ReadDir(protonPath); err == nil {
		var names []string
		for _, e := range entries {
			if e.IsDir() {
				names = append(names, e.Name())
			}
		}
		if len(names) == 0 {
			sendEvent(event{Event: "log", Line: "proton: no custom compatibility tools found"})
		} else {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("proton tools: %s", strings.Join(names, ", "))})
		}
	} else {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("proton path missing: %v", err)})
	}
}

// isSteamRunning returns true only when the actual Steam client binary is
// running and IPC-ready. The bash launcher wrapper (/usr/bin/steam) is NOT
// counted — it cannot accept steam:// protocol handoffs.
func isSteamRunning() bool {
	return findSteamBinaryPID() > 0
}

// isSteamActive returns true when any steam-related process is alive, including
// the bash launcher wrapper during its bootstrap phase. Use this instead of
// isSteamRunning when deciding whether to start a new Steam instance, to avoid
// spawning a duplicate while an existing one is still initialising.
func isSteamActive() bool {
	cmd := exec.Command("/bin/ps", "-u", fmt.Sprintf("%d", steamUID), "-o", "pid=,comm=,args=")
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		lower := strings.ToLower(line)
		if (strings.Contains(lower, "steam") || strings.Contains(lower, "steamwebhelper")) &&
			!strings.Contains(lower, "steamdeps") &&
			!strings.Contains(lower, "zenity") &&
			!strings.Contains(lower, "srt-logger") {
			return true
		}
	}
	return false
}

// waitForSessionSteam polls isSteamActive for up to timeout after the Wayland
// socket has appeared. The boot path is:
//
//	systemd → getty autologin → bash .bash_profile → exec sway
//	→ sway exec meridian-session.sh → steam -silent
//
// The meridian-agent starts accepting connections seconds after the kernel
// boots, well before sway and the session script have had time to run.
// Without this wait, the agent sees no Steam, starts its own bare instance,
// and that bare instance exits immediately because the VDF session files have
// not yet been copied from the virtiofs share by meridian-session.sh.
func waitForSessionSteam(timeout time.Duration, sendEvent func(event)) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if isSteamActive() {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	sendEvent(event{Event: "log", Line: fmt.Sprintf(
		"session-script Steam did not appear within %s; will start Steam directly",
		timeout.Round(time.Second),
	)})
}

// setupSteamSessionFiles replicates the credential-setup portion of
// meridian-session.sh so the agent can start a usable Steam instance when
// the session script has not yet run (e.g. early install/launch commands that
// arrive before sway has finished starting).
//
// It mounts the meridian-steam-session virtiofs share (if not already mounted),
// copies loginusers.vdf / config.vdf / registry.vdf into Steam's config
// directory, and returns any +login args required by the credentials.env
// fallback path (for users without a macOS Steam installation).
func setupSteamSessionFiles(sendEvent func(event)) []string {
	const (
		sessionMount = "/mnt/steam-session"
		steamCfg     = "/home/meridian/.local/share/Steam/config"
		steamHome    = "/home/meridian/.local/share/Steam"
	)

	// Mount the virtiofs share if it is not already present.
	if err := exec.Command("mountpoint", "-q", sessionMount).Run(); err != nil {
		if out, merr := exec.Command(
			"mount", "-t", "virtiofs", "meridian-steam-session", sessionMount,
		).CombinedOutput(); merr != nil {
			sendEvent(event{Event: "log", Line: fmt.Sprintf(
				"steam session: virtiofs mount failed: %v (%s)", merr, strings.TrimSpace(string(out)),
			)})
		} else {
			sendEvent(event{Event: "log", Line: "steam session: mounted meridian-steam-session virtiofs share"})
		}
	}

	if err := os.MkdirAll(steamCfg, 0o755); err == nil {
		os.Chown(steamCfg, steamUID, steamGID)
	}

	// Copy the two main VDF files that Steam needs to restore a cached login.
	for _, f := range []string{"loginusers.vdf", "config.vdf"} {
		src := ""
		if _, err := os.Stat(filepath.Join(sessionMount, "config", f)); err == nil {
			src = filepath.Join(sessionMount, "config", f)
		} else if _, err := os.Stat(filepath.Join(sessionMount, f)); err == nil {
			src = filepath.Join(sessionMount, f)
		}
		if src == "" {
			continue
		}
		dst := filepath.Join(steamCfg, f)
		if data, err := os.ReadFile(src); err == nil {
			if werr := os.WriteFile(dst, data, 0o644); werr == nil {
				os.Chown(dst, steamUID, steamGID)
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam session: copied %s", f)})
			}
		}
	}

	// registry.vdf lives one level above config/.
	if src := filepath.Join(sessionMount, "registry.vdf"); func() bool {
		_, err := os.Stat(src)
		return err == nil
	}() {
		dst := filepath.Join(steamHome, "registry.vdf")
		if data, err := os.ReadFile(src); err == nil {
			if werr := os.WriteFile(dst, data, 0o644); werr == nil {
				os.Chown(dst, steamUID, steamGID)
				sendEvent(event{Event: "log", Line: "steam session: copied registry.vdf"})
			}
		}
	}

	// Device-auth tokens copied from the host Steam install.
	if copied := copySessionTokenFiles(sessionMount, steamHome); copied > 0 {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam session: copied %d ssfn token file(s)", copied)})
	}

	// credentials.env fallback: used when no macOS Steam VDF files are staged.
	// If loginusers.vdf was not found above, fall back to username/password login.
	if _, err := os.Stat(filepath.Join(steamCfg, "loginusers.vdf")); err != nil {
		credPath := filepath.Join(sessionMount, "credentials.env")
		if data, err := os.ReadFile(credPath); err == nil {
			var steamUser, steamPass string
			for _, line := range strings.Split(string(data), "\n") {
				line = strings.TrimSpace(line)
				if u, ok := strings.CutPrefix(line, "STEAM_USER="); ok {
					steamUser = strings.Trim(u, `"`)
				}
				if p, ok := strings.CutPrefix(line, "STEAM_PASS="); ok {
					steamPass = strings.Trim(p, `"`)
				}
			}
			if steamUser != "" && steamPass != "" {
				sendEvent(event{Event: "log", Line: "steam session: using credentials.env for +login"})
				return []string{"+login", steamUser, steamPass}
			}
		}
	}
	return nil
}

func copySessionTokenFiles(sessionMount, steamHome string) int {
	entries, err := os.ReadDir(sessionMount)
	if err != nil {
		return 0
	}
	copied := 0
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "ssfn") {
			continue
		}
		src := filepath.Join(sessionMount, name)
		dst := filepath.Join(steamHome, name)
		data, err := os.ReadFile(src)
		if err != nil {
			continue
		}
		if err := os.WriteFile(dst, data, 0o600); err != nil {
			continue
		}
		_ = os.Chown(dst, steamUID, steamGID)
		copied++
	}
	return copied
}

// ensureSteamCDNReachable verifies the VM can reach Steam's update servers.
// Steam fails with "http error 0" / "needs to be online to update" when the
// guest has no working outbound connectivity. Fail fast here with actionable
// guidance instead of letting Steam sit in a loop.
func ensureSteamCDNReachable(sendEvent func(event)) error {
	const (
		steamCDNURL = "https://client-update.steamstatic.com"
		maxAttempts = 6
		retryDelay  = 5 * time.Second
	)

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: checking VM network connectivity (attempt %d/%d)", attempt, maxAttempts)})
		// Do not use curl -f here: Steam CDN can legitimately return 403 for this
		// probe URL, which still proves DNS + TCP + TLS reachability.
		cmd := exec.Command("curl", "-sS", "--max-time", "15", "-o", "/dev/null", "-w", "%{http_code}", steamCDNURL)
		cmd.Env = mergedEnv(
			os.Environ(),
			map[string]string{"HOME": "/home/meridian", "USER": "meridian"},
		)
		cmd.SysProcAttr = &syscall.SysProcAttr{
			Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
		}
		out, err := cmd.CombinedOutput()
		code := strings.TrimSpace(string(out))
		if err == nil && code != "" && code != "000" {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: VM network connectivity OK (Steam CDN reachable, HTTP %s)", code)})
			return nil
		}
		msg := strings.TrimSpace(string(out))
		if msg != "" {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: curl failed: %s", msg)})
		} else {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: curl failed: %v", err)})
		}
		lowerMsg := strings.ToLower(msg)
		if strings.Contains(lowerMsg, "could not resolve host") ||
			strings.Contains(lowerMsg, "name or service not known") ||
			strings.Contains(lowerMsg, "temporary failure in name resolution") {
			sendEvent(event{Event: "log", Line: "steam preflight: DNS resolution failed; attempting resolver repair"})
			if attempt == 1 {
				emitNetworkDiagnostics(sendEvent)
			}
			repairDNSResolver(sendEvent)
			if attempt >= 2 {
				ensureSteamHostFallback(sendEvent)
			}
		}
		if attempt == 2 {
			// Attempt to refresh DHCP on primary interface; sometimes the interface
			// is up but routing/DNS isn't ready yet. Agent runs as root.
			sendEvent(event{Event: "log", Line: "steam preflight: attempting DHCP refresh on default interface"})
			iface := detectPrimaryInterface()
			if iface != "" {
				exec.Command("dhclient", "-r", iface).Run()
				exec.Command("dhclient", iface).Run()
			} else if out, err := exec.Command("sh", "-c", "ls /sys/class/net/ | grep -E '^en|^eth' | head -1").Output(); err == nil {
				iface = strings.TrimSpace(string(out))
				if iface != "" {
					exec.Command("dhclient", iface).Run()
				}
			}
			repairDNSResolver(sendEvent)
		}
		if attempt < maxAttempts {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: retrying in %s", retryDelay)})
			time.Sleep(retryDelay)
		}
	}
	return fmt.Errorf(
		"VM cannot reach Steam CDN (%s); Steam will fail with 'needs to be online to update'. "+
			"Check: host internet, VPN/proxy, macOS firewall. VZNAT may not work with some VPNs.",
		steamCDNURL,
	)
}

func emitNetworkDiagnostics(sendEvent func(event)) {
	commands := []struct {
		label string
		args  []string
	}{
		{label: "ip -brief link", args: []string{"ip", "-brief", "link"}},
		{label: "ip -brief addr", args: []string{"ip", "-brief", "addr"}},
		{label: "ip route", args: []string{"ip", "route"}},
		{label: "resolv.conf", args: []string{"sh", "-c", "sed -n '1,20p' /etc/resolv.conf"}},
	}
	for _, c := range commands {
		out, err := exec.Command(c.args[0], c.args[1:]...).CombinedOutput()
		text := strings.TrimSpace(string(out))
		if text == "" && err != nil {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight diag: %s failed: %v", c.label, err)})
			continue
		}
		if text != "" {
			text = strings.ReplaceAll(text, "\n", " | ")
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight diag: %s => %s", c.label, text)})
		}
	}
}

func detectPrimaryInterface() string {
	if out, err := exec.Command("sh", "-c", "ip -o route get 1.1.1.1 2>/dev/null | grep -oE 'dev [^ ]+' | cut -d' ' -f2").Output(); err == nil && len(out) > 0 {
		iface := strings.TrimSpace(string(out))
		if iface != "" {
			return iface
		}
	}
	if out, err := exec.Command("sh", "-c", "ls /sys/class/net/ | grep -E '^en|^eth' | head -1").Output(); err == nil {
		iface := strings.TrimSpace(string(out))
		if iface != "" {
			return iface
		}
	}
	return ""
}

func repairDNSResolver(sendEvent func(event)) {
	iface := detectPrimaryInterface()
	gateway := detectDefaultGatewayIPv4()

	servers := []string{}
	if gateway != "" {
		servers = append(servers, gateway)
	}
	servers = append(servers, "1.1.1.1", "8.8.8.8")

	// Configure systemd-resolved with both VZNAT gateway DNS and public fallbacks.
	dropIn := fmt.Sprintf("[Resolve]\nDNS=%s\nFallbackDNS=1.1.1.1 8.8.8.8\n", strings.Join(servers, " "))
	if err := os.MkdirAll("/etc/systemd/resolved.conf.d", 0o755); err == nil {
		if werr := os.WriteFile("/etc/systemd/resolved.conf.d/meridian-runtime-dns.conf", []byte(dropIn), 0o644); werr == nil {
			exec.Command("systemctl", "restart", "systemd-resolved").Run()
		}
	}

	if iface != "" {
		args := append([]string{"dns", iface}, servers...)
		if out, err := exec.Command("resolvectl", args...).CombinedOutput(); err != nil {
			if text := strings.TrimSpace(string(out)); text != "" {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: resolvectl dns output: %s", text)})
			}
		}
		exec.Command("resolvectl", "domain", iface, "~.").Run()
		exec.Command("resolvectl", "flush-caches").Run()
	}

	const resolvConfPath = "/etc/resolv.conf"
	data, err := os.ReadFile(resolvConfPath)
	if err != nil || !hasRealNameserver(data) {
		fallback := "options timeout:2 attempts:2\n"
		if gateway != "" {
			fallback += "nameserver " + gateway + "\n"
		}
		fallback += "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
		if werr := os.WriteFile(resolvConfPath, []byte(fallback), 0o644); werr == nil {
			sendEvent(event{Event: "log", Line: "steam preflight: wrote fallback DNS to /etc/resolv.conf"})
		} else {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: failed to write /etc/resolv.conf: %v", werr)})
		}
	}
}

func detectDefaultGatewayIPv4() string {
	out, err := exec.Command("sh", "-c", "ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1").Output()
	if err != nil {
		return ""
	}
	gw := strings.TrimSpace(string(out))
	if gw == "" {
		return ""
	}
	if regexp.MustCompile(`^\d{1,3}(\.\d{1,3}){3}$`).MatchString(gw) {
		return gw
	}
	return ""
}

func ensureSteamHostFallback(sendEvent func(event)) {
	const steamHost = "client-update.steamstatic.com"
	ip, err := resolveHostViaDoH(steamHost)
	if err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: DoH fallback failed: %v", err)})
		return
	}
	if err := upsertHostsEntry(steamHost, ip); err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: failed to update /etc/hosts: %v", err)})
		return
	}
	sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: added /etc/hosts fallback %s -> %s", steamHost, ip)})
}

func resolveHostViaDoH(host string) (string, error) {
	url := fmt.Sprintf("https://cloudflare-dns.com/dns-query?name=%s&type=A", host)
	cmd := exec.Command(
		"curl",
		"-sSf",
		"--max-time", "10",
		"--resolve", "cloudflare-dns.com:443:1.1.1.1",
		"-H", "accept: application/dns-json",
		url,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("curl DoH request failed: %s", strings.TrimSpace(string(out)))
	}
	re := regexp.MustCompile(`"data"\s*:\s*"((?:\d{1,3}\.){3}\d{1,3})"`)
	matches := re.FindSubmatch(out)
	if len(matches) < 2 {
		return "", fmt.Errorf("no A record returned")
	}
	return string(matches[1]), nil
}

func upsertHostsEntry(host, ip string) error {
	const hostsPath = "/etc/hosts"
	const marker = "# meridian-steam-dns"

	data, _ := os.ReadFile(hostsPath)
	lines := []string{}
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			lines = append(lines, line)
			continue
		}
		if strings.Contains(trimmed, marker) || strings.HasSuffix(trimmed, " "+host) {
			continue
		}
		lines = append(lines, line)
	}
	lines = append(lines, fmt.Sprintf("%s %s %s", ip, host, marker))
	content := strings.TrimRight(strings.Join(lines, "\n"), "\n") + "\n"
	return os.WriteFile(hostsPath, []byte(content), 0o644)
}

func hasRealNameserver(data []byte) bool {
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if !strings.HasPrefix(line, "nameserver ") {
			continue
		}
		ns := strings.TrimSpace(strings.TrimPrefix(line, "nameserver "))
		if ns == "" || ns == "127.0.0.53" || ns == "::1" {
			continue
		}
		return true
	}
	return false
}

func ensureRosettaTranslation(sendEvent func(event)) error {
	if isRosettaBinfmtEnabled() && verifyKnownX86Binary() == nil {
		return nil
	}

	sendEvent(event{Event: "log", Line: "steam preflight: x86_64 translation not active; attempting rosetta setup"})

	// First, try the systemd unit path used at boot.
	if out, err := exec.Command("/usr/bin/systemctl", "start", "rosetta-setup.service").CombinedOutput(); err != nil {
		if text := strings.TrimSpace(string(out)); text != "" {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: rosetta-setup.service start output: %s", text)})
		}
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: rosetta-setup.service start failed: %v", err)})
	}
	if isRosettaBinfmtEnabled() && verifyKnownX86Binary() == nil {
		sendEvent(event{Event: "log", Line: "steam preflight: rosetta binfmt active"})
		return nil
	}

	// Fallback: run setup script directly for immediate diagnostics.
	out, err := exec.Command("/usr/local/bin/setup-rosetta.sh").CombinedOutput()
	if text := strings.TrimSpace(string(out)); text != "" {
		for _, line := range strings.Split(text, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			sendEvent(event{Event: "log", Line: fmt.Sprintf("rosetta-setup: %s", line)})
		}
	}
	if err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: setup-rosetta.sh failed: %v", err)})
	}
	if isRosettaBinfmtEnabled() && verifyKnownX86Binary() == nil {
		sendEvent(event{Event: "log", Line: "steam preflight: rosetta binfmt active"})
		return nil
	}

	return fmt.Errorf("x86_64 translation is unavailable in guest (rosetta binfmt not active); Steam runtime cannot execute x86 binaries")
}

func isRosettaBinfmtEnabled() bool {
	data, err := os.ReadFile("/proc/sys/fs/binfmt_misc/rosetta")
	if err != nil {
		return false
	}
	return strings.Contains(string(data), "enabled")
}

func verifyKnownX86Binary() error {
	candidates := []string{
		"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/libexec/steam-runtime-tools-0/srt-logger",
		"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/amd64/usr/bin/steam-runtime-identify-library-abi",
	}
	for _, path := range candidates {
		if _, err := os.Stat(path); err != nil {
			continue
		}
		cmd := exec.Command(path, "--version")
		err := cmd.Run()
		// Non-zero exit from an executed binary is acceptable; ENOEXEC is not.
		if err == nil {
			return nil
		}
		if _, ok := err.(*exec.ExitError); ok {
			return nil
		}
		return fmt.Errorf("x86 binary sanity check failed for %s: %w", path, err)
	}
	// Steam runtime not extracted yet; defer verification to first boot/install.
	return nil
}

func emitSteamPreflightStatus(sendEvent func(event)) {
	maxVal, _ := readProcInt("/proc/sys/user/max_user_namespaces")
	clone := "n/a"
	if _, err := os.Stat("/proc/sys/kernel/unprivileged_userns_clone"); err == nil {
		if v, err := readProcInt("/proc/sys/kernel/unprivileged_userns_clone"); err == nil {
			clone = strconv.Itoa(v)
		} else {
			clone = "error"
		}
	}
	// xdisplay_glx is driven by glxProber — an injectable function that actually
	// tests glXChooseVisual, not just socket file presence.  A stale socket left
	// behind by a crashed XWayland would pass an os.Stat check but fail here.
	display := getSteamDisplay()
	xdisplayGLX := hasXDisplaySocketAt(xDisplaySocketPathFor(display)) && displayHasGLX(display)
	sendEvent(event{
		Event: "log",
		Line: fmt.Sprintf(
			"steam preflight status: display=%s rosetta_binfmt=%t libc32=%t libcap_amd64=%t libGL_i386=%t libdrm_i386=%t libGLdispatch_i386=%t xdisplay_glx=%t user.max_user_namespaces=%d kernel.unprivileged_userns_clone=%s",
			display,
			isRosettaBinfmtEnabled(),
			has32BitLibc(),
			hasAmd64Libcap(),
			hasI386LibGL(),
			hasI386LibDRM(),
			hasI386LibGLDispatch(),
			xdisplayGLX,
			maxVal,
			clone,
		),
	})
}

// glxProber is the function used to verify that the X display has working GLX
// visuals.  It is a package-level variable so tests can inject a fake prober
// without launching python3 or needing a real X server.
//
// IMPORTANT: This probe runs as an aarch64 native Python process.  The full
// Steam client is i386 and crashes at glXChooseVisual inside pressure-vessel
// regardless of env vars.  Game installation now uses DepotDownloader (native
// arm64) which needs no display.  This probe is retained for Proton game
// rendering which still needs a working X display.
var glxProber = probeXDisplayGLX

// glxProbeScript is a self-contained Python script that replicates the exact
// glXChooseVisual call made by Steam's VGUI2 surface layer.  It prints "PASS"
// if a suitable visual is found, "FAIL" otherwise.  All errors are non-fatal
// (the script always exits 0) so the Go caller can inspect stdout only.
//
// Attribute list: GLX_RGBA=4, GLX_DOUBLEBUFFER=5, GLX_DEPTH_SIZE=12 (value
// 24) — this matches the Steam source at src/vgui2/src/surface_linux.cpp:1956.
const glxProbeScript = `import ctypes, ctypes.util, sys, os
def load(name, fb):
    l = ctypes.util.find_library(name)
    try: return ctypes.CDLL(l or fb)
    except OSError: return None
libX11 = load("X11", "libX11.so.6")
libGL  = load("GL",  "libGL.so.1")
if not libX11 or not libGL:
    print("FAIL"); sys.exit(0)
libX11.XOpenDisplay.restype  = ctypes.c_void_p
libX11.XOpenDisplay.argtypes = [ctypes.c_char_p]
libX11.XDefaultScreen.restype  = ctypes.c_int
libX11.XDefaultScreen.argtypes = [ctypes.c_void_p]
libGL.glXChooseVisual.restype  = ctypes.c_void_p
libGL.glXChooseVisual.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                   ctypes.POINTER(ctypes.c_int)]
dpy = libX11.XOpenDisplay(None)
if not dpy: print("FAIL"); sys.exit(0)
screen  = libX11.XDefaultScreen(dpy)
attribs = (ctypes.c_int * 6)(4, 5, 12, 24, 0, 0)
vi      = libGL.glXChooseVisual(dpy, screen, attribs)
print("PASS" if vi else "FAIL")
`

// probeXDisplayGLX runs the Python glXChooseVisual probe against DISPLAY=:0
// and returns true only when a valid visual is found.  Uses indirect rendering
// to match Steam's runtime environment (no client-side DRI driver loading).
func probeXDisplayGLX() bool {
	return probeXDisplayGLXOn(":0")
}

func displayHasGLX(display string) bool {
	if display == ":0" {
		return glxProber()
	}
	return probeXDisplayGLXOn(display)
}

func probeXDisplayGLXOn(display string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "python3", "-c", glxProbeScript)
	cmd.Env = append(os.Environ(),
		"DISPLAY="+display,
		"LIBGL_ALWAYS_SOFTWARE=1",
		"MESA_LOADER_DRIVER_OVERRIDE=llvmpipe",
		"GALLIUM_DRIVER=llvmpipe",
	)
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == "PASS"
}

// hasXDisplaySocket returns true when the X11 display socket for :0 is present.
// This is a necessary (but not sufficient) condition — use glxProber() for the
// full GLX availability check.  hasXDisplaySocket is used as a fast pre-gate
// to skip the glxProber call when the socket is obviously absent.
func hasXDisplaySocket() bool {
	return hasXDisplaySocketAt(xDisplaySocketPath)
}

// hasXDisplaySocketAt is the testable core of hasXDisplaySocket.
func hasXDisplaySocketAt(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func setSteamDisplay(display string) {
	if display == "" {
		return
	}
	steamDisplayMu.Lock()
	steamDisplay = display
	steamDisplayMu.Unlock()
}

func getSteamDisplay() string {
	steamDisplayMu.RLock()
	defer steamDisplayMu.RUnlock()
	return steamDisplay
}

func has32BitLibc() bool {
	paths := []string{
		"/lib/i386-linux-gnu/libc.so.6",
		"/usr/lib/i386-linux-gnu/libc.so.6",
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

func hasAmd64Libcap() bool {
	paths := []string{
		"/lib/x86_64-linux-gnu/libcap.so.2",
		"/usr/lib/x86_64-linux-gnu/libcap.so.2",
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

func hasI386LibGL() bool {
	paths := []string{
		"/usr/lib/i386-linux-gnu/libGL.so.1",
		"/lib/i386-linux-gnu/libGL.so.1",
		"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu/libGL.so.1",
		"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/pinned_libs_32/libGL.so.1",
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

func hasI386LibDRM() bool {
	paths := []string{
		"/usr/lib/i386-linux-gnu/libdrm.so.2",
		"/lib/i386-linux-gnu/libdrm.so.2",
		"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu/libdrm.so.2",
		"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/pinned_libs_32/libdrm.so.2",
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

func hasI386LibGLDispatch() bool {
	paths := []string{
		"/usr/lib/i386-linux-gnu/libGLdispatch.so.0",
		"/lib/i386-linux-gnu/libGLdispatch.so.0",
		"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu/libGLdispatch.so.0",
		"/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/pinned_libs_32/libGLdispatch.so.0",
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

func ensureUserNamespaces(sendEvent func(event)) error {
	maxPath := "/proc/sys/user/max_user_namespaces"
	maxVal, err := readProcInt(maxPath)
	if err != nil {
		return fmt.Errorf("steam requires user namespaces, but %s is unavailable: %w", maxPath, err)
	}
	if maxVal <= 0 {
		if err := os.WriteFile(maxPath, []byte("28633\n"), 0o644); err != nil {
			return fmt.Errorf("steam requires user namespaces enabled; could not set %s=28633: %w", maxPath, err)
		}
		sendEvent(event{Event: "log", Line: "steam preflight: enabled user.max_user_namespaces=28633"})
	}

	clonePath := "/proc/sys/kernel/unprivileged_userns_clone"
	if _, statErr := os.Stat(clonePath); statErr == nil {
		cloneVal, err := readProcInt(clonePath)
		if err != nil {
			return fmt.Errorf("steam requires unprivileged user namespaces, but %s is unreadable: %w", clonePath, err)
		}
		if cloneVal <= 0 {
			if err := os.WriteFile(clonePath, []byte("1\n"), 0o644); err != nil {
				return fmt.Errorf("steam requires unprivileged user namespaces enabled; could not set %s=1: %w", clonePath, err)
			}
			sendEvent(event{Event: "log", Line: "steam preflight: enabled kernel.unprivileged_userns_clone=1"})
		}
	} else if !os.IsNotExist(statErr) {
		return fmt.Errorf("steam preflight could not access %s: %w", clonePath, statErr)
	}

	return nil
}

func ensureSteamSandboxReady(sendEvent func(event)) error {
	return ensureSteamSandboxReadyWith(sendEvent, probeSteamUserNamespaces, func(se func(event), err error) (error, bool) {
		return remediateSteamBubblewrap(se, err)
	})
}

func ensureSteamSandboxReadyWith(
	sendEvent func(event),
	probe func(func(event)) error,
	remediate func(func(event), error) (error, bool), // (err, bwrapSetuid)
) error {
	probeErr := probe(sendEvent)
	if probeErr == nil {
		return nil
	}
	sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: functional userns probe failed: %v", probeErr)})
	remErr, bwrapSetuid := remediate(sendEvent, probeErr)
	if remErr != nil {
		return remErr
	}
	// Steam uses bwrap, not unshare. When bwrap is setuid it creates namespaces
	// with privilege; unshare probes unprivileged userns which can fail in VMs.
	// Skip re-probe if bwrap is setuid — that path is sufficient for Steam.
	if bwrapSetuid {
		sendEvent(event{Event: "log", Line: "steam preflight: bwrap setuid present; skipping unshare re-probe (Steam uses bwrap)"})
		return nil
	}
	if err := probe(sendEvent); err != nil {
		return fmt.Errorf("steam sandbox remains unusable after remediation: %w", err)
	}
	sendEvent(event{Event: "log", Line: "steam preflight: functional userns probe passed after remediation"})
	return nil
}

func probeSteamUserNamespaces(sendEvent func(event)) error {
	if _, err := os.Stat(unshareBinaryPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("required userns probe binary is missing: %s", unshareBinaryPath)
		}
		return fmt.Errorf("could not stat %s: %w", unshareBinaryPath, err)
	}

	cmd := exec.Command(unshareBinaryPath, "--user", "--map-root-user", "/usr/bin/true")
	cmd.Env = mergedEnv(
		os.Environ(),
		map[string]string{
			"HOME": "/home/meridian",
			"USER": "meridian",
		},
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		if msg := strings.TrimSpace(string(out)); msg != "" {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: userns probe output: %s", msg)})
		}
		return fmt.Errorf("unshare probe failed: %w", err)
	}
	sendEvent(event{Event: "log", Line: "steam preflight: functional userns probe passed"})
	return nil
}

func remediateSteamBubblewrap(sendEvent func(event), probeErr error) (error, bool) {
	sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: attempting bubblewrap remediation after userns probe failure: %v", probeErr)})

	info, err := os.Stat(bwrapBinaryPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("steam sandbox check failed and %s is missing", bwrapBinaryPath), false
		}
		return fmt.Errorf("steam sandbox check failed and %s is not accessible: %w", bwrapBinaryPath, err), false
	}

	hadSetuid := info.Mode()&os.ModeSetuid != 0
	sendEvent(event{Event: "log", Line: fmt.Sprintf(
		"steam preflight: bubblewrap mode perm=%#o setuid=%t",
		info.Mode().Perm(),
		hadSetuid,
	)})

	if hadSetuid {
		sendEvent(event{Event: "log", Line: "steam preflight: bubblewrap already has setuid bit"})
		return nil, true // Skip unshare re-probe; Steam uses bwrap
	}

	if err := os.Chown(bwrapBinaryPath, 0, 0); err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: bubblewrap chown warning: %v", err)})
	}

	newMode := info.Mode().Perm() | os.ModeSetuid
	if err := os.Chmod(bwrapBinaryPath, newMode); err != nil {
		return fmt.Errorf("failed to enable setuid on %s: %w", bwrapBinaryPath, err), false
	}
	sendEvent(event{Event: "log", Line: fmt.Sprintf(
		"steam preflight: enabled setuid on bubblewrap perm=%#o",
		newMode.Perm(),
	)})
	return nil, true // Now setuid; skip unshare re-probe
}

func ensureSteamRuntime(sendEvent func(event)) error {
	libcPaths := []string{
		"/lib/i386-linux-gnu/libc.so.6",
		"/usr/lib/i386-linux-gnu/libc.so.6",
	}
	for _, p := range libcPaths {
		if _, err := os.Stat(p); err == nil {
			goto checkLibcap
		}
	}
	sendEvent(event{Event: "log", Line: "steam preflight: missing 32-bit libc runtime (libc.so.6)"})
	return fmt.Errorf("steam runtime missing 32-bit libc.so.6; rebuild or patch the VM image with i386 runtime libs")

checkLibcap:
	if hasAmd64Libcap() {
		if !hasI386LibGL() {
			sendEvent(event{Event: "log", Line: "steam preflight: missing 32-bit OpenGL runtime (libGL.so.1)"})
			return fmt.Errorf("steam runtime missing i386 libGL.so.1; patch the VM image to install i386 mesa GL libs")
		}
		if !hasI386LibDRM() {
			sendEvent(event{Event: "log", Line: "steam preflight: missing 32-bit DRM runtime (libdrm.so.2)"})
			return fmt.Errorf("steam runtime missing i386 libdrm.so.2; patch the VM image to install i386 libdrm libs")
		}
		if !hasI386LibGLDispatch() {
			sendEvent(event{Event: "log", Line: "steam preflight: missing 32-bit GLVND runtime (libGLdispatch.so.0)"})
			return fmt.Errorf("steam runtime missing i386 libGLdispatch.so.0; patch the VM image to install i386 libglvnd libs")
		}
		steamBootstrapOnce.Do(func() {
			if err := repairSteamUserRuntime(sendEvent); err != nil {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: runtime repair warning: %v", err)})
			}
			// steamdeps is unreliable in this forced amd64-on-arm64 setup and can
			// block launch/install flow. Image patching already warms dependencies.
			sendEvent(event{Event: "log", Line: "steam preflight: skipping steamdeps-preflight (known non-fatal parser bug path)"})
		})
		return nil
	}
	sendEvent(event{Event: "log", Line: "steam preflight: missing amd64 libcap runtime (libcap.so.2)"})
	return fmt.Errorf("steam runtime missing amd64 libcap.so.2; rebuild or patch the VM image with libcap2:amd64")
}

func repairSteamUserRuntime(sendEvent func(event)) error {
	const (
		homeDir       = "/home/meridian"
		homeSteamRoot = "/home/meridian/.local/share/Steam"
		homeSteamDot  = "/home/meridian/.steam"
		homeRuntime   = "/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime"
		loggerRel     = "usr/libexec/steam-runtime-tools-0/logger-0.bash"
	)

	if err := os.MkdirAll(homeSteamRoot, 0o755); err != nil {
		return fmt.Errorf("create steam home root: %w", err)
	}
	if err := os.MkdirAll(homeSteamDot, 0o755); err != nil {
		return fmt.Errorf("create ~/.steam: %w", err)
	}
	if err := ensureSymlink(homeSteamRoot, filepath.Join(homeSteamDot, "steam")); err != nil {
		return fmt.Errorf("ensure ~/.steam/steam symlink: %w", err)
	}
	if err := ensureSymlink(homeSteamRoot, filepath.Join(homeSteamDot, "root")); err != nil {
		return fmt.Errorf("ensure ~/.steam/root symlink: %w", err)
	}

	homeLogger := filepath.Join(homeRuntime, loggerRel)
	if _, err := os.Stat(homeLogger); err == nil {
		return nil
	}

	systemRuntimeRoots := []string{
		"/usr/lib/steam/ubuntu12_32",
		"/usr/lib/steam/steam-runtime",
	}
	var srcRoot string
	for _, candidate := range systemRuntimeRoots {
		candidateLogger := filepath.Join(candidate, "steam-runtime", loggerRel)
		if _, err := os.Stat(candidateLogger); err == nil {
			srcRoot = candidate
			break
		}
	}
	if srcRoot == "" {
		sendEvent(event{Event: "log", Line: "steam preflight: packaged steam runtime template not found; continuing"})
		return nil
	}

	dstRoot := filepath.Join(homeSteamRoot, "ubuntu12_32")
	if err := os.MkdirAll(dstRoot, 0o755); err != nil {
		return fmt.Errorf("create steam runtime destination: %w", err)
	}

	copy := exec.Command("/bin/cp", "-a", srcRoot+"/.", dstRoot+"/")
	if out, err := copy.CombinedOutput(); err != nil {
		return fmt.Errorf("copy packaged steam runtime: %w (%s)", err, strings.TrimSpace(string(out)))
	}

	owner := fmt.Sprintf("%d:%d", steamUID, steamGID)
	chown := exec.Command("/usr/bin/chown", "-R", owner, homeDir)
	if out, err := chown.CombinedOutput(); err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam preflight: chown warning: %v (%s)", err, strings.TrimSpace(string(out)))})
	}
	sendEvent(event{Event: "log", Line: "steam preflight: repaired steam runtime files in home directory"})
	return nil
}

func ensureSymlink(target, link string) error {
	info, err := os.Lstat(link)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			resolved, readErr := os.Readlink(link)
			if readErr == nil && resolved == target {
				return nil
			}
		}
		if removeErr := os.RemoveAll(link); removeErr != nil {
			return removeErr
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	return os.Symlink(target, link)
}

func runSteamDepsNonInteractive(sendEvent func(event), timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/usr/bin/steamdeps")
	cmd.Env = mergedEnv(
		os.Environ(),
		map[string]string{
			"DEBIAN_FRONTEND":          "noninteractive",
			"APT_LISTCHANGES_FRONTEND": "none",
			"TERM":                     "dumb",
		},
	)
	cmd.Stdin = strings.NewReader("\n\n\n\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("timed out after %s", timeout)
		}
		// Known steamdeps parser bug in mixed-arch forced-launcher setups.
		// In this VM we intentionally force-install steam-launcher:amd64 on arm64.
		if strings.Contains(string(out), "KeyError: 'steam-launcher:amd64:amd64'") {
			sendEvent(event{Event: "log", Line: "steam preflight: steamdeps known parser bug ignored"})
			return nil
		}
		return err
	}
	return nil
}

func readProcInt(path string) (int, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	value := strings.TrimSpace(string(b))
	n, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("parse %q as int: %w", value, err)
	}
	return n, nil
}

func handoffToSteam(appID int, env []string, sendEvent func(event), timeout time.Duration) error {
	target := fmt.Sprintf("steam://rungameid/%d", appID)
	return handoffToSteamTarget(target, env, sendEvent, timeout)
}

func handoffToSteamTarget(target string, env []string, sendEvent func(event), timeout time.Duration) error {
	var lastErr error
	start := time.Now()
	attempt := 0
	wrapperStarted := false
	const perAttemptTimeout = 20 * time.Second
	for time.Since(start) < timeout {
		attempt++
		killSteamZenityPopups(sendEvent, "handoff attempt start")
		pid := findSteamBinaryPID()
		sendEvent(event{Event: "log", Line: fmt.Sprintf(
			"steam handoff attempt=%d target=%s elapsed=%s steam_pid=%d wrapper_started=%t timeout=%s",
			attempt, target, time.Since(start).Round(time.Millisecond), pid, wrapperStarted, perAttemptTimeout,
		)})
		// Ask an already-running Steam client to handle the protocol target.
		// Using -ifrunning avoids triggering a second bootstrap/dependency pass.
		//
		// IMPORTANT: `steam -ifrunning` always exits 0 — it does so even when Steam
		// is not running (silent no-op). We must not treat exit-0 alone as proof the
		// URL was delivered. The real indicator is that:
		//   1. A Steam binary process is running (findSteamBinaryPID > 0), AND
		//   2. steam.pipe exists (Steam created its IPC socket, so -ifrunning had
		//      something to write to).
		// If either check fails we fall through to the wrapper-start path below.
		ctx, cancel := context.WithTimeout(context.Background(), perAttemptTimeout)
		client := exec.CommandContext(ctx, "/usr/bin/steam", "-ifrunning", target)
		client.Env = env
		client.SysProcAttr = &syscall.SysProcAttr{
			Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
		}
		// steamdeps can still prompt in some distro states; keep handoff non-interactive.
		client.Stdin = strings.NewReader("\n\n\n\n")
		attachCommandLogs("steam-handoff-client", client, sendEvent)
		timedOut := false
		if err := client.Run(); err == nil {
			cancel()
			pid := findSteamBinaryPID()
			pipeReady := steamPipeExists()
			sendEvent(event{Event: "log", Line: fmt.Sprintf(
				"steam handoff -ifrunning attempt=%d target=%s pid=%d pipe=%t",
				attempt, target, pid, pipeReady,
			)})
			if pid > 0 && pipeReady {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam handoff client succeeded attempt=%d target=%s", attempt, target)})
				return nil
			}
			// pid=0 or pipe not yet present: Steam is either not running or still
			// initialising. Fall through to evaluate the wrapper-start path.
			if pid == 0 {
				lastErr = fmt.Errorf("steam -ifrunning exited 0 but no steam process found (no-op)")
			} else {
				lastErr = fmt.Errorf("steam -ifrunning exited 0 but steam.pipe not present yet (too early)")
			}
		} else {
			cancel()
			lastErr = err
			if ctx.Err() == context.DeadlineExceeded {
				timedOut = true
				lastErr = fmt.Errorf("steam handoff client timed out after %s", perAttemptTimeout)
				logSteamProcessSnapshot(sendEvent, "handoff client timeout")
				killSteamZenityPopups(sendEvent, "handoff client timeout")
			}
			if attempt == 1 || attempt%5 == 0 {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam handoff client retry %d target=%s: %v", attempt, target, lastErr)})
			}
		}

		// Do not start another wrapper if any steam process is alive (running or still
		// bootstrapping). isSteamActive covers the bash-wrapper bootstrap phase where
		// the binary has not exec'd yet; starting a second wrapper would create two
		// competing Steam instances fighting over the same IPC socket.
		// When -ifrunning timed out we force one wrapper attempt anyway to break stalls.
		if isSteamActive() && !timedOut {
			time.Sleep(1 * time.Second)
			continue
		}

		// Fallback when no steam process is alive at all.
		// Start one wrapper process, then continue retrying -ifrunning until the
		// binary finishes bootstrapping and accepts the protocol URL.
		if !wrapperStarted {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam handoff invoking wrapper target=%s", target)})
			handoff := exec.Command("/usr/bin/steam", target)
			handoff.Env = env
			handoff.SysProcAttr = &syscall.SysProcAttr{
				Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
			}
			handoff.Stdin = strings.NewReader("\n\n\n\n")
			attachCommandLogs("steam-handoff", handoff, sendEvent)
			if err := handoff.Start(); err == nil {
				wrapperStarted = true
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam wrapper handoff started target=%s pid=%d", target, handoff.Process.Pid)})
				go func() {
					if waitErr := handoff.Wait(); waitErr != nil {
						sendEvent(event{Event: "log", Line: fmt.Sprintf("steam wrapper handoff exited: %v", waitErr)})
					}
				}()
			} else {
				wrapperErr := err
				lastErr = fmt.Errorf("client handoff failed (%v) and wrapper handoff failed (%v)", lastErr, wrapperErr)
			}
		}
		if attempt == 1 || attempt%5 == 0 {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("steam handoff retry %d target=%s: %v", attempt, target, lastErr)})
		}
		time.Sleep(1 * time.Second)
	}
	return lastErr
}

func logSelectedEnv(prefix string, env []string, sendEvent func(event)) {
	keys := []string{
		"HOME", "USER", "PATH", "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR",
		"DBUS_SESSION_BUS_ADDRESS", "STEAM_RUNTIME", "XDG_SESSION_TYPE",
		"STEAM_RUNTIME_PREFER_HOST_LIBRARIES", "STEAM_DISABLE_ZENITY",
		"STEAM_SKIP_LIBRARIES_CHECK", "STEAMOS", "GTK_A11Y",
		"LIBGL_ALWAYS_SOFTWARE", "MESA_LOADER_DRIVER_OVERRIDE", "GALLIUM_DRIVER",
		"__GLX_VENDOR_LIBRARY_NAME", "LD_LIBRARY_PATH", "LIBGL_DRIVERS_PATH",
		"DEBIAN_FRONTEND", "APT_LISTCHANGES_FRONTEND", "TERM",
	}
	values := make(map[string]string, len(env))
	for _, kv := range env {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		values[k] = v
	}
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%q", k, values[k]))
	}
	sendEvent(event{Event: "log", Line: fmt.Sprintf("%s: %s", prefix, strings.Join(parts, " "))})
}

func logSteamProcessSnapshot(sendEvent func(event), reason string) {
	cmd := exec.Command("/bin/ps", "-u", fmt.Sprintf("%d", steamUID), "-o", "pid=,comm=,args=")
	out, err := cmd.Output()
	if err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam process snapshot (%s) failed: %v", reason, err)})
		return
	}
	var hits []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		lower := strings.ToLower(line)
		if strings.Contains(lower, "steam") || strings.Contains(lower, "steamwebhelper") {
			hits = append(hits, line)
		}
	}
	if len(hits) == 0 {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam process snapshot (%s): no matching steam processes", reason)})
		return
	}
	const maxLines = 8
	limit := len(hits)
	if limit > maxLines {
		limit = maxLines
	}
	for i := 0; i < limit; i++ {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam process snapshot (%s) [%d/%d]: %s", reason, i+1, len(hits), hits[i])})
	}
}

func logManifestCandidates(appID int, sendEvent func(event)) {
	manifestName := fmt.Sprintf("appmanifest_%d.acf", appID)
	dirs := steamLibrarySteamappsDirs()
	if len(dirs) == 0 {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("install manifest diag appid=%d: no steamapps dirs discovered", appID)})
		return
	}
	const maxDirs = 8
	limit := len(dirs)
	if limit > maxDirs {
		limit = maxDirs
	}
	sendEvent(event{Event: "log", Line: fmt.Sprintf("install manifest diag appid=%d: checking %d/%d dirs", appID, limit, len(dirs))})
	for i := 0; i < limit; i++ {
		manifest := filepath.Join(dirs[i], manifestName)
		_, err := os.Stat(manifest)
		if err == nil {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("install manifest diag appid=%d: FOUND %s", appID, manifest)})
		} else if os.IsNotExist(err) {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("install manifest diag appid=%d: missing %s", appID, manifest)})
		} else {
			sendEvent(event{Event: "log", Line: fmt.Sprintf("install manifest diag appid=%d: error stat %s: %v", appID, manifest, err)})
		}
	}
}

func killSteamZenityPopups(sendEvent func(event), reason string) {
	cmd := exec.Command("/bin/ps", "-u", fmt.Sprintf("%d", steamUID), "-o", "pid=,comm=,args=")
	out, err := cmd.Output()
	if err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam zenity cleanup (%s) ps failed: %v", reason, err)})
		return
	}
	var killed []int
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		lower := strings.ToLower(line)
		if !strings.Contains(lower, "zenity") || !strings.Contains(lower, "missing the following 32-bit libraries") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		pid, convErr := strconv.Atoi(fields[0])
		if convErr != nil {
			continue
		}
		if killErr := syscall.Kill(pid, syscall.SIGTERM); killErr == nil {
			killed = append(killed, pid)
		}
	}
	if len(killed) > 0 {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam zenity cleanup (%s): terminated popup pids=%v", reason, killed)})
	}
}

func terminateSteamProcesses(sendEvent func(event), reason string) {
	patterns := []string{
		"steamwebhelper", "steamdeps", "srt-logger", "zenity", "steam.sh",
		"ubuntu12_32/steam", "/usr/bin/steam", "steam-runtime-steam-remote",
	}
	for _, p := range patterns {
		cmd := exec.Command("/usr/bin/pkill", "-u", fmt.Sprintf("%d", steamUID), "-f", p)
		if err := cmd.Run(); err != nil {
			if _, ok := err.(*exec.ExitError); !ok {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam terminate (%s) pattern=%q error=%v", reason, p, err)})
			}
		}
	}
	logSteamProcessSnapshot(sendEvent, "after terminate "+reason)
}

// findSteamBinaryPID returns the PID of the actual Steam client binary process.
//
// The bash launcher wrapper (comm=bash, args=bash /usr/bin/steam) is explicitly
// excluded because it is not IPC-ready: it cannot accept steam:// protocol
// handoffs via steam.pipe until the real binary has exec'd and initialised.
// Matching on /steam in args (the old behaviour) incorrectly treats the wrapper
// as a live client, causing install/launch handoffs to land on the wrong process.
func findSteamBinaryPID() int {
	cmd := exec.Command("/bin/ps", "-u", fmt.Sprintf("%d", steamUID), "-o", "pid=,comm=,args=")
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	var candidate int
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		var pid int
		if _, err := fmt.Sscanf(fields[0], "%d", &pid); err != nil {
			continue
		}
		lineLower := strings.ToLower(line)
		name := strings.ToLower(fields[1])
		// Skip interpreter/launcher processes — the comm field (fields[1]) is the
		// short binary name (e.g. "bash"), not the script path.
		if name == "bash" || name == "sh" || name == "python3" || name == "python" {
			continue
		}
		if strings.Contains(lineLower, "steamdeps") ||
			strings.Contains(lineLower, "zenity") ||
			strings.Contains(lineLower, "srt-logger") {
			continue
		}
		// Also match qemu-i386-static acting as the interpreter for the Steam
		// binary. In that case comm is "qemu-i386-sta" (15-char truncation) but
		// the args contain the path ubuntu12_32/steam.
		if strings.Contains(name, "steam") ||
			strings.Contains(lineLower, "steamwebhelper") ||
			strings.Contains(lineLower, "ubuntu12_32/steam") {
			candidate = pid
		}
	}
	return candidate
}

// steamPipePaths lists the locations where the running Steam client creates its
// IPC named pipe. We check all of them because the canonical path varies by
// version and symlink layout.
var steamPipePaths = []string{
	"/home/meridian/.local/share/Steam/steam.pipe",
	"/home/meridian/.steam/steam/steam.pipe",
	"/home/meridian/.steam/root/steam.pipe",
}

// steamPipeExists returns true when at least one of the known steam.pipe
// locations exists. Steam creates this named pipe early in its startup
// sequence, before writing steam.pid, and `steam -ifrunning` uses it to
// deliver protocol URLs. Polling this file is therefore a more reliable IPC
// readiness signal than watching for the binary PID alone.
func steamPipeExists() bool {
	for _, p := range steamPipePaths {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

// waitForSteamIPC waits until the Steam binary process is running AND its IPC
// named pipe (steam.pipe) is present. Returns the binary PID on success, 0 on
// timeout.
//
// While waiting, tailSteamConsoleLog streams new lines from Steam's console log
// so the caller always has live visibility into what Steam is doing, even during
// the long first-boot CDN / qemu emulation startup phase.
func waitForSteamIPC(timeout time.Duration, sendEvent func(event)) int {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go tailSteamConsoleLog(ctx, sendEvent)

	deadline := time.Now().Add(timeout)
	binaryAppeared := false
	for time.Now().Before(deadline) {
		pid := findSteamBinaryPID()
		if pid > 0 {
			if !binaryAppeared {
				binaryAppeared = true
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam binary running pid=%d; waiting for steam.pipe IPC socket", pid)})
			}
			if steamPipeExists() {
				sendEvent(event{Event: "log", Line: fmt.Sprintf("steam IPC ready pid=%d steam.pipe present", pid)})
				return pid
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	if !binaryAppeared {
		sendEvent(event{Event: "log", Line: "steam IPC wait timed out: binary never appeared"})
	} else {
		sendEvent(event{Event: "log", Line: "steam IPC wait timed out: binary running but steam.pipe never appeared"})
	}
	return 0
}

// tailSteamConsoleLog continuously reads new lines appended to Steam's console
// log and forwards each one to the host as a log event. It returns when ctx is
// cancelled. The function polls the file every second; it handles the common
// case where the log file does not exist yet (Steam hasn't started writing) by
// waiting until the file appears.
func tailSteamConsoleLog(ctx context.Context, sendEvent func(event)) {
	const logPath = "/home/meridian/.local/share/Steam/logs/console-linux.txt"

	var offset int64
	var initialized bool
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			fi, err := os.Stat(logPath)
			if err != nil {
				continue // log file not created yet
			}
			// Start from EOF on first attach so we only stream lines from the
			// current bootstrap/install attempt, not stale history.
			if !initialized {
				offset = fi.Size()
				initialized = true
				continue
			}
			if fi.Size() < offset {
				offset = 0 // log was rotated / truncated
				sendEvent(event{Event: "log", Line: "steam> [log rotated]"})
			}
			if fi.Size() == offset {
				continue // nothing new
			}

			f, err := os.Open(logPath)
			if err != nil {
				continue
			}
			if _, err := f.Seek(offset, io.SeekStart); err != nil {
				f.Close()
				continue
			}
			scanner := bufio.NewScanner(f)
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if line != "" && line != "Log opened" {
					sendEvent(event{Event: "log", Line: "steam> " + line})
				}
			}
			offset, _ = f.Seek(0, io.SeekCurrent)
			f.Close()
		}
	}
}

// waitForSteamPID polls until the Steam binary (not the bash wrapper) appears
// or the timeout elapses. Returns the binary PID, or 0 on timeout.
// Prefer waitForSteamIPC when about to issue a steam -ifrunning handoff.
func waitForSteamPID(timeout time.Duration) int {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if pid := findSteamBinaryPID(); pid > 0 {
			return pid
		}
		time.Sleep(500 * time.Millisecond)
	}
	return 0
}

// logSteamConsoleLog reads Steam's own console log and forwards the last
// maxLines lines as agent log events. Called when Steam exits unexpectedly
// so we can see what Steam itself reported before it went away.
func logSteamConsoleLog(sendEvent func(event), maxLines int) {
	candidates := []string{
		"/home/meridian/.local/share/Steam/logs/console-linux.txt",
		"/home/meridian/.local/share/Steam/logs/console.txt",
	}
	for _, path := range candidates {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
		start := len(lines) - maxLines
		if start < 0 {
			start = 0
		}
		sendEvent(event{Event: "log", Line: fmt.Sprintf("steam console log (last %d lines of %s):", len(lines[start:]), path)})
		for _, ln := range lines[start:] {
			if ln = strings.TrimSpace(ln); ln != "" {
				sendEvent(event{Event: "log", Line: "steam-log: " + ln})
			}
		}
		return
	}
	sendEvent(event{Event: "log", Line: "steam console log: not found (Steam may not have started)"})
}

func mergedEnv(base []string, overrides map[string]string) []string {
	kv := make(map[string]string, len(base)+len(overrides))
	for _, e := range base {
		k, v, ok := strings.Cut(e, "=")
		if !ok {
			continue
		}
		kv[k] = v
	}
	for k, v := range overrides {
		kv[k] = v
	}
	env := make([]string, 0, len(kv))
	for k, v := range kv {
		env = append(env, k+"="+v)
	}
	return env
}

func attachCommandLogs(name string, cmd *exec.Cmd, sendEvent func(event)) {
	stdout, err := cmd.StdoutPipe()
	if err == nil {
		go streamPipe(name, "stdout", stdout, sendEvent)
	} else {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("%s stdout pipe error: %v", name, err)})
	}
	stderr, err := cmd.StderrPipe()
	if err == nil {
		go streamPipe(name, "stderr", stderr, sendEvent)
	} else {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("%s stderr pipe error: %v", name, err)})
	}
}

func streamPipe(name, stream string, r io.ReadCloser, sendEvent func(event)) {
	defer r.Close()
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		sendEvent(event{Event: "log", Line: fmt.Sprintf("%s[%s]: %s", name, stream, line)})
	}
	if err := scanner.Err(); err != nil {
		// Steam bootstrap often closes stdio as it daemonizes; treat as non-fatal noise.
		if strings.Contains(err.Error(), "file already closed") {
			return
		}
		sendEvent(event{Event: "log", Line: fmt.Sprintf("%s[%s] read error: %v", name, stream, err)})
	}
}
