# Shared environment for the from-source engine build. Sourced, not executed.
#
# The engine is x86_64 (Wine runs under Rosetta 2). Every Unix-side library is
# cross-compiled for x86_64 on an Apple Silicon host with the system clang —
# same SDK, different -arch — so no Intel Homebrew or Rosetta toolchain is
# needed. Native build tools (meson, ninja, cmake, bison, mingw-w64) come from
# the host's arm64 Homebrew.
#
# Nothing in this build reads from a CrossOver install. Sources come from
# CodeWeavers' published LGPL source tarball and upstream project releases.

set -euo pipefail

: "${BUILD_ROOT:=$HOME/meridian-engine-build}"   # outside Dropbox: large, churny
export BUILD_ROOT
export SRC="$BUILD_ROOT/sources"                  # unpacked crossover-sources tarball
export DL="$BUILD_ROOT/downloads"
export WORK="$BUILD_ROOT/work"
export DEPS="$BUILD_ROOT/deps"                    # x86_64 install prefix for libraries
export STAGE="$BUILD_ROOT/stage"                  # assembled engine (becomes engine/)

# CrossOver's published source (Wine 11.0 + CodeWeavers patches, LGPL).
export CX_SOURCE_VERSION="26.3.0"
export CX_SOURCE_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_SOURCE_VERSION}.tar.gz"

export MACOSX_DEPLOYMENT_TARGET="15.0"            # matches the app's minimum
export ARCH_FLAGS="-arch x86_64 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export JOBS="$(sysctl -n hw.ncpu)"

BREW="$(brew --prefix)"
export PATH="$BREW/opt/bison/bin:$BREW/opt/flex/bin:$BREW/opt/libtool/libexec/gnubin:$PATH"

# Isolate pkg-config to the x86_64 prefix so arm64 Homebrew libraries are
# never picked up by a cross build.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig"
unset PKG_CONFIG_PATH

xcc_env() {
    export CC="clang $ARCH_FLAGS"
    export CXX="clang++ $ARCH_FLAGS"
    export OBJC="clang $ARCH_FLAGS"
    export CPPFLAGS="-I$DEPS/include"
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
    export LDFLAGS="-L$DEPS/lib -Wl,-headerpad_max_install_names"
}

# Autotools cross triple: build on arm64, host x86_64.
export AT_HOST="--host=x86_64-apple-darwin --build=aarch64-apple-darwin"

# Meson cross file for x86_64.
write_meson_cross() {
    mkdir -p "$WORK"
    cat > "$WORK/x86_64-darwin.cross" <<EOF
[binaries]
c = ['clang', '-arch', 'x86_64', '-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}']
cpp = ['clang++', '-arch', 'x86_64', '-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}']
objc = ['clang', '-arch', 'x86_64', '-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}']
objcpp = ['clang++', '-arch', 'x86_64', '-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-I$DEPS/include']
cpp_args = ['-I$DEPS/include']
c_link_args = ['-L$DEPS/lib', '-Wl,-headerpad_max_install_names']
cpp_link_args = ['-L$DEPS/lib', '-Wl,-headerpad_max_install_names']
objc_link_args = ['-L$DEPS/lib', '-Wl,-headerpad_max_install_names']

[properties]
pkg_config_libdir = '$DEPS/lib/pkgconfig'
needs_exe_wrapper = false

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Rosetta can run x86_64 binaries, so configure-time run tests work and
# needs_exe_wrapper stays false.
