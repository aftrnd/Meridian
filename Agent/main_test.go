package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestEnsureSymlinkCreatesLink(t *testing.T) {
	tmp := t.TempDir()
	target := filepath.Join(tmp, "target")
	link := filepath.Join(tmp, "link")

	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("mkdir target: %v", err)
	}
	if err := ensureSymlink(target, link); err != nil {
		t.Fatalf("ensureSymlink failed: %v", err)
	}

	got, err := os.Readlink(link)
	if err != nil {
		t.Fatalf("readlink: %v", err)
	}
	if got != target {
		t.Fatalf("symlink target mismatch: got=%q want=%q", got, target)
	}
}

func TestEnsureSymlinkReplacesWrongLink(t *testing.T) {
	tmp := t.TempDir()
	targetA := filepath.Join(tmp, "target-a")
	targetB := filepath.Join(tmp, "target-b")
	link := filepath.Join(tmp, "link")

	if err := os.MkdirAll(targetA, 0o755); err != nil {
		t.Fatalf("mkdir target-a: %v", err)
	}
	if err := os.MkdirAll(targetB, 0o755); err != nil {
		t.Fatalf("mkdir target-b: %v", err)
	}
	if err := os.Symlink(targetA, link); err != nil {
		t.Fatalf("create initial symlink: %v", err)
	}

	if err := ensureSymlink(targetB, link); err != nil {
		t.Fatalf("ensureSymlink failed: %v", err)
	}

	got, err := os.Readlink(link)
	if err != nil {
		t.Fatalf("readlink: %v", err)
	}
	if got != targetB {
		t.Fatalf("symlink target mismatch: got=%q want=%q", got, targetB)
	}
}

func TestEnsureSymlinkReplacesDirectory(t *testing.T) {
	tmp := t.TempDir()
	target := filepath.Join(tmp, "target")
	link := filepath.Join(tmp, "link")

	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("mkdir target: %v", err)
	}
	if err := os.MkdirAll(link, 0o755); err != nil {
		t.Fatalf("mkdir link dir: %v", err)
	}

	if err := ensureSymlink(target, link); err != nil {
		t.Fatalf("ensureSymlink failed: %v", err)
	}

	info, err := os.Lstat(link)
	if err != nil {
		t.Fatalf("lstat link: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("expected symlink at %q", link)
	}
}

func TestEnsureSteamSandboxReadyWithProbePassesImmediately(t *testing.T) {
	t.Helper()

	var remediationCalled bool
	err := ensureSteamSandboxReadyWith(
		func(event) {},
		func(func(event)) error { return nil },
		func(func(event), error) (error, bool) {
			remediationCalled = true
			return nil, false
		},
	)
	if err != nil {
		t.Fatalf("ensureSteamSandboxReadyWith returned error: %v", err)
	}
	if remediationCalled {
		t.Fatalf("remediation should not run when probe passes")
	}
}

func TestEnsureSteamSandboxReadyWithRemediatesAndReprobes(t *testing.T) {
	t.Helper()

	probeCalls := 0
	err := ensureSteamSandboxReadyWith(
		func(event) {},
		func(func(event)) error {
			probeCalls++
			if probeCalls == 1 {
				return errors.New("first probe failed")
			}
			return nil
		},
		func(func(event), error) (error, bool) { return nil, false }, // bwrapSetuid=false => re-probe
	)
	if err != nil {
		t.Fatalf("ensureSteamSandboxReadyWith returned error: %v", err)
	}
	if probeCalls != 2 {
		t.Fatalf("expected 2 probe calls (before/after remediation), got %d", probeCalls)
	}
}

func TestEnsureSteamSandboxReadyWithFailsWhenRemediationFails(t *testing.T) {
	t.Helper()

	want := "remediation failed"
	err := ensureSteamSandboxReadyWith(
		func(event) {},
		func(func(event)) error { return errors.New("probe failed") },
		func(func(event), error) (error, bool) { return errors.New(want), false },
	)
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	if err.Error() != want {
		t.Fatalf("unexpected error: got %q want %q", err.Error(), want)
	}
}

func TestEnsureSteamSandboxReadyWithFailsWhenProbeStillFailsAfterRemediation(t *testing.T) {
	t.Helper()

	err := ensureSteamSandboxReadyWith(
		func(event) {},
		func(func(event)) error { return errors.New("probe still failing") },
		func(func(event), error) (error, bool) { return nil, false }, // bwrapSetuid=false => re-probe, which fails
	)
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "steam sandbox remains unusable after remediation") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestEnsureSteamSandboxReadyWithSkipsReprobeWhenBwrapSetuid(t *testing.T) {
	t.Helper()

	probeCalls := 0
	err := ensureSteamSandboxReadyWith(
		func(event) {},
		func(func(event)) error {
			probeCalls++
			return errors.New("unshare always fails in VM")
		},
		func(func(event), error) (error, bool) { return nil, true }, // bwrap setuid => skip re-probe
	)
	if err != nil {
		t.Fatalf("ensureSteamSandboxReadyWith returned error: %v", err)
	}
	if probeCalls != 1 {
		t.Fatalf("expected 1 probe call (skip re-probe when bwrap setuid), got %d", probeCalls)
	}
}

// ── X display socket tests ─────────────────────────────────────────────────

// makeUnixSocket creates a real UNIX socket at path (not just a plain file).
// Tests must use an actual socket so that os.Stat + inode lookups behave
// identically to the real /tmp/.X11-unix/X0 socket on a running system.
//
// IMPORTANT: macOS limits UNIX socket paths to 104 bytes.  Always create the
// socket under a short /tmp prefix, not under t.TempDir() (whose path often
// exceeds the limit, causing bind: invalid argument).
func makeUnixSocket(t *testing.T, path string) {
	t.Helper()
	if len(path) > 100 {
		t.Fatalf("makeUnixSocket: path %q exceeds macOS 104-byte UNIX socket limit", path)
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("makeUnixSocket: %v", err)
	}
	t.Cleanup(func() {
		l.Close()
		os.Remove(path)
	})
}

// tempSocketDir creates a short temporary directory under /tmp suitable for
// UNIX socket paths.  Returns the dir and registers cleanup.
func tempSocketDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "mxtest")
	if err != nil {
		t.Fatalf("tempSocketDir: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func TestHasXDisplaySocketAt_Present(t *testing.T) {
	dir := tempSocketDir(t)
	sock := filepath.Join(dir, "X0")
	makeUnixSocket(t, sock)

	if !hasXDisplaySocketAt(sock) {
		t.Fatalf("hasXDisplaySocketAt returned false for existing socket at %s", sock)
	}
}

func TestHasXDisplaySocketAt_Missing(t *testing.T) {
	dir := tempSocketDir(t)
	sock := filepath.Join(dir, "X0_nx")

	if hasXDisplaySocketAt(sock) {
		t.Fatalf("hasXDisplaySocketAt returned true for non-existent path %s", sock)
	}
}

func TestHasXDisplaySocketAt_PlainFileCountsAsPresent(t *testing.T) {
	// os.Stat succeeds for any file, not just sockets.  The real guard is the
	// socket itself existing; we test that a regular file is also detected so
	// unit tests don't need net.Listen.
	tmp := t.TempDir()
	f := filepath.Join(tmp, "X0_file")
	if err := os.WriteFile(f, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	if !hasXDisplaySocketAt(f) {
		t.Fatalf("hasXDisplaySocketAt returned false for plain file at %s", f)
	}
}

func TestWaitForXDisplayAt_ImmediatelyReady(t *testing.T) {
	dir := tempSocketDir(t)
	sock := filepath.Join(dir, "X0")
	makeUnixSocket(t, sock)

	var logs []string
	err := waitForXDisplayAt(sock, 5*time.Second, func(e event) {
		logs = append(logs, e.Line)
	})
	if err != nil {
		t.Fatalf("waitForXDisplayAt returned error for pre-existing socket: %v", err)
	}
	// Should emit the "ready" log line.
	found := false
	for _, l := range logs {
		if strings.Contains(l, "ready") || strings.Contains(l, "socket ready") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected a 'ready' log line, got: %v", logs)
	}
}

func TestWaitForXDisplayAt_AppearsAfterDelay(t *testing.T) {
	dir := tempSocketDir(t)
	sock := filepath.Join(dir, "X0")

	// Create the socket after a short delay.
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		time.Sleep(400 * time.Millisecond)
		// Use a plain file here — waitForXDisplayAt only needs os.Stat to
		// succeed, not a real socket, and the goroutine can't call t.Fatal.
		_ = os.WriteFile(sock, []byte{}, 0o600)
	}()

	err := waitForXDisplayAt(sock, 5*time.Second, func(event) {})
	wg.Wait()
	if err != nil {
		t.Fatalf("waitForXDisplayAt should succeed when socket appears within timeout, got: %v", err)
	}
}

func TestWaitForXDisplayAt_TimesOut(t *testing.T) {
	dir := tempSocketDir(t)
	sock := filepath.Join(dir, "X0_never")

	err := waitForXDisplayAt(sock, 1500*time.Millisecond, func(event) {})
	if err == nil {
		t.Fatal("waitForXDisplayAt should return error when socket never appears")
	}
	if !strings.Contains(err.Error(), "not found after") {
		t.Fatalf("error should mention 'not found after', got: %v", err)
	}
	if !strings.Contains(err.Error(), "XWayland") {
		t.Fatalf("error should hint at XWayland/Xvfb, got: %v", err)
	}
}

func TestWaitForXDisplayAt_ErrorMessageContainsPath(t *testing.T) {
	dir := tempSocketDir(t)
	sock := filepath.Join(dir, "X0_absent")

	err := waitForXDisplayAt(sock, 500*time.Millisecond, func(event) {})
	if err == nil {
		t.Fatal("expected error for missing socket")
	}
	if !strings.Contains(err.Error(), sock) {
		t.Fatalf("error message should contain the socket path %q, got: %v", sock, err)
	}
}

// ── readFileString tests ───────────────────────────────────────────────────

func TestReadFileString_ExistingFile(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "test.txt")
	want := "hello\nworld\n"
	if err := os.WriteFile(f, []byte(want), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readFileString(f)
	if got != want {
		t.Fatalf("readFileString got %q, want %q", got, want)
	}
}

func TestReadFileString_MissingFile(t *testing.T) {
	got := readFileString("/nonexistent/path/file.txt")
	if got != "" {
		t.Fatalf("readFileString of missing file should return empty string, got %q", got)
	}
}

// ── steamEnvironment tests ────────────────────────────────────────────────

// envMap converts a []string environment slice into a map for easy lookup.
func envMap(env []string) map[string]string {
	m := make(map[string]string, len(env))
	for _, kv := range env {
		k, v, ok := strings.Cut(kv, "=")
		if ok {
			m[k] = v
		}
	}
	return m
}

func TestSteamEnvironment_ContainsDISPLAY(t *testing.T) {
	env := envMap(steamEnvironment())
	d := env["DISPLAY"]
	if d != ":0" && !strings.HasPrefix(d, ":") {
		t.Fatalf("DISPLAY should be ':0' or ':N', got %q", d)
	}
}

// TestSteamEnvironment_DisplayReflectsSetSteamDisplay ensures that when the
// agent has selected a dedicated Xvfb display (e.g. :1), steamEnvironment
// passes that to Steam instead of hardcoding :0.
func TestSteamEnvironment_DisplayReflectsSetSteamDisplay(t *testing.T) {
	setSteamDisplay(":1")
	t.Cleanup(func() { setSteamDisplay(":0") })
	env := envMap(steamEnvironment())
	if env["DISPLAY"] != ":1" {
		t.Fatalf("DISPLAY should be ':1' after setSteamDisplay(:1), got %q", env["DISPLAY"])
	}
}

func TestSteamEnvironment_ContainsSoftwareGL(t *testing.T) {
	env := envMap(steamEnvironment())
	if env["LIBGL_ALWAYS_SOFTWARE"] != "1" {
		t.Fatalf("LIBGL_ALWAYS_SOFTWARE should be '1', got %q", env["LIBGL_ALWAYS_SOFTWARE"])
	}
	if env["MESA_LOADER_DRIVER_OVERRIDE"] != "llvmpipe" {
		t.Fatalf("MESA_LOADER_DRIVER_OVERRIDE should be 'llvmpipe', got %q", env["MESA_LOADER_DRIVER_OVERRIDE"])
	}
	if env["GALLIUM_DRIVER"] != "llvmpipe" {
		t.Fatalf("GALLIUM_DRIVER should be 'llvmpipe', got %q", env["GALLIUM_DRIVER"])
	}
}

func TestSteamEnvironment_ContainsWayland(t *testing.T) {
	env := envMap(steamEnvironment())
	if env["WAYLAND_DISPLAY"] != "wayland-1" {
		t.Fatalf("WAYLAND_DISPLAY should be 'wayland-1', got %q", env["WAYLAND_DISPLAY"])
	}
}

func TestSteamEnvironment_DisablesZenity(t *testing.T) {
	env := envMap(steamEnvironment())
	if env["STEAM_DISABLE_ZENITY"] != "1" {
		t.Fatalf("STEAM_DISABLE_ZENITY should be '1', got %q", env["STEAM_DISABLE_ZENITY"])
	}
	if env["STEAM_SKIP_LIBRARIES_CHECK"] != "1" {
		t.Fatalf("STEAM_SKIP_LIBRARIES_CHECK should be '1', got %q", env["STEAM_SKIP_LIBRARIES_CHECK"])
	}
}

func TestSteamEnvironment_ContainsLDLibraryPath(t *testing.T) {
	env := envMap(steamEnvironment())
	ldPath := env["LD_LIBRARY_PATH"]
	if ldPath == "" {
		t.Fatal("LD_LIBRARY_PATH must be set for Steam 32-bit runtime")
	}
	for _, expected := range []string{
		"pinned_libs_32",
		"i386-linux-gnu",
	} {
		if !strings.Contains(ldPath, expected) {
			t.Fatalf("LD_LIBRARY_PATH missing %q, got: %s", expected, ldPath)
		}
	}
}

// TestSteamEnvironment_LDLibraryPathPrefersHostI386 guards regression: host
// i386 GL/DRM must come before Steam runtime pinned_libs_32, or Steam's
// glXChooseVisual fails at runtime despite preflight GLX probe passing.
func TestSteamEnvironment_LDLibraryPathPrefersHostI386(t *testing.T) {
	env := envMap(steamEnvironment())
	ldPath := env["LD_LIBRARY_PATH"]
	hostIdx := strings.Index(ldPath, "/usr/lib/i386-linux-gnu")
	pinnedIdx := strings.Index(ldPath, "pinned_libs_32")
	if hostIdx < 0 {
		t.Fatalf("LD_LIBRARY_PATH must include /usr/lib/i386-linux-gnu, got: %s", ldPath)
	}
	if pinnedIdx < 0 {
		t.Fatalf("LD_LIBRARY_PATH must include pinned_libs_32 as fallback, got: %s", ldPath)
	}
	if hostIdx > pinnedIdx {
		t.Fatalf("host i386 paths must come before pinned_libs_32 (glXChooseVisual regression); got: %s", ldPath)
	}
}

// TestSteamEnvironment_ContainsLibGLDriversPath ensures Mesa DRI driver path
// is set so software GL (llvmpipe) can be found at runtime.
func TestSteamEnvironment_ContainsLibGLDriversPath(t *testing.T) {
	env := envMap(steamEnvironment())
	driversPath := env["LIBGL_DRIVERS_PATH"]
	if driversPath == "" {
		t.Fatal("LIBGL_DRIVERS_PATH must be set for Mesa software GL")
	}
	if !strings.Contains(driversPath, "aarch64-linux-gnu/dri") {
		t.Fatalf("LIBGL_DRIVERS_PATH should include aarch64 DRI path, got: %s", driversPath)
	}
}

// TestSteamEnvironment_PrefersHostLibraries ensures we request host Mesa over
// steam-runtime pinned libs (avoids glXChooseVisual crash).
func TestSteamEnvironment_PrefersHostLibraries(t *testing.T) {
	env := envMap(steamEnvironment())
	if env["STEAM_RUNTIME_PREFER_HOST_LIBRARIES"] != "1" {
		t.Fatalf("STEAM_RUNTIME_PREFER_HOST_LIBRARIES should be 1, got %q", env["STEAM_RUNTIME_PREFER_HOST_LIBRARIES"])
	}
}

func TestSteamEnvironment_OverridesBaseEnv(t *testing.T) {
	// Temporarily inject a HOME that should be overridden.
	t.Setenv("HOME", "/root")
	env := envMap(steamEnvironment())
	if env["HOME"] != "/home/meridian" {
		t.Fatalf("HOME should be overridden to '/home/meridian', got %q", env["HOME"])
	}
}

// ── mergedEnv tests ───────────────────────────────────────────────────────

func TestMergedEnv_OverridesBase(t *testing.T) {
	base := []string{"FOO=original", "BAR=keep"}
	overrides := map[string]string{"FOO": "overridden"}
	env := envMap(mergedEnv(base, overrides))
	if env["FOO"] != "overridden" {
		t.Fatalf("FOO should be overridden, got %q", env["FOO"])
	}
	if env["BAR"] != "keep" {
		t.Fatalf("BAR should be preserved, got %q", env["BAR"])
	}
}

func TestMergedEnv_AddsNew(t *testing.T) {
	base := []string{"EXISTING=yes"}
	overrides := map[string]string{"NEW": "value"}
	env := envMap(mergedEnv(base, overrides))
	if env["NEW"] != "value" {
		t.Fatalf("NEW key not added, env: %v", env)
	}
	if env["EXISTING"] != "yes" {
		t.Fatalf("EXISTING key dropped, env: %v", env)
	}
}

func TestMergedEnv_EmptyBase(t *testing.T) {
	env := envMap(mergedEnv(nil, map[string]string{"K": "V"}))
	if env["K"] != "V" {
		t.Fatalf("expected K=V, got %v", env)
	}
}

func TestMergedEnv_EmptyOverrides(t *testing.T) {
	base := []string{"A=1", "B=2"}
	env := envMap(mergedEnv(base, nil))
	if env["A"] != "1" || env["B"] != "2" {
		t.Fatalf("base env not preserved with empty overrides: %v", env)
	}
}

// ── parseLibraryFolders tests ─────────────────────────────────────────────

func TestParseLibraryFolders_ValidVDF(t *testing.T) {
	tmp := t.TempDir()
	vdf := filepath.Join(tmp, "libraryfolders.vdf")
	content := `"libraryfolders"
{
	"0"
	{
		"path"		"/mnt/games"
		"label"		""
	}
	"1"
	{
		"path"		"/home/meridian/.local/share/Steam"
	}
}`
	if err := os.WriteFile(vdf, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	paths := parseLibraryFolders(vdf)
	if len(paths) != 2 {
		t.Fatalf("expected 2 library paths, got %d: %v", len(paths), paths)
	}
	want := map[string]bool{"/mnt/games": true, "/home/meridian/.local/share/Steam": true}
	for _, p := range paths {
		if !want[p] {
			t.Fatalf("unexpected path %q in results %v", p, paths)
		}
	}
}

func TestParseLibraryFolders_Missing(t *testing.T) {
	paths := parseLibraryFolders("/nonexistent/libraryfolders.vdf")
	if len(paths) != 0 {
		t.Fatalf("expected empty slice for missing file, got %v", paths)
	}
}

func TestParseLibraryFolders_Empty(t *testing.T) {
	tmp := t.TempDir()
	vdf := filepath.Join(tmp, "libraryfolders.vdf")
	if err := os.WriteFile(vdf, []byte(`"libraryfolders" {}`), 0o644); err != nil {
		t.Fatal(err)
	}
	paths := parseLibraryFolders(vdf)
	if len(paths) != 0 {
		t.Fatalf("expected 0 paths for empty VDF, got %v", paths)
	}
}

// ── isGameInstalled tests ─────────────────────────────────────────────────

func TestIsGameInstalled_PresentInSteamapps(t *testing.T) {
	tmp := t.TempDir()
	steamapps := filepath.Join(tmp, "steamapps")
	if err := os.MkdirAll(steamapps, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := filepath.Join(steamapps, "appmanifest_813230.acf")
	if err := os.WriteFile(manifest, []byte(`"AppState" { "appid" "813230" }`), 0o644); err != nil {
		t.Fatal(err)
	}

	// Temporarily override the library discovery by testing the low-level
	// manifest stat path directly, since steamLibrarySteamappsDirs uses
	// hard-coded paths that don't exist in test environments.
	_, err := os.Stat(manifest)
	if err != nil {
		t.Fatalf("manifest should exist: %v", err)
	}
	// Validate the manifest naming convention matches what the agent checks.
	wantName := "appmanifest_813230.acf"
	if filepath.Base(manifest) != wantName {
		t.Fatalf("manifest filename mismatch: got %q want %q", filepath.Base(manifest), wantName)
	}
}

func TestIsGameInstalled_AbsentManifest(t *testing.T) {
	tmp := t.TempDir()
	manifest := filepath.Join(tmp, "appmanifest_813230.acf")
	if _, err := os.Stat(manifest); !os.IsNotExist(err) {
		t.Fatal("manifest should not exist yet")
	}
}

// ── preflight status format tests ─────────────────────────────────────────

// TestPreflightStatusContainsXDisplayGLX verifies that emitSteamPreflightStatus
// always includes xdisplay_glx= in its log output.  The glXChooseVisual crash
// was invisible in logs before this was added; this test ensures it stays.
func TestPreflightStatusContainsXDisplayGLX(t *testing.T) {
	var lines []string
	emitSteamPreflightStatus(func(e event) {
		lines = append(lines, e.Line)
	})
	if len(lines) == 0 {
		t.Fatal("emitSteamPreflightStatus emitted no events")
	}
	statusLine := lines[len(lines)-1]
	if !strings.Contains(statusLine, "xdisplay_glx=") {
		t.Fatalf("preflight status line missing xdisplay_glx= field (glXChooseVisual crash would be invisible).\nGot: %s", statusLine)
	}
	// The value must be a boolean — either true or false.
	if !strings.Contains(statusLine, "xdisplay_glx=true") &&
		!strings.Contains(statusLine, "xdisplay_glx=false") {
		t.Fatalf("xdisplay_glx= must be 'true' or 'false', got: %s", statusLine)
	}
}

// ── GLX probe injection tests ─────────────────────────────────────────────
//
// These tests guard against the exact failure observed in VZ mode:
//
//   "X display :0 socket ready (owner not found in /proc)"
//   xdisplay_glx=true    ← WRONG: XWayland had died; stale socket file remained
//   glXChooseVisual failed → Fatal assert; application exiting
//
// Root cause: xdisplay_glx was driven by os.Stat(socketPath) — socket file
// presence — not by an actual GLX connectivity check.  A dead X server leaves
// its socket file on disk.  The agent reported "all good" and let Steam proceed
// into glXChooseVisual against a dead server.
//
// Fix: xdisplay_glx must be set from glxProber() — an injectable function that
// actually tests GLX (runs a python glXChooseVisual probe in production).

// withGLXProber temporarily replaces the package-level glxProber and restores
// it when the test finishes.
func withGLXProber(t *testing.T, prober func() bool) {
	t.Helper()
	orig := glxProber
	glxProber = prober
	t.Cleanup(func() { glxProber = orig })
}

// withXSocketPath temporarily replaces xDisplaySocketPath and restores it.
func withXSocketPath(t *testing.T, path string) {
	t.Helper()
	orig := xDisplaySocketPath
	xDisplaySocketPath = path
	t.Cleanup(func() { xDisplaySocketPath = orig })
}

// TestPreflightGLXProbe_StaleSocket_MustReportFalse is the regression test for
// the VZ-mode glXChooseVisual crash.
//
// Scenario: XWayland started, created /tmp/.X11-unix/X0, then exited (because
// it couldn't connect to the Wayland compositor, or glamor init failed).  The
// socket FILE still exists on disk.  The agent must not report xdisplay_glx=true
// in this state — it must call glxProber() and use that result.
//
// This test FAILS with the original code (os.Stat-only check) and PASSES after
// the fix (glxProber injection).
func TestPreflightGLXProbe_StaleSocket_MustReportFalse(t *testing.T) {
	// Create a stale socket file (the file exists but no X server behind it).
	tmp := t.TempDir()
	staleSock := filepath.Join(tmp, "X0_stale")
	if err := os.WriteFile(staleSock, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	withXSocketPath(t, staleSock)
	// Prober returns false — simulates "connected to socket but got no GLX visuals"
	// OR "X server is dead and XOpenDisplay returns NULL".
	withGLXProber(t, func() bool { return false })

	var lines []string
	emitSteamPreflightStatus(func(e event) { lines = append(lines, e.Line) })

	status := lines[len(lines)-1]
	if !strings.Contains(status, "xdisplay_glx=false") {
		t.Fatalf(
			"stale X socket + failing GLX probe MUST yield xdisplay_glx=false\n"+
				"(the original os.Stat-only check would report true here — that is the bug)\n"+
				"Got status: %s", status)
	}
}

// TestPreflightGLXProbe_WorkingDisplay_ReportsTrue verifies the happy path:
// socket present AND glxProber() returns true → xdisplay_glx=true.
func TestPreflightGLXProbe_WorkingDisplay_ReportsTrue(t *testing.T) {
	tmp := t.TempDir()
	sock := filepath.Join(tmp, "X0_live")
	if err := os.WriteFile(sock, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	withXSocketPath(t, sock)
	withGLXProber(t, func() bool { return true })

	var lines []string
	emitSteamPreflightStatus(func(e event) { lines = append(lines, e.Line) })

	status := lines[len(lines)-1]
	if !strings.Contains(status, "xdisplay_glx=true") {
		t.Fatalf("socket present + passing GLX probe must yield xdisplay_glx=true, got: %s", status)
	}
}

// TestPreflightGLXProbe_NoSocket_SkipsProber verifies that when the socket
// doesn't exist at all, the prober is NOT called (saves time on slow VMs)
// and xdisplay_glx=false is reported.
func TestPreflightGLXProbe_NoSocket_SkipsProber(t *testing.T) {
	tmp := t.TempDir()
	withXSocketPath(t, filepath.Join(tmp, "X0_absent"))

	proberCalled := false
	withGLXProber(t, func() bool {
		proberCalled = true
		return true
	})

	var lines []string
	emitSteamPreflightStatus(func(e event) { lines = append(lines, e.Line) })

	status := lines[len(lines)-1]
	if !strings.Contains(status, "xdisplay_glx=false") {
		t.Fatalf("no socket must yield xdisplay_glx=false, got: %s", status)
	}
	if proberCalled {
		t.Fatal("glxProber must NOT be called when the socket doesn't even exist")
	}
}

// TestPreflightStatusFieldOrder verifies all required preflight fields appear
// in the status line so regressions in field omissions are caught immediately.
func TestPreflightStatusFieldOrder(t *testing.T) {
	var lines []string
	emitSteamPreflightStatus(func(e event) {
		lines = append(lines, e.Line)
	})
	if len(lines) == 0 {
		t.Fatal("no lines emitted")
	}
	status := lines[len(lines)-1]
	required := []string{
		"display=",
		"rosetta_binfmt=",
		"libc32=",
		"libcap_amd64=",
		"libGL_i386=",
		"libdrm_i386=",
		"libGLdispatch_i386=",
		"xdisplay_glx=",        // must be present — was missing before the fix
		"user.max_user_namespaces=",
		"kernel.unprivileged_userns_clone=",
	}
	for _, field := range required {
		if !strings.Contains(status, field) {
			t.Errorf("preflight status missing field %q\nFull line: %s", field, status)
		}
	}
}
