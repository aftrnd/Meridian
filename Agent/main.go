package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	vsockPort = 1234
	steamUID  = 1000
	steamGID  = 1000
)

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

	for scanner.Scan() {
		line := scanner.Bytes()
		var c cmd
		if err := json.Unmarshal(line, &c); err != nil {
			sendLog(fmt.Sprintf("bad json: %v", err))
			continue
		}

		switch c.Cmd {
		case "launch":
			if gameProc != nil {
				gameProc.Kill()
				gameProc = nil
			}
			go func(appID int) {
				proc, err := launchGame(appID, sendEvent)
				if err != nil {
					sendLog(fmt.Sprintf("launch error: %v", err))
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
			if gameProc != nil {
				gameProc.Kill()
				gameProc = nil
			}
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
	// Wait up to 30 s for the Wayland socket (sway may still be starting).
	const waylandSocket = "/run/user/1000/wayland-1"
	for i := 0; i < 30; i++ {
		if _, err := os.Stat(waylandSocket); err == nil {
			break
		}
		time.Sleep(time.Second)
	}
	if _, err := os.Stat(waylandSocket); err != nil {
		return nil, fmt.Errorf("wayland socket not found after 30s: %v", err)
	}

	// Preserve baseline environment (especially PATH) then override session vars.
	// Steam is a shell launcher script and will fail quickly if PATH is missing.
	env := mergedEnv(
		os.Environ(),
		map[string]string{
			"HOME":                     "/home/meridian",
			"USER":                     "meridian",
			"WAYLAND_DISPLAY":          "wayland-1",
			"XDG_RUNTIME_DIR":          "/run/user/1000",
			"DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
			"STEAM_RUNTIME":            "1",
			"XDG_SESSION_TYPE":         "wayland",
		},
	)

	emitLaunchDiagnostics(appID, sendEvent)

	// Prefer handing off to an already-running Steam instance via URL protocol.
	// This avoids wrapper startup checks (including misleading 32-bit warnings)
	// on every launch and is the canonical way to trigger an app from desktop.
	if !isSteamRunning() {
		sendEvent(event{Event: "log", Line: "steam process not running; starting client first"})
		boot := exec.Command("/usr/bin/steam", "-silent", "-no-cef-sandbox")
		boot.Env = env
		boot.SysProcAttr = &syscall.SysProcAttr{
			Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
		}
		attachCommandLogs("steam-boot", boot, sendEvent)
		if err := boot.Start(); err != nil {
			return nil, fmt.Errorf("start steam bootstrap: %w", err)
		}
		// Do not wait on bootstrap here; wait for steady-state steam process below.
	}

	steamPID, ok := waitForSteamPID(30 * time.Second)
	if !ok {
		return nil, fmt.Errorf("steam process did not become ready within 30s")
	}

	handoff := exec.Command("/usr/bin/xdg-open", fmt.Sprintf("steam://rungameid/%d", appID))
	handoff.Env = env
	handoff.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
	}
	attachCommandLogs("steam-handoff", handoff, sendEvent)
	if err := handoff.Run(); err != nil {
		return nil, fmt.Errorf("steam handoff failed: %w", err)
	}

	sendEvent(event{Event: "log", Line: fmt.Sprintf("launch handed off to running steam (pid=%d)", steamPID)})
	sendEvent(event{Event: "started", PID: steamPID})
	return nil, nil
}

// ── Game installer ────────────────────────────────────────────────────────────

func installGame(appID int, sendEvent func(event)) {
	cmd := exec.Command("/usr/bin/steam",
		"+app_update", fmt.Sprintf("%d", appID), "validate", "+quit")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: steamUID, Gid: steamGID},
	}
	cmd.Env = mergedEnv(
		os.Environ(),
		map[string]string{
			"HOME":          "/home/meridian",
			"USER":          "meridian",
			"STEAM_RUNTIME": "1",
		},
	)

	out, err := cmd.CombinedOutput()
	if err != nil {
		sendEvent(event{Event: "log", Line: fmt.Sprintf("install error: %v\n%s", err, out)})
		sendEvent(event{Event: "installed", AppID: appID, Installed: boolPtr(false)})
	} else {
		sendEvent(event{Event: "progress", AppID: appID, Pct: 100})
		sendEvent(event{Event: "installed", AppID: appID, Installed: boolPtr(isGameInstalled(appID))})
	}
}

func isGameInstalled(appID int) bool {
	manifest := fmt.Sprintf("/home/meridian/.local/share/Steam/steamapps/appmanifest_%d.acf", appID)
	if _, err := os.Stat(manifest); err == nil {
		return true
	}
	return false
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

func isSteamRunning() bool {
	return findSteamPID() > 0
}

func waitForSteamPID(timeout time.Duration) (int, bool) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if pid := findSteamPID(); pid > 0 {
			return pid, true
		}
		time.Sleep(300 * time.Millisecond)
	}
	return 0, false
}

func findSteamPID() int {
	cmd := exec.Command("/usr/bin/pgrep", "-u", fmt.Sprintf("%d", steamUID), "-x", "steam")
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	text := strings.TrimSpace(string(out))
	if text == "" {
		return 0
	}
	lines := strings.Split(text, "\n")
	last := strings.TrimSpace(lines[len(lines)-1])
	var pid int
	if _, err := fmt.Sscanf(last, "%d", &pid); err != nil {
		return 0
	}
	return pid
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
		sendEvent(event{Event: "log", Line: fmt.Sprintf("%s[%s] read error: %v", name, stream, err)})
	}
}
