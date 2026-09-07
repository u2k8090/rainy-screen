#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Verification builds must not replace the app whose privacy permissions are granted.
DEST="$PWD/dist/preview/Rainy Screen.app"
if [[ "${1:-}" == "--install" ]]; then
    DEST="$PWD/dist/Rainy Screen.app"
elif [[ -n "${1:-}" ]]; then
    print -u2 'Usage: ./scripts/build.sh [--install]'
    exit 2
fi
swift build -c release
mkdir -p "${DEST:h}"
STAGE="$(mktemp -d "${DEST:h}/.build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Rainy Screen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --show-bin-path)"
cp "$BIN/RainyScreen" "$APP/Contents/MacOS/RainyScreen"
cp -R "$BIN/RainyScreen_RainyScreen.bundle" "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
# Convert the editable .icon package's PNG layer into the multi-size .icns
# that LaunchServices uses for the app bundle. Rebuilding picks up icon edits.
ICON_SOURCE="$PWD/icon/rainy-screen-iOS-Default-1024x1024@1x.png"
if [[ -f "$ICON_SOURCE" ]]; then
    ICONSET="$STAGE/RainyScreen.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size*2))
        sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil --convert icns --output "$APP/Contents/Resources/RainyScreen.icns" "$ICONSET"
else
    print -u2 "Warning: 指定したアイコンPNGがないため、アイコンを生成できません。"
fi
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
# Replace the bundle atomically instead of modifying a running executable in place.
if [[ -d "$DEST" ]]; then mv "$DEST" "$STAGE/previous.app"; fi
mv "$APP" "$DEST"
print "Built: $DEST"
if [[ "${1:-}" == "--install" ]]; then
    print 'Ad-hoc update: macOS may require renewing Screen Recording permission after relaunch.'
fi
