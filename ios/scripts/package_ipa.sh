#!/usr/bin/env bash
# Packages Vita3KiOS.app into
#   Vita3K-iOS.tipa  (TrollStore: full JIT entitlements, signed with ldid)
#   Vita3K-iOS.ipa   (sideloading: conservative entitlements, JIT via debugger)
# usage: package_ipa.sh <path/to/Vita3KiOS.app> <output_dir>
set -euo pipefail

APP="${1:?path to Vita3KiOS.app}"
OUT="${2:?output dir}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LDID="${LDID:-ldid}"
command -v "$LDID" >/dev/null || { echo "ldid not found (brew install ldid)"; exit 1; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_package() {
    local ents="$1" name="$2"
    local stage="$WORK/$name"
    rm -rf "$stage"
    mkdir -p "$stage/Payload"
    cp -R "$APP" "$stage/Payload/Vita3KiOS.app"
    local bundle="$stage/Payload/Vita3KiOS.app"

    rm -rf "$bundle/_CodeSignature"
    # nested code first, then the main executable
    find "$bundle" -name '*.dylib' -print0 | while IFS= read -r -d '' lib; do
        "$LDID" -S "$lib"
    done
    "$LDID" -S"$ents" "$bundle/Vita3KiOS"

    (cd "$stage" && zip -qry -9 "$OUT/$name" Payload)
    echo "created $OUT/$name"
}

make_package "$HERE/entitlements/Vita3K.entitlements" "Vita3K-iOS.tipa"
make_package "$HERE/entitlements/Vita3K.sideload.entitlements" "Vita3K-iOS.ipa"
