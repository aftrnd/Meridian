#!/usr/bin/env bash
#
# build-wine.sh — build Wine from its published LGPL source (env.sh).
#
# Usage: bash Scripts/engine/build-wine.sh
#   Requires build-deps.sh to have populated $DEPS.
#
# Wine is x86_64 (run under Rosetta 2) with new-style WoW64 for 32-bit games:
# --enable-archs=i386,x86_64 builds i386 *PE* modules but no i386 Unix side.
# The configure host/build triple both claim x86_64: the arm64 clang emits
# x86_64 code and the build-time tools (winebuild, widl, wrc, makedep) are
# x86_64 binaries that Rosetta runs transparently. That keeps the compiler
# native (fast) without a separate tools build.
#
# No closed component is part of the source or built; Meridian selects D3D
# implementations itself (see package-engine.sh).
#
# Output: $WORK/wine-install (a `make install` tree under prefix /).

source "$(dirname "$0")/env.sh"

BUILD="$WORK/build-wine"
INSTALL="$WORK/wine-install"
PATCHES="$(cd "$(dirname "$0")" && pwd)/patches/wine"

# Meridian's own changes on top of the source. Idempotent: a patch
# that already reverse-applies is in the tree from an earlier run.
apply_patches() {
    local p
    for p in "$PATCHES"/*.patch; do
        [ -e "$p" ] || continue
        if patch -d "$SRC/wine" -p1 -R -s -f --dry-run < "$p" >/dev/null 2>&1; then
            continue
        fi
        say "Applying $(basename "$p")"
        patch -d "$SRC/wine" -p1 -N -s < "$p" || die "patch failed: $p"
    done
}

main() {
    [ -f "$DEPS/lib/libgnutls.30.dylib" ] || die "run build-deps.sh first"
    command -v x86_64-w64-mingw32-gcc >/dev/null || die "brew install mingw-w64"
    command -v i686-w64-mingw32-gcc   >/dev/null || die "brew install mingw-w64"

    apply_patches

    local gst="--without-gstreamer"
    [ -f "$DEPS/lib/pkgconfig/gstreamer-1.0.pc" ] && gst="--with-gstreamer"

    # 32-bit PE modules do their floating point in SSE, not x87 (mingw's i686
    # default). Rosetta has no fast path for x87: Wine's dsound resampler ran
    # ~118x slower as x87, so two resampled sounds already took a core and
    # Fallout: New Vegas stalled at 1 fps waiting on the mixer. Same flags as
    # Proton's i386 build (stack realigned: Windows callers keep 4-byte stacks).
    local i386_cflags="-g -O2 -mstackrealign -march=nocona -mtune=core-avx2 -mfpmath=sse"

    say "Configuring Wine $(cat "$SRC/wine/VERSION") (gstreamer: ${gst#--})"
    rm -rf "$BUILD"; mkdir -p "$BUILD"
    (
        cd "$BUILD"
        xcc_env
        "$SRC/wine/configure" \
            --host=x86_64-apple-darwin --build=x86_64-apple-darwin \
            --prefix=/ \
            --enable-archs=i386,x86_64 \
            i386_CFLAGS="$i386_cflags" \
            --disable-tests \
            --without-x --without-wayland --without-alsa --without-oss --without-pulse \
            --without-dbus --without-udev --without-v4l2 --without-sane --without-gphoto \
            --without-capi --without-krb5 --without-netapi --without-pcap --without-usb \
            --without-inotify --without-ffmpeg --without-unwind \
            --with-coreaudio --with-cups --with-gnutls --with-freetype --with-sdl \
            --with-vulkan --with-opencl \
            $gst
    ) > "$WORK/wine-configure.log" 2>&1 || { tail -30 "$WORK/wine-configure.log"; die "configure failed"; }

    grep -E '^configure: (WARNING|libs)|support will not|not found' "$WORK/wine-configure.log" | grep -v '^$' || true

    say "Building Wine ($JOBS jobs)"
    make -C "$BUILD" -j"$JOBS" > "$WORK/wine-make.log" 2>&1 \
        || { grep -nE 'error:|Error [0-9]' "$WORK/wine-make.log" | head -20; die "make failed (see $WORK/wine-make.log)"; }

    say "Installing to $INSTALL"
    rm -rf "$INSTALL"
    make -C "$BUILD" install-lib DESTDIR="$INSTALL" > "$WORK/wine-install.log" 2>&1 \
        || die "install failed (see $WORK/wine-install.log)"
    "$INSTALL/bin/wine" --version
}

main "$@"
