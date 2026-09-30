#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
SOURCE="$PWD/Resources/AppIcon-source.png"
ICONSET="$PWD/build/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns --output Resources/AppIcon.icns "$ICONSET"
print "Built Resources/AppIcon.icns"
