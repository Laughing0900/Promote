#!/bin/sh
# Build Promote.app from the release binary and install to /Applications. Usage: ./make-app.sh
set -e
cd "$(dirname "$0")"

echo "==> Building (release)..."
swift build -c release

echo "==> Assembling $PWD/Promote.app..."
APP=Promote.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Promote</string>
    <key>CFBundleDisplayName</key><string>Promote</string>
    <key>CFBundleIdentifier</key><string>com.laughing.promote</string>
    <key>CFBundleExecutable</key><string>Promote</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.5</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF

# icon.jpg -> AppIcon.icns
if [ -f icon.jpg ]; then
    echo "==> Generating AppIcon.icns..."
    mkdir -p "$APP/Contents/Resources"
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -s format png -z $s $s icon.jpg --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -s format png -z $((s*2)) $((s*2)) icon.jpg --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cp .build/release/Promote "$APP/Contents/MacOS/Promote"

# Stable signature keeps TCC grants (Desktop access etc.) across rebuilds; ad-hoc re-prompts every build.
# One-time setup: Keychain Access > Certificate Assistant > Create a Certificate...
#   Name: promote-dev, Identity Type: Self-Signed Root, Certificate Type: Code Signing
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/promote-dev/ {print $2; exit}')
echo "==> Signing (identity: ${SIGN_ID:-ad-hoc})..."
codesign --force --sign "${SIGN_ID:--}" "$APP"

echo "==> Installing to /Applications..."
rm -rf /Applications/Promote.app
cp -R "$APP" /Applications/
echo "==> Installed to /Applications/Promote.app"

if pgrep -x Promote >/dev/null; then
    echo "==> Promote is currently running — quit and reopen to pick up this build."
else
    echo "==> Promote is not running — launch with: open /Applications/Promote.app"
fi
