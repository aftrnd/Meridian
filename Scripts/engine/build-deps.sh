#!/usr/bin/env bash
#
# build-deps.sh — cross-compile the engine's x86_64 Unix libraries from source.
#
# Usage: bash Scripts/engine/build-deps.sh [package ...]
#   No arguments builds everything in order. Each package writes a stamp file
#   under $WORK/stamps, so re-runs skip finished packages; delete the stamp to
#   rebuild one.
#
# Outputs: $DEPS/{include,lib} (x86_64, install names under $DEPS/lib — the
# packaging step rewrites them to @rpath).

source "$(dirname "$0")/env.sh"

STAMPS="$WORK/stamps"
mkdir -p "$DL" "$WORK" "$DEPS" "$STAMPS"

fetch_cx_sources() {
    [ -d "$SRC/wine" ] && return
    say "Fetching CrossOver ${CX_SOURCE_VERSION} source"
    curl -fL -o "$DL/crossover-sources-${CX_SOURCE_VERSION}.tar.gz" "$CX_SOURCE_URL"
    tar -C "$BUILD_ROOT" -xzf "$DL/crossover-sources-${CX_SOURCE_VERSION}.tar.gz"
}

# Fetch an upstream tarball into $DL and unpack it into $WORK; echoes the dir.
fetch_tar() {
    local url="$1" name="${1##*/}"
    [ -f "$DL/$name" ] || curl -fsSL -o "$DL/$name" "$url"
    local dir
    dir="$(tar -tf "$DL/$name" | head -1 | cut -d/ -f1)"
    [ -d "$WORK/$dir" ] || tar -C "$WORK" -xf "$DL/$name"
    echo "$WORK/$dir"
}

# Out-of-tree autotools build of a source dir.
autotools() {
    local src="$1"; shift
    local bdir="$WORK/build-$(basename "$src")"
    [ -x "$src/configure" ] || ( cd "$src" && autoreconf -fi )
    rm -rf "$bdir"; mkdir -p "$bdir"
    ( cd "$bdir" && xcc_env && "$src/configure" $AT_HOST --prefix="$DEPS" "$@" \
        && make -j"$JOBS" && make install )
}

meson_build() {
    local src="$1"; shift
    local bdir="$WORK/build-$(basename "$src")"
    rm -rf "$bdir"
    meson setup "$bdir" "$src" --cross-file "$WORK/x86_64-darwin.cross" \
        --prefix="$DEPS" --libdir=lib --buildtype=release "$@"
    ninja -C "$bdir" -j"$JOBS" install
}

# MARK: - Packages

build_gmp() {
    # --enable-fat: runtime CPU dispatch, safe under Rosetta's x86 feature set.
    autotools "$SRC/gnutls/gmp" --enable-shared --disable-static --enable-fat
}

build_nettle() {
    # CodeWeavers' tree ships nettle without Makefile.in; use the GNU release
    # of the same 3.10 line.
    local src; src="$(fetch_tar https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz)"
    autotools "$src" --enable-shared --disable-static --enable-fat \
        --disable-documentation --disable-openssl
}

build_gnutls() {
    autotools "$SRC/gnutls/gnutls" --enable-shared --disable-static \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit \
        --without-idn --disable-gost --without-brotli --without-zstd --without-zlib --without-tpm --without-tpm2 \
        --disable-doc --disable-tests --disable-tools --disable-cxx --disable-nls \
        --disable-guile --disable-libdane --disable-full-test-suite \
        NETTLE_LIBS="-lnettle" HOGWEED_LIBS="-lhogweed" GMP_LIBS="-lgmp"
}

build_freetype() {
    meson_build "$SRC/freetype" -Dpng=disabled -Dharfbuzz=disabled -Dbrotli=disabled \
        -Dbzip2=disabled -Dzlib=internal -Dtests=disabled
}

build_sdl2() {
    local src; src="$(fetch_tar https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz)"
    local bdir="$WORK/build-sdl2"
    rm -rf "$bdir"
    cmake -S "$src" -B "$bdir" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$DEPS" -DSDL_STATIC=OFF -DSDL_TEST=OFF
    ninja -C "$bdir" install
}

build_moltenvk() {
    # Upstream Khronos release (Apache-2.0). The macOS dylib is universal; keep
    # only the x86_64 slice. Vulkan headers come from the same tarball.
    local tar="$DL/MoltenVK-macos-1.4.2.tar"
    [ -f "$tar" ] || curl -fsSL -o "$tar" https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar
    rm -rf "$WORK/MoltenVK"; tar -C "$WORK" -xf "$tar"
    local dylib
    dylib="$(find "$WORK/MoltenVK" -name libMoltenVK.dylib -path '*dynamic*' | head -1)"
    [ -n "$dylib" ] || die "libMoltenVK.dylib not found in MoltenVK release"
    mkdir -p "$DEPS/lib" "$DEPS/include"
    lipo "$dylib" -thin x86_64 -output "$DEPS/lib/libMoltenVK.dylib" 2>/dev/null \
        || cp "$dylib" "$DEPS/lib/libMoltenVK.dylib"
    install_name_tool -id "$DEPS/lib/libMoltenVK.dylib" "$DEPS/lib/libMoltenVK.dylib"
    local inc; inc="$(find "$WORK/MoltenVK" -type d -name include -path '*MoltenVK/include' | head -1)"
    cp -R "$inc/"* "$DEPS/include/"
}

build_glib() {
    # CodeWeavers' glib 2.78 tree lacks the gvdb submodule, and 2.78's
    # gdbus-codegen needs Python's removed distutils. Upstream 2.82 has
    # neither problem and satisfies GStreamer 1.24 (>= 2.64). libffi, pcre2
    # and libintl come from glib's own meson wraps.
    local src; src="$(fetch_tar https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz)"
    meson_build "$src" -Dtests=false -Dinstalled_tests=false -Dnls=disabled \
        -Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
        -Dsysprof=disabled -Ddtrace=disabled -Dlibelf=disabled -Dman-pages=disabled \
        -Ddocumentation=false -Dglib_debug=disabled \
        --force-fallback-for=libffi,pcre2,proxy-libintl
}

build_gstreamer() {
    # winegstreamer's Media Foundation / DirectShow decode path. The plugin set
    # matches what Meridian engines have shipped: container demuxers (mp4, avi,
    # asf, wav), parsers, converters, and applemedia's VideoToolbox decoders.
    # ORC is off: a cross build needs a native `orcc`, and every element has a
    # plain-C fallback (video decode itself runs in VideoToolbox).
    meson_build "$SRC/gstreamer" -Dauto_features=disabled \
        -Dbase=enabled -Dgood=enabled -Dbad=enabled -Dugly=enabled \
        -Dlibav=disabled -Dtests=disabled -Dexamples=disabled -Ddoc=disabled \
        -Dintrospection=disabled -Dpython=disabled -Ddevtools=disabled -Dges=disabled \
        -Drtsp_server=disabled -Dsharp=disabled -Dvaapi=disabled -Dlibnice=disabled \
        -Dtools=disabled -Dorc=disabled -Dbuild-tools-source=system \
        -Dgstreamer:tools=disabled -Dgstreamer:check=disabled -Dgstreamer:coretracers=disabled \
        -Dgst-plugins-base:app=enabled -Dgst-plugins-base:audioconvert=enabled \
        -Dgst-plugins-base:audioresample=enabled -Dgst-plugins-base:playback=enabled \
        -Dgst-plugins-base:typefind=enabled -Dgst-plugins-base:videoconvertscale=enabled \
        -Dgst-plugins-base:gl=enabled -Dgst-plugins-base:gl_api=opengl \
        -Dgst-plugins-base:gl_platform=cgl -Dgst-plugins-base:gl_winsys=cocoa \
        -Dgst-plugins-good:audioparsers=enabled -Dgst-plugins-good:avi=enabled \
        -Dgst-plugins-good:deinterlace=enabled -Dgst-plugins-good:id3demux=enabled \
        -Dgst-plugins-good:isomp4=enabled -Dgst-plugins-good:videofilter=enabled \
        -Dgst-plugins-good:wavparse=enabled \
        -Dgst-plugins-bad:applemedia=enabled -Dgst-plugins-bad:videoparsers=enabled \
        -Dgst-plugins-bad:gl=enabled \
        -Dgst-plugins-ugly:asfdemux=enabled
}

ALL=(gmp nettle gnutls freetype sdl2 moltenvk glib gstreamer)

main() {
    command -v meson >/dev/null || die "meson missing: brew install meson ninja cmake bison flex"
    fetch_cx_sources
    write_meson_cross
    local pkgs=("$@"); [ ${#pkgs[@]} -gt 0 ] || pkgs=("${ALL[@]}")
    for p in "${pkgs[@]}"; do
        if [ -f "$STAMPS/$p" ] && [ $# -eq 0 ]; then say "$p: already built"; continue; fi
        say "Building $p"
        "build_$p"
        touch "$STAMPS/$p"
    done
    say "Dependencies installed in $DEPS"
}

main "$@"
