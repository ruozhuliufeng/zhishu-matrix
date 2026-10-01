#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
APP_NAME="智枢矩阵"
EXECUTABLE="ZhishuMatrix"
mkdir -p build
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon-source.png -nt Resources/AppIcon.icns ]]; then
    zsh scripts/build-icon.sh
fi
clang -fobjc-arc -mmacosx-version-min=14.0 -O2 -Wall \
    -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers -framework Network \
    -framework Security -framework LocalAuthentication -framework UserNotifications \
    Sources/*.m -o "build/$EXECUTABLE"

APP_DIR="$PWD/build/$APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "build/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Resources/*.js "$APP_DIR/Contents/Resources/"
codesign --force --sign - "$APP_DIR"
touch "$APP_DIR"
print "Built $APP_DIR"
