#!/usr/bin/env bash
# Configure + build Vita3KiOS.app. Needs: macOS, Xcode, cmake, ninja, git.
# usage: configure_ios.sh <moltenvk_dir> [build_dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MVK_DIR="${1:?moltenvk dir produced by ios/moltenvk/build_moltenvk.sh}"
BUILD="${2:-$ROOT/build-ios}"
VCPKG_ROOT="${VCPKG_ROOT:-$ROOT/vcpkg}"

python3 "$ROOT/ios/patches/apply_ios_patches.py"

if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
    git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
    BASELINE="$(python3 -c "import json;print(json.load(open('$ROOT/vcpkg.json'))['builtin-baseline'])")"
    git -C "$VCPKG_ROOT" checkout "$BASELINE"
    "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
fi

cmake -S "$ROOT" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET=arm64-ios-vita3k \
    -DVCPKG_HOST_TRIPLET=arm64-osx \
    -DVCPKG_OVERLAY_TRIPLETS="$ROOT/ios/vcpkg/triplets" \
    -DMOLTENVK_IOS_DIR="$MVK_DIR" \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -fno-semantic-interposition" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -fno-semantic-interposition" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF

cmake --build "$BUILD" --target Vita3KiOS --parallel
echo "App bundle: $BUILD/ios-bin/Vita3KiOS.app"
