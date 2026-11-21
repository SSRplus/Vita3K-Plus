#!/usr/bin/env bash
# Builds a MoltenVK that only contains what Vita3K needs on iOS.
#
# What is trimmed (nothing Vita3K relies on is removed):
#   * only the iOS device (arm64) dynamic library is built: no macOS, tvOS, visionOS, simulator
#     or MacCatalyst slices, no static xcframework, no ShaderConverter tool, no docs
#   * the library is compiled with -O3, dead code stripping and fully stripped symbols
#     (only the exported Vulkan entry points remain)
#   * the *default* runtime configuration is changed to what a shipping emulator wants:
#       - log level = errors only (the stock default is INFO and prints on every pipeline compile)
#       - no performance tracking, no watermark, no vulkan call tracing
#       - pipeline compilation may use every core (removes shader compile stutter)
#   * every Vulkan feature, extension and the SPIRV-Cross -> MSL translation path is kept exactly
#     as shipped by Khronos, so the shaders that Vita3K emits are translated the same way as on macOS.
#     Metal argument buffers are already on by default in MoltenVK 1.2.x and are left on.
#
# Output layout (consumed by -DMOLTENVK_IOS_DIR=<out_dir>):
#   <out_dir>/include/MoltenVK/*.h
#   <out_dir>/dylib/iOS/libMoltenVK.dylib
set -euo pipefail

OUT_DIR="${1:?usage: build_moltenvk.sh <out_dir>}"
MVK_TAG="${MVK_TAG:-v1.2.11}"
WORK_DIR="${MVK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/moltenvk-src}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

mkdir -p "$(dirname "$WORK_DIR")"
if [ ! -d "$WORK_DIR/.git" ]; then
    git clone --depth 1 --branch "$MVK_TAG" https://github.com/KhronosGroup/MoltenVK "$WORK_DIR"
fi
cd "$WORK_DIR"

# external dependencies (SPIRV-Cross, SPIRV-Tools, glslang, Vulkan headers ...) for iOS only
./fetchDependencies --ios

rm -rf Package

xcodebuild build \
    -project MoltenVKPackaging.xcodeproj \
    -scheme "MoltenVK Package (iOS only)" \
    -destination "generic/platform=iOS" \
    -configuration Release \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS=arm64 \
    GCC_OPTIMIZATION_LEVEL=3 \
    DEAD_CODE_STRIPPING=YES \
    COPY_PHASE_STRIP=YES \
    STRIP_INSTALLED_PRODUCT=YES \
    STRIP_STYLE=non-global \
    DEBUG_INFORMATION_FORMAT=dwarf \
    CODE_SIGNING_ALLOWED=NO \
    GCC_PREPROCESSOR_DEFINITIONS='$(inherited) MVK_CONFIG_LOG_LEVEL=1 MVK_CONFIG_PERFORMANCE_TRACKING=0 MVK_CONFIG_DISPLAY_WATERMARK=0 MVK_CONFIG_TRACE_VULKAN_CALLS=0 MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1'

echo "--- packaged files:"
find Package -type f 2>/dev/null | grep -v '/include/' | head -50 || true

DYLIB=""
for candidate in $(find Package -path '*dynamic*' \( -name libMoltenVK.dylib -o -path '*MoltenVK.framework/MoltenVK' \) -type f 2>/dev/null); do
    case "$candidate" in
        *[Ss]imulator*|*macOS*|*macos*|*tvOS*|*xrOS*|*visionOS*) continue ;;
    esac
    # keep only arm64 iOS device builds
    if lipo -info "$candidate" 2>/dev/null | grep -q arm64 && vtool -show-build "$candidate" 2>/dev/null | grep -q "platform IOS$"; then
        DYLIB="$candidate"
        break
    fi
done
if [ -z "$DYLIB" ]; then
    echo "error: libMoltenVK.dylib for iOS was not produced" >&2
    exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/dylib/iOS" "$OUT_DIR/include"
cp -p "$DYLIB" "$OUT_DIR/dylib/iOS/libMoltenVK.dylib"
cp -R MoltenVK/include/MoltenVK "$OUT_DIR/include/MoltenVK"

# make the dylib loadable from <app>/Frameworks through @rpath
install_name_tool -id "@rpath/libMoltenVK.dylib" "$OUT_DIR/dylib/iOS/libMoltenVK.dylib"

# sanity checks: the loader entry points Vita3K resolves must still be exported
EXPORTS="$(nm -gU "$OUT_DIR/dylib/iOS/libMoltenVK.dylib")"
for sym in _vkGetInstanceProcAddr _vkCreateInstance _vkCreateMetalSurfaceEXT; do
    if ! grep -q " $sym\$" <<<"$EXPORTS"; then
        echo "error: $sym is missing from the trimmed MoltenVK" >&2
        exit 1
    fi
done

lipo -info "$OUT_DIR/dylib/iOS/libMoltenVK.dylib"
ls -lh "$OUT_DIR/dylib/iOS/libMoltenVK.dylib"
echo "MoltenVK for iOS is ready in $OUT_DIR"
