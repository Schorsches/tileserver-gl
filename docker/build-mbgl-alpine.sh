#!/bin/sh
# Build @maplibre/maplibre-gl-native's `mbgl.node` addon against musl (Alpine).
#
# Upstream publishes exactly one Linux prebuilt binary. It is glibc-linked and
# soname-pinned to Ubuntu 24.04's ICU 74 (libicuuc.so.74), and it renders through
# GLX/X11 -- which is why the stock image carries the whole X stack plus Xvfb.
# None of that works on Alpine, so we compile the addon ourselves and select the
# headless EGL backend instead, removing X11 from the runtime image entirely.
#
# Run inside an Alpine container that has a matching Node.js (the ABI is baked
# into the output path). See .github/workflows/build-mbgl-alpine.yml.
#
# Env:
#   MAPLIBRE_REF  git tag to build           (default: node-v6.4.1)
#   SRC_DIR       checkout location          (default: /usr/src/maplibre-native)
#   OUT_DIR       where the tarball lands    (default: /out)
#   NODE_ABI      node ABI, e.g. 137         (default: from the local node)
#   JOBS          parallel compile jobs      (default: nproc)
#   INSTALL_DEPS  1 to apk add build deps    (default: 1)
#   BUILTIN_ICU   ON to vendor ICU statically (default: ON)
#   STUB_SRC      musl-bigstack.c location    (default: alongside this script)
set -eu

MAPLIBRE_REF="${MAPLIBRE_REF:-node-v6.4.1}"
SRC_DIR="${SRC_DIR:-/usr/src/maplibre-native}"
OUT_DIR="${OUT_DIR:-/out}"
NODE_ABI="${NODE_ABI:-$(node -p 'process.versions.modules')}"
JOBS="${JOBS:-$(nproc)}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
# Vendoring ICU drops libicuuc/libicui18n/libicudata from NEEDED -- the exact
# soname pin that makes the upstream prebuilt binary Ubuntu-24.04-only -- and
# keeps icu-libs (~33 MB, a recurring CVE source) out of the runtime image.
BUILTIN_ICU="${BUILTIN_ICU:-ON}"
STUB_SRC="${STUB_SRC:-$(dirname "$0")/musl-bigstack.c}"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) NPG_ARCH=x64 ;;
  aarch64) NPG_ARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

if [ "$INSTALL_DEPS" = "1" ]; then
  # Most heavy dependencies (boost, freetype, harfbuzz, icu, sqlite, protozero)
  # are vendored in the maplibre-native tree, so this list stays short.
  #
  # icu-dev is needed at configure time even though we vendor ICU: linux.cmake
  # line 153 reads `if(NOT ${ICUUC_FOUND} OR ...)`, which is a CMake syntax
  # error when ICUUC_FOUND is undefined because ICU is absent entirely. It is a
  # build-stage package only and never reaches the runtime image.
  apk add --no-cache \
    build-base cmake samurai git python3 linux-headers pkgconf \
    curl-dev libjpeg-turbo-dev libpng-dev libwebp-dev libuv-dev \
    zlib-dev mesa-dev mesa-gles icu-dev binutils
fi

if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --depth 1 --branch "$MAPLIBRE_REF" \
    --recurse-submodules --shallow-submodules --jobs 4 \
    https://github.com/maplibre/maplibre-native.git "$SRC_DIR"
fi

cd "$SRC_DIR"

# MLN_WITH_EGL selects platform/linux/src/headless_backend_egl.cpp and links
# OpenGL::EGL, giving surfaceless headless rendering with no X server.
# MLN_WITH_X11 defaults to ON and would pull in find_package(X11 REQUIRED);
# MLN_WITH_GLFW defaults to ON and drags X11 in behind it.
# MLN_WITH_WERROR defaults to ON -- Alpine's GCC warns where upstream's
# toolchain does not, so leaving it on turns any new warning into a build break.
#
# OPENGL_USE_GLES3 is required, not optional: CMake's FindOpenGL insists on the
# GLVND libOpenGL.so unless one of OPENGL_USE_GLES2/3 is set, and Alpine ships no
# libglvnd package. Upstream's Wayland branch sets the same flag for the same
# reason (see the comment in platform/linux/linux.cmake).
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENGL_USE_GLES3=TRUE \
  -DMLN_WITH_NODE=ON \
  -DMLN_WITH_OPENGL=ON \
  -DMLN_WITH_EGL=ON \
  -DMLN_WITH_X11=OFF \
  -DMLN_WITH_GLFW=OFF \
  -DMLN_WITH_WERROR=OFF \
  -DMLN_USE_BUILTIN_ICU="$BUILTIN_ICU" \
  -DBUILD_TESTING=OFF \
  -DCMAKE_SHARED_LINKER_FLAGS="-lGLESv2"

# platform/node/cmake/module.cmake generates one shared-library target per
# supported Node ABI (mbgl-node.abi-115, .abi-127, .abi-137, ...). `mbgl-node`
# itself is an INTERFACE library and is not buildable. Build only our ABI --
# the others are several times the work for binaries we would discard.
cmake --build build --target "mbgl-node.abi-${NODE_ABI}" -j "$JOBS"

ADDON="$SRC_DIR/platform/node/lib/node-v${NODE_ABI}/mbgl.node"
[ -f "$ADDON" ] || { echo "expected addon not produced at $ADDON" >&2; exit 1; }

# Gate: the whole point of this build is a musl-linked, X11-free, EGL addon.
# Fail loudly rather than shipping something that only appears to work.
echo "--- readelf -d ---"
readelf -d "$ADDON" | grep NEEDED || true
readelf -lW "$ADDON" | grep -i 'program interpreter' || true

fail=0
BAD="libc.so.6 libX11.so libXext.so libGLX.so libOpenGL.so"
[ "$BUILTIN_ICU" = "ON" ] && BAD="$BAD libicuuc.so libicui18n.so libicudata.so"
for bad in $BAD; do
  if readelf -d "$ADDON" | grep -q "$bad"; then
    echo "GATE FAILED: $ADDON still links $bad" >&2
    fail=1
  fi
done
readelf -d "$ADDON" | grep -q 'libEGL.so' || {
  echo "GATE FAILED: $ADDON does not link libEGL.so -- the GLX path was taken" >&2
  fail=1
}
[ "$fail" = "0" ] || exit 1

mkdir -p "$OUT_DIR"
cp "$ADDON" "$OUT_DIR/mbgl.node"
strip --strip-unneeded "$OUT_DIR/mbgl.node" 2>/dev/null || true

# The LD_PRELOAD stub that raises musl's 128 KiB default thread stack to 8 MiB.
# See musl-bigstack.c for why the addon itself cannot carry this header.
gcc -shared -fPIC -O2 -o "$OUT_DIR/libmusl-bigstack.so" "$STUB_SRC" \
    -Wl,-z,stack-size=8388608 -Wl,--build-id=none
readelf -lW "$OUT_DIR/libmusl-bigstack.so" | grep -q 'GNU_STACK.* 0x800000' || {
  echo "GATE FAILED: libmusl-bigstack.so does not carry an 8 MiB PT_GNU_STACK" >&2
  exit 1
}

# Also emit the tarball in the layout node-pre-gyp expects (a single
# node-v<abi>/mbgl.node entry), for anyone installing outside Docker via
# npm_config_maplibre_gl_native_binary_host_mirror.
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/node-v${NODE_ABI}"
cp "$OUT_DIR/mbgl.node" "$STAGE/node-v${NODE_ABI}/mbgl.node"
TARBALL="$OUT_DIR/node-v${NODE_ABI}-linuxmusl-${NPG_ARCH}-Release.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" "node-v${NODE_ABI}"
rm -rf "$STAGE"
( cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

cat > "$OUT_DIR/BUILDINFO.json" <<JSON
{
  "maplibre_ref": "${MAPLIBRE_REF}",
  "node_abi": "${NODE_ABI}",
  "arch": "${NPG_ARCH}",
  "libc": "musl",
  "alpine_version": "$(cat /etc/alpine-release 2>/dev/null || echo unknown)",
  "gl_backend": "egl-surfaceless",
  "builtin_icu": "${BUILTIN_ICU}",
  "needed": [$(readelf -d "$OUT_DIR/mbgl.node" | sed -n 's/.*Shared library: \[\(.*\)\]/"\1"/p' | paste -sd, -)]
}
JSON

echo "built $TARBALL"
cat "$TARBALL.sha256"
cat "$OUT_DIR/BUILDINFO.json"
