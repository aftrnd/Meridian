// Meridian game-bundle interposer (probe). Injected via DYLD_INSERT_LIBRARIES into wine64.
// CX Wine copies its loader to $TMPDIR/winetemp-<ids>/<exe> and execs it, so the game process is a
// bare executable macOS treats as "anon" — never eligible for Game Mode and named "hl2.exe" in the Dock.
// This interposes execve: when the target is a winetemp copy, mirror it into
//   $MERIDIAN_GAME_BUNDLE_DIR/<Display Name>.app/Contents/MacOS/<exe>
// with an Info.plist (games category, GCSupportsGameMode) and exec that instead.
// Runs in a forked child: syscalls only — no stdio, no ObjC, no malloc.
#include <fcntl.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// A signed binary exec'd from inside a bundle must have the bundle's Info.plist in its
// CodeDirectory, otherwise taskgated kills it ("Code Signature Invalid"). Re-sign ad-hoc in place.
static int resign(const char *target) {
    pid_t pid; int st = -1;
    char *argv[] = { "/usr/bin/codesign", "--force", "--sign", "-",
                     "--preserve-metadata=entitlements,flags,runtime", (char *)target, NULL };
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0) return -1;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) && WEXITSTATUS(st) == 0 ? 0 : -1;
}

#define DYLD_INTERPOSE(_r, _o) __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##_o __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_r, (const void *)(unsigned long)&_o };

static const char *base_name(const char *p) { const char *s = strrchr(p, '/'); return s ? s + 1 : p; }

static int copy_file(const char *src, const char *dst) {
    int in = open(src, O_RDONLY); if (in < 0) return -1;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0755); if (out < 0) { close(in); return -1; }
    char buf[65536]; ssize_t n;
    while ((n = read(in, buf, sizeof buf)) > 0) if (write(out, buf, (size_t)n) != n) { close(in); close(out); return -1; }
    close(in); close(out); return 0;
}

static void cat(char *dst, size_t cap, const char *s) { size_t l = strlen(dst); if (l < cap) strlcpy(dst + l, s, cap - l); }

static void trace(const char *a, const char *b, const char *c) {
    int fd = open("/tmp/gamebundle.log", O_WRONLY | O_CREAT | O_APPEND, 0644); if (fd < 0) return;
    char line[3000] = ""; cat(line, sizeof line, a); cat(line, sizeof line, " | "); cat(line, sizeof line, b); cat(line, sizeof line, " | "); cat(line, sizeof line, c); cat(line, sizeof line, "\n");
    write(fd, line, strlen(line)); close(fd);
}

// Returns the bundle path to run instead of `path`, or NULL to run `path` unchanged.
static const char *redirect(const char *path, char *out, size_t cap) {
    const char *dir = getenv("MERIDIAN_GAME_BUNDLE_DIR");
    if (!dir || !strstr(path, "/winetemp-")) return NULL;
    {
        const char *exe = base_name(path);
        const char *name = getenv("MERIDIAN_GAME_DISPLAY_NAME"); if (!name || !*name) name = exe;
        char app[1024] = ""; cat(app, sizeof app, dir); cat(app, sizeof app, "/"); cat(app, sizeof app, name); cat(app, sizeof app, ".app");
        char contents[1100] = ""; cat(contents, sizeof contents, app); cat(contents, sizeof contents, "/Contents");
        char macos[1200] = ""; cat(macos, sizeof macos, contents); cat(macos, sizeof macos, "/MacOS");
        mkdir(dir, 0755); mkdir(app, 0755); mkdir(contents, 0755); mkdir(macos, 0755);
        char target[1400] = ""; cat(target, sizeof target, macos); cat(target, sizeof target, "/"); cat(target, sizeof target, exe);
        struct stat src_st, dst_st;
        int fresh = stat(path, &src_st) == 0 && stat(target, &dst_st) == 0 && src_st.st_size == dst_st.st_size;
        // The loader dlopens ntdll.so from its own directory; mirror CX's winetemp symlink.
        char srcdir[1024] = ""; strlcpy(srcdir, path, sizeof srcdir); *strrchr(srcdir, '/') = 0;
        char srcnt[1100] = ""; cat(srcnt, sizeof srcnt, srcdir); cat(srcnt, sizeof srcnt, "/ntdll.so");
        char ntlink[1400] = ""; cat(ntlink, sizeof ntlink, macos); cat(ntlink, sizeof ntlink, "/ntdll.so");
        char ntdst[1400]; ssize_t n = readlink(srcnt, ntdst, sizeof ntdst - 1);
        if (n > 0) { ntdst[n] = 0; unlink(ntlink); symlink(ntdst, ntlink); }
        if (fresh || copy_file(path, target) == 0) {
            char plist[1400] = ""; cat(plist, sizeof plist, contents); cat(plist, sizeof plist, "/Info.plist");
            int fd = open(plist, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                char xml[2048] = "";
                cat(xml, sizeof xml, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n<key>CFBundleExecutable</key><string>");
                cat(xml, sizeof xml, exe);
                cat(xml, sizeof xml, "</string>\n<key>CFBundleName</key><string>"); cat(xml, sizeof xml, name);
                cat(xml, sizeof xml, "</string>\n<key>CFBundleDisplayName</key><string>"); cat(xml, sizeof xml, name);
                cat(xml, sizeof xml, "</string>\n<key>CFBundleIdentifier</key><string>com.meridian.game.");
                cat(xml, sizeof xml, exe);
                cat(xml, sizeof xml, "</string>\n<key>CFBundlePackageType</key><string>APPL</string>\n"
                    "<key>LSApplicationCategoryType</key><string>public.app-category.games</string>\n"
                    "<key>GCSupportsGameMode</key><true/>\n<key>NSHighResolutionCapable</key><true/>\n"
                    "<key>CFBundleIconFile</key><string>game.icns</string>\n</dict></plist>\n");
                write(fd, xml, strlen(xml)); close(fd);
            }
            const char *icon = getenv("MERIDIAN_GAME_ICON");
            if (icon && *icon) {
                char res[1400] = ""; cat(res, sizeof res, contents); cat(res, sizeof res, "/Resources"); mkdir(res, 0755);
                cat(res, sizeof res, "/game.icns"); copy_file(icon, res);
            }
            if (fresh) { trace("redirect(fresh)", target, ""); strlcpy(out, target, cap); return out; }
            int rs = resign(target);
            trace(rs == 0 ? "redirect(resigned)" : "resign FAILED, falling back", target, "");
            if (rs == 0) { strlcpy(out, target, cap); return out; }
        } else trace("copy FAILED", target, "");
    }
    return NULL;
}

static int meridian_execve(const char *path, char *const argv[], char *const envp[]) {
    char t[1400]; trace("execve", path, "");
    const char *r = redirect(path, t, sizeof t);
    return execve(r ? r : path, argv, envp);
}
static int meridian_execv(const char *path, char *const argv[]) {
    char t[1400]; trace("execv", path, "");
    const char *r = redirect(path, t, sizeof t);
    return execv(r ? r : path, argv);
}
static int meridian_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                                const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    char t[1400]; trace("posix_spawn", path, "");
    const char *r = redirect(path, t, sizeof t);
    return posix_spawn(pid, r ? r : path, fa, attr, argv, envp);
}
static int meridian_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                                 const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    char t[1400]; trace("posix_spawnp", file, "");
    const char *r = redirect(file, t, sizeof t);
    return posix_spawnp(pid, r ? r : file, fa, attr, argv, envp);
}
static int meridian_execvp(const char *file, char *const argv[]) {
    char t[1400]; trace("execvp", file, "");
    const char *r = redirect(file, t, sizeof t);
    return execvp(r ? r : file, argv);
}
DYLD_INTERPOSE(meridian_execve, execve)
DYLD_INTERPOSE(meridian_execv, execv)
DYLD_INTERPOSE(meridian_execvp, execvp)
DYLD_INTERPOSE(meridian_posix_spawn, posix_spawn)
DYLD_INTERPOSE(meridian_posix_spawnp, posix_spawnp)
