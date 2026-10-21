#!/usr/bin/env bash
#
# build-d3d9.sh — build the D3D9 → Metal path from source:
#
#   DXVK          d3d9.dll (32/64-bit PE), Direct3D 9 → Vulkan     zlib
#   Vulkan-Loader libvulkan.1.dylib (x86_64), picks the driver      Apache-2.0
#   KosmicKrisp   libvulkan_kosmickrisp.dylib (x86_64), Vulkan →    MIT
#                 Metal 4 (Mesa); needs macOS 26 at run time
#
# Usage: bash Scripts/engine/build-d3d9.sh
#   Output: $WORK/d3d9-install/{dxvk/{x86_64,i386}-windows/d3d9.dll, lib64/*.dylib}
#
# Why not MoltenVK: DXVK 3.x samples every D3D9 texture through one image that
# is also used for depth compares; MoltenVK 1.4.2's SPIRV-Cross types it
# depth2d and colour textures read back as one channel (Pattern 32), and
# MoltenVK lacks robustness2 / nullDescriptor, which DXVK requires. KosmicKrisp
# has both and picks depth or colour per instruction. DXVK still asks for
# geometryShader and fillModeNonSolid, which KosmicKrisp lacks; D3D9 uses them
# only for ProcessVertices and wireframe, so patches/dxvk makes them optional.
#
# Wine loads MoltenVK by default; patch 0009 lets a launch name this loader
# (WINE_VULKAN_LIBRARY) and the loader takes its driver from VK_DRIVER_FILES.
#
# KosmicKrisp compiles internal kernels at build time with Mesa's tools, so
# Mesa builds twice: those tools natively (arm64), then the x86_64 driver.
# Prerequisites:
#   brew install meson ninja cmake glslang llvm libclc spirv-llvm-translator spirv-tools

source "$(dirname "$0")/env.sh"

DXVK_REPO="https://github.com/doitsujin/dxvk.git"
DXVK_COMMIT="d713ef8748a1eee3e90d4b6d5dc2e80f5be4b519"    # master, Oct 21 2026 (3.1.1-151)
LOADER_REPO="https://github.com/KhronosGroup/Vulkan-Loader.git"
LOADER_TAG="v1.4.365"
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_COMMIT="687304e237c27d9f9b9f964db2c6dd929ff85749"     # main, Oct 21 2026 (27.0.0-devel)

OUT="$WORK/d3d9-install"
PATCHES="$(cd "$(dirname "$0")" && pwd)/patches/dxvk"
VENV="$BUILD_ROOT/venv-mesa"
MESA_TOOLS="$WORK/mesa-native-tools"

# A git checkout of $1 at revision $3 in $2, fetched shallow when it's a commit.
checkout() {
    local repo="$1" dir="$2" rev="$3"
    if [ ! -d "$dir/.git" ]; then
        git init -q "$dir"
        git -C "$dir" remote add origin "$repo"
    fi
    local have want
    have="$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)"
    want="$(git -C "$dir" rev-parse -q --verify "$rev^{commit}" 2>/dev/null || true)"
    if [ -z "$have" ] || [ "$have" != "$want" ]; then
        git -C "$dir" fetch -q --depth 1 origin "$rev"
        git -C "$dir" checkout -q -f FETCH_HEAD
    fi
}

# MARK: - DXVK

build_dxvk() {
    local src="$SRC/dxvk-git"
    say "DXVK $DXVK_COMMIT"
    checkout "$DXVK_REPO" "$src" "$DXVK_COMMIT"
    git -C "$src" submodule -q update --init --recursive --depth 1
    local p
    for p in "$PATCHES"/*.patch; do
        if git -C "$src" apply -R --check "$p" 2>/dev/null; then continue; fi
        say "Applying $(basename "$p")"
        git -C "$src" apply "$p" || die "patch failed: $p"
    done

    local bits arch
    for bits in 32 64; do
        local bdir="$WORK/build-dxvk$bits"
        rm -rf "$bdir"
        meson setup --cross-file "$src/build-win$bits.txt" --buildtype release -Dbuild_id=false \
            -Denable_dxgi=false -Denable_d3d8=false -Denable_d3d10=false -Denable_d3d11=false \
            "$bdir" "$src" > "$WORK/dxvk-setup$bits.log" 2>&1 \
            || { tail -20 "$WORK/dxvk-setup$bits.log"; die "DXVK $bits-bit configure failed"; }
        ninja -C "$bdir" src/d3d9/d3d9.dll > "$WORK/dxvk-build$bits.log" 2>&1 \
            || { grep -m10 error "$WORK/dxvk-build$bits.log"; die "DXVK $bits-bit build failed"; }
        arch=$([ "$bits" = 32 ] && echo i386-windows || echo x86_64-windows)
        mkdir -p "$OUT/dxvk/$arch"
        cp "$bdir/src/d3d9/d3d9.dll" "$OUT/dxvk/$arch/"
    done
}

# MARK: - Vulkan loader

build_loader() {
    local src="$SRC/Vulkan-Loader"
    say "Vulkan-Loader $LOADER_TAG"
    checkout "$LOADER_REPO" "$src" "$LOADER_TAG"
    local bdir="$WORK/build-vkloader"
    rm -rf "$bdir"
    cmake -S "$src" -B "$bdir" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DUPDATE_DEPS=ON -DBUILD_TESTS=OFF -DBUILD_WERROR=OFF > "$WORK/vkloader-setup.log" 2>&1 \
        || { tail -20 "$WORK/vkloader-setup.log"; die "Vulkan-Loader configure failed"; }
    ninja -C "$bdir" > "$WORK/vkloader-build.log" 2>&1 || die "Vulkan-Loader build failed (see $WORK/vkloader-build.log)"
    mkdir -p "$OUT/lib64"
    cp "$bdir/loader/libvulkan.1.dylib" "$OUT/lib64/"
}

# MARK: - KosmicKrisp

build_kosmickrisp() {
    local src="$SRC/mesa"
    say "Mesa KosmicKrisp $MESA_COMMIT"
    checkout "$MESA_REPO" "$src" "$MESA_COMMIT"
    [ -x "$VENV/bin/python3" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q mako pyyaml packaging; }

    local common=(-Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false -Dzstd=disabled)

    # 1. Native (arm64) build-time tools: mesa_clc, vtn_bindgen2, kk_clc.
    say "  native tools"
    rm -rf "$WORK/build-mesa-native" "$MESA_TOOLS"
    ( export PATH="$(brew --prefix llvm)/bin:$VENV/bin:$PATH"
      export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig:$(brew --prefix llvm)/lib/pkgconfig"
      unset PKG_CONFIG_LIBDIR
      meson setup "$WORK/build-mesa-native" "$src" --buildtype=release --prefix="$MESA_TOOLS" "${common[@]}" \
          -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true \
          > "$WORK/mesa-native-setup.log" 2>&1 \
          || { tail -20 "$WORK/mesa-native-setup.log"; exit 1; }
      ninja -C "$WORK/build-mesa-native" install > "$WORK/mesa-native-build.log" 2>&1 \
          || { grep -m10 error: "$WORK/mesa-native-build.log"; exit 1; }
    ) || die "Mesa native tools failed"

    # 2. The x86_64 driver. Metal 4 means macOS 26: its own cross file.
    say "  x86_64 driver"
    write_meson_cross
    sed 's/-mmacosx-version-min=[0-9.]*/-mmacosx-version-min=26.0/g' "$WORK/x86_64-darwin.cross" > "$WORK/x86_64-darwin-26.cross"
    rm -rf "$WORK/build-mesa-x64"
    ( export PATH="$MESA_TOOLS/bin:$VENV/bin:$PATH"
      meson setup "$WORK/build-mesa-x64" "$src" --cross-file "$WORK/x86_64-darwin-26.cross" \
          --buildtype=release "${common[@]}" -Dllvm=disabled -Dxmlconfig=disabled -Dbuild-tests=false \
          -Dmesa-clc=system -Dprecomp-compiler=system > "$WORK/mesa-x64-setup.log" 2>&1 \
          || { tail -20 "$WORK/mesa-x64-setup.log"; exit 1; }
      ninja -C "$WORK/build-mesa-x64" > "$WORK/mesa-x64-build.log" 2>&1 \
          || { grep -m10 error: "$WORK/mesa-x64-build.log"; exit 1; }
    ) || die "KosmicKrisp build failed"
    local vk="$WORK/build-mesa-x64/src/kosmickrisp/vulkan"
    mkdir -p "$OUT/lib64"
    cp "$vk/libvulkan_kosmickrisp.dylib" "$OUT/lib64/"
    # Mesa's manifest names its install path; the loader resolves a relative
    # library_path against the manifest's own directory.
    python3 -I - "$vk/kosmickrisp_mesa_icd.x86_64.json" "$OUT/lib64/kosmickrisp_icd.json" <<'PY'
import json, sys
icd = json.load(open(sys.argv[1]))
icd["ICD"]["library_path"] = "./libvulkan_kosmickrisp.dylib"
json.dump(icd, open(sys.argv[2], "w"), indent=4)
PY
}

main() {
    command -v glslangValidator >/dev/null || die "brew install glslang"
    command -v "$(brew --prefix llvm)/bin/llvm-config" >/dev/null || die "brew install llvm libclc spirv-llvm-translator spirv-tools"
    rm -rf "$OUT"; mkdir -p "$OUT"
    build_dxvk
    build_loader
    build_kosmickrisp
    mkdir -p "$OUT/licenses"
    cp "$SRC/dxvk-git/LICENSE"          "$OUT/licenses/dxvk-LICENSE.txt"
    cp "$SRC/Vulkan-Loader/LICENSE.txt" "$OUT/licenses/vulkan-loader-LICENSE.txt"
    cp "$SRC/mesa/docs/license.rst"     "$OUT/licenses/mesa-license.rst"
    echo "DXVK $DXVK_COMMIT, Vulkan-Loader $LOADER_TAG, Mesa $MESA_COMMIT" > "$OUT/versions.txt"
    say "D3D9 path built into $OUT"
}

main "$@"
