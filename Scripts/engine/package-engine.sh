#!/usr/bin/env bash
#
# package-engine.sh — assemble the Meridian engine tarball from source-built parts.
#
# Usage: bash Scripts/engine/package-engine.sh <vX.Y.Z-engine>
#   Requires build-deps.sh and build-wine.sh to have run.
#   Produces $BUILD_ROOT/meridian-engine-arm64.tar.gz (the asset EngineDownloader
#   installs into ~/Library/Application Support/com.meridian.app/engine/).
#   Publishing is a separate step: Scripts/engine/publish-engine.sh.
#
# Nothing here is taken from a CrossOver install. Components:
#   Wine        CodeWeavers' published CrossOver source (LGPL-2.1)   build-wine.sh
#   libraries   GnuTLS, nettle, gmp, freetype, SDL2, GLib, GStreamer   build-deps.sh
#   MoltenVK    Khronos release (Apache-2.0)                           build-deps.sh
#   DXMT        3Shain/dxmt release (MIT)                              fetched here
#
# Renderer selection (replaces CrossOver's closed cxcompatdb.so):
#   Wine searches its own lib/wine before any WINEDLLPATH entry, so a DLL that
#   exists there can never be overridden per launch. The D3D front-end DLLs that
#   Meridian switches between are therefore moved OUT of lib/wine into one
#   directory per implementation. WineEngine builds each launch's search path
#   as  <preferred backend>:lib/wined3d:lib/wine  so Wine's own implementation
#   fills in whatever the preferred backend does not provide:
#     lib/dxmt/    d3d11 dxgi d3d10core (+ nvapi64, nvngx)   D3D10/11 → Metal
#     lib/wined3d/ d3d11 dxgi d3d10core d3d12 d3d12core      Wine's own
#   DXMT's backend, winemetal.dll/.so, links Wine's winemac.so via @loader_path
#   and has no Wine counterpart, so it lives in lib/wine itself.
#
# Not shipped: Apple D3DMetal (GPTK license), cxcompatdb.so (closed source),
# the gbe_fork Steamworks emulator, and any Valve binary.

source "$(dirname "$0")/env.sh"

TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-engine$ ]] || die "usage: package-engine.sh vX.Y.Z-engine"

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
WINE_INSTALL="$WORK/wine-install"
ARCHIVE="$BUILD_ROOT/meridian-engine-arm64.tar.gz"
DXMT_VERSION="v0.80"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/${DXMT_VERSION}/dxmt-${DXMT_VERSION}-builtin.tar.gz"
INSTALLED_ENGINE="$HOME/Library/Application Support/com.meridian.app/engine"

# The D3D front-ends Meridian switches between per launch. d3d12 moves too:
# while it sits in lib/wine nothing on WINEDLLPATH can ever replace it.
SWITCHED_DLLS=(d3d11 dxgi d3d10core d3d12 d3d12core)

W="$STAGE/wine"

# MARK: - Wine

stage_wine() {
    say "Staging Wine $("$WINE_INSTALL/bin/wine" --version)"
    rm -rf "$STAGE"; mkdir -p "$W"
    cp -R "$WINE_INSTALL/bin" "$WINE_INSTALL/lib" "$WINE_INSTALL/share" "$W/"
    # The app launches bin/wine64 (historical name); Wine 11 has one loader.
    cp "$W/bin/wine" "$W/bin/wine64"

    # Wine's PE side builds with -g; without stripping, every DLL (and its
    # copy in the prefix template's system32) carries DWARF.
    say "Stripping debug info"
    find "$W/lib/wine/x86_64-windows" -name '*.dll' -o -name '*.exe' -o -name '*.drv' -o -name '*.sys' \
        | xargs x86_64-w64-mingw32-strip --strip-debug 2>/dev/null || true
    find "$W/lib/wine/i386-windows" -type f \
        | xargs i686-w64-mingw32-strip --strip-debug 2>/dev/null || true
    find "$W/lib/wine/x86_64-unix" -type f | xargs strip -S 2>/dev/null || true
    strip -S "$W/bin/wine" "$W/bin/wine64" "$W/bin/wineserver"

    say "Moving Wine's D3D front-ends to lib/wined3d"
    local arch dll
    for arch in x86_64-windows i386-windows; do
        mkdir -p "$W/lib/wined3d/$arch"
        for dll in "${SWITCHED_DLLS[@]}"; do
            mv "$W/lib/wine/$arch/$dll.dll" "$W/lib/wined3d/$arch/"
        done
    done
}

# MARK: - DXMT

stage_dxmt() {
    say "Staging DXMT $DXMT_VERSION"
    local tar="$DL/dxmt-${DXMT_VERSION}-builtin.tar.gz"
    [ -f "$tar" ] || curl -fsSL -o "$tar" "$DXMT_URL"
    local src="$WORK/dxmt/$DXMT_VERSION"
    rm -rf "$WORK/dxmt"; mkdir -p "$WORK/dxmt"; tar -C "$WORK/dxmt" -xzf "$tar"

    local arch dll
    for arch in x86_64-windows i386-windows; do
        mkdir -p "$W/lib/dxmt/$arch"
        for dll in "$src/$arch"/*.dll; do
            case "$(basename "$dll")" in
                winemetal.dll) cp "$dll" "$W/lib/wine/$arch/" ;;
                *)             cp "$dll" "$W/lib/dxmt/$arch/" ;;
            esac
        done
    done
    cp "$src/x86_64-unix/winemetal.so" "$W/lib/wine/x86_64-unix/"
    echo "DXMT $DXMT_VERSION" > "$W/meridian-dxmt-version.txt"
}

# MARK: - Libraries

# Copy the x86_64 dylibs Wine loads into wine/lib64 and rewrite every
# reference to the build prefix into @rpath, so the tree is relocatable.
stage_libraries() {
    say "Staging libraries into wine/lib64"
    mkdir -p "$W/lib64/gstreamer-1.0"
    local f
    for f in "$DEPS"/lib/*.dylib; do
        [ -L "$f" ] && continue           # real files only; links recreated below
        cp "$f" "$W/lib64/"
    done
    # Recreate the versioned symlinks that dlopen() and the linker use.
    for f in "$DEPS"/lib/*.dylib; do
        [ -L "$f" ] || continue
        ln -sf "$(readlink "$f")" "$W/lib64/$(basename "$f")"
    done
    cp "$DEPS"/lib/gstreamer-1.0/*.dylib "$W/lib64/gstreamer-1.0/"

    say "Rewriting install names to @rpath"
    local bin
    while IFS= read -r bin; do
        relink "$bin"
    done < <(find "$W" -type f \( -name '*.dylib' -o -name '*.so' \) ; echo "$W/bin/wine"; echo "$W/bin/wine64"; echo "$W/bin/wineserver")
    # Wine's own Unix modules find lib64 through this rpath.
    for bin in "$W"/lib/wine/x86_64-unix/*.so; do
        add_rpath "$bin" "@loader_path/../../../lib64"
    done
    for bin in "$W"/lib64/*.dylib; do
        [ -L "$bin" ] || add_rpath "$bin" "@loader_path"
    done
    for bin in "$W"/lib64/gstreamer-1.0/*.dylib; do
        add_rpath "$bin" "@loader_path/.."
    done
}

relink() {
    local bin="$1" dep
    file "$bin" | grep -q 'Mach-O' || return 0
    case "$bin" in "$W"/lib64/*.dylib)
        install_name_tool -id "@rpath/$(basename "$bin")" "$bin" 2>/dev/null ;;
    esac
    while IFS= read -r dep; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$bin" 2>/dev/null
    done < <(otool -L "$bin" | awk 'NR>1 {print $1}' | grep "^$DEPS/")
}

add_rpath() {
    otool -l "$1" | grep -A2 LC_RPATH | grep -q "path $2 " \
        || install_name_tool -add_rpath "$2" "$1" 2>/dev/null
}

# MARK: - Meridian tools

stage_meridian_tools() {
    say "Building Meridian's Wine-side helpers"
    mkdir -p "$W/share/meridian" "$STAGE/tools"
    bash "$SCRIPTS/build-coremessaging.sh" "$W/lib/wine/x86_64-windows/coremessaging.dll"
    bash "$SCRIPTS/build-dpapi.sh" "$W/share/meridian/meridian-dpapi.exe"
    bash "$SCRIPTS/build-wine-accessory.sh" "$W/share/meridian/meridian-wine-accessory.dylib"

    local dd="$STAGE/tools/depotdownloader/DepotDownloader"
    mkdir -p "$(dirname "$dd")"
    if command -v dotnet >/dev/null; then
        bash "$SCRIPTS/build-depotdownloader.sh" "$dd"
    elif [ -x "$INSTALLED_ENGINE/tools/depotdownloader/DepotDownloader" ]; then
        # Meridian's own fork (GPL-2.0); reuse the previously built binary.
        printf '\033[1;33m    dotnet not installed: reusing DepotDownloader from the installed engine\033[0m\n'
        cp "$INSTALLED_ENGINE/tools/depotdownloader/DepotDownloader" "$dd"
    else
        die "DepotDownloader: install dotnet (brew install dotnet) to build it"
    fi
}

# MARK: - Signing

sign_loader() {
    # Ad-hoc sign the loader with the entitlements Meridian relies on:
    # DYLD_INSERT_LIBRARIES (wine-accessory) and JIT-style memory for games.
    say "Signing Wine loader"
    local ent="$WORK/wine-entitlements.plist"
    cat > "$ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
EOF
    local bin
    for bin in "$W/bin/wine" "$W/bin/wine64" "$W/lib/wine/x86_64-unix/wine"; do
        codesign --force --sign - --entitlements "$ent" "$bin"
    done
    # Everything else install_name_tool touched needs a fresh ad-hoc signature.
    find "$W" -type f \( -name '*.dylib' -o -name '*.so' \) -exec codesign --force --sign - {} + 2>/dev/null
    codesign --force --sign - "$W/bin/wineserver"
}

# MARK: - Prefix template

engine_env() {
    env -i HOME="$HOME" PATH="/usr/bin:/bin" \
        WINEPREFIX="$1" WINEDEBUG=-all WINEMSYNC=1 MVK_CONFIG_LOG_LEVEL=0 \
        WINEDLLPATH="$W/lib/dxmt:$W/lib/wine" \
        WINEDLLOVERRIDES="mscoree,mshtml=" \
        "${@:2}"
}

build_prefix_template() {
    # mscoree/mshtml disabled: wineboot must never prompt for Wine Mono/Gecko.
    say "Building prefix template (wineboot --init)"
    local tpl="$WORK/prefix-template" timeout
    timeout="$(command -v gtimeout || command -v timeout)" || die "brew install coreutils (gtimeout)"
    rm -rf "$tpl"
    engine_env "$tpl" "$timeout" 300 "$W/bin/wine64" wineboot --init \
        || die "wineboot --init failed or timed out"
    engine_env "$tpl" "$W/bin/wineserver" -w

    local dlls services
    dlls=$(find "$tpl/drive_c/windows/system32" -name '*.dll' | wc -l | tr -d ' ')
    services=$(grep -cE '^\[System\\\\(CurrentControlSet|ControlSet001)\\\\Services\\\\[^\\]+\]' "$tpl/system.reg" || true)
    [ "$dlls" -gt 100 ] || die "prefix template has only $dlls DLLs"
    # steamwebhelper networking needs the full wine.inf service registration.
    grep -q Winsock2 "$tpl/system.reg" || die "prefix template missing Winsock2 registration"
    grep -q Dnscache "$tpl/system.reg" || die "prefix template missing Dnscache registration"
    [ "$services" -ge 15 ] || die "prefix template has only $services services"
    echo "    template: $dlls DLLs, $services services"

    rm -rf "$tpl/dosdevices"; mkdir -p "$tpl/dosdevices" "$tpl/drive_c/windows/syswow64"
    cp -R "$tpl" "$STAGE/prefix-template"
}

# MARK: - Licenses

stage_licenses() {
    say "Staging license texts"
    local d="$STAGE/licenses"
    mkdir -p "$d"
    cp "$SRC/wine/COPYING.LIB" "$d/wine-LGPL-2.1.txt"
    cp "$SRC/wine/LICENSE"     "$d/wine-LICENSE.txt"
    cat > "$d/README.txt" <<EOF
Meridian engine $TAG — third-party components

Wine 11.0 (CodeWeavers CrossOver ${CX_SOURCE_VERSION} source)  LGPL-2.1
  Source: ${CX_SOURCE_URL}
DXMT ${DXMT_VERSION}                                MIT        https://github.com/3Shain/dxmt
MoltenVK 1.4.2                                     Apache-2.0 https://github.com/KhronosGroup/MoltenVK
GnuTLS, nettle, GMP                                LGPL       https://gnutls.org
FreeType                                           FTL        https://freetype.org
SDL2                                               zlib       https://libsdl.org
GLib, GStreamer                                    LGPL-2.1   https://gstreamer.freedesktop.org
DepotDownloader (Meridian fork)                    GPL-2.0    https://github.com/SteamRE/DepotDownloader

The LGPL components are dynamically loaded and unmodified from the cited
sources; build scripts are in the Meridian repository under Scripts/engine/.
EOF
}

# MARK: - Validate & archive

validate() {
    say "Validating"
    local f
    for f in bin/wine64 bin/wineserver share/wine/wine.inf share/wine/winmd/windows.system.winmd \
             share/wine/nls/l_intl.nls share/wine/nls/locale.nls share/wine/nls/normnfc.nls \
             lib/wine/x86_64-unix/winemetal.so lib/wine/x86_64-windows/winemetal.dll \
             lib/dxmt/x86_64-windows/d3d11.dll lib/dxmt/i386-windows/d3d11.dll \
             lib/wined3d/x86_64-windows/d3d11.dll lib/wined3d/i386-windows/d3d11.dll \
             lib64/libgnutls.30.dylib lib64/libMoltenVK.dylib lib64/libfreetype.6.dylib; do
        [ -e "$W/$f" ] || die "missing wine/$f"
    done
    for f in "${SWITCHED_DLLS[@]}"; do
        [ ! -e "$W/lib/wine/x86_64-windows/$f.dll" ] || die "$f.dll still in lib/wine (would shadow WINEDLLPATH)"
    done
    # No absolute build paths may survive in the shipped Mach-O files.
    local leaks
    leaks=$(find "$W" -type f \( -name '*.dylib' -o -name '*.so' \) -exec otool -L {} + 2>/dev/null \
        | grep $'^\t' | grep -c "$BUILD_ROOT" || true)
    [ "$leaks" -eq 0 ] || die "$leaks library references still point into $BUILD_ROOT"
    ! find "$STAGE" -name 'cxcompatdb*' -o -name 'D3DMetal*' | grep -q . || die "closed-source component in stage"
}

main() {
    [ -x "$WINE_INSTALL/bin/wine" ] || die "run build-wine.sh first"
    stage_wine
    stage_dxmt
    stage_libraries
    stage_meridian_tools
    sign_loader
    echo "$TAG" > "$W/meridian-engine-version.txt"
    build_prefix_template
    stage_licenses
    validate

    say "Creating $ARCHIVE"
    rm -f "$ARCHIVE"
    tar -C "$STAGE" -czf "$ARCHIVE" .
    du -sh "$ARCHIVE"
}

main "$@"
