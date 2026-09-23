#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --cache-path .build/cache --config-path .build/config --security-path .build/security
BIN="$PWD/.build/release"
STAGE="$PWD/.build/package"
APP="$PWD/dist/RunOnSleep.app"
mkdir -p dist
rm -rf "$STAGE" "$APP"
mkdir -p "$STAGE/root/Library/PrivilegedHelperTools" "$STAGE/root/Library/LaunchDaemons" "$STAGE/scripts"
install -m 755 "$BIN/RunOnSleepHelper" "$STAGE/root/Library/PrivilegedHelperTools/com.runonsleep.helper"
codesign --force --sign - --identifier com.runonsleep.helper "$STAGE/root/Library/PrivilegedHelperTools/com.runonsleep.helper"
install -m 644 Resources/com.runonsleep.helper.plist "$STAGE/root/Library/LaunchDaemons/"
install -m 755 Scripts/preinstall "$STAGE/scripts/preinstall"
install -m 755 Scripts/postinstall "$STAGE/scripts/postinstall"
pkgbuild --root "$STAGE/root" --scripts "$STAGE/scripts" --identifier com.runonsleep.helper.pkg \
    --version 0.1.0 --install-location / --ownership recommended dist/RunOnSleepHelper.pkg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/bash Scripts/build-icon.sh
install -m 644 .build/RunOnSleep.icns "$APP/Contents/Resources/AppIcon.icns"
install -m 755 "$BIN/RunOnSleep" "$APP/Contents/MacOS/RunOnSleep"
install -m 644 Resources/Info.plist "$APP/Contents/Info.plist"
install -m 644 dist/RunOnSleepHelper.pkg "$APP/Contents/Resources/"
install -m 644 docs/USER_GUIDE.md "$APP/Contents/Resources/"
install -m 755 Scripts/uninstall.sh "$APP/Contents/Resources/Uninstall RunOnSleep.command"
codesign --force --sign - --identifier com.runonsleep.app "$APP"
codesign --verify --strict "$APP"
install -m 755 Scripts/uninstall.sh "dist/Uninstall RunOnSleep.command"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/RunOnSleep.zip
printf 'Built %s\n' "$APP" "$PWD/dist/RunOnSleepHelper.pkg"
