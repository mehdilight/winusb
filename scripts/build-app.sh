#!/bin/bash
# Builds WinUSB.app (universal if possible) and bundles wimlib-imagex inside it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/WinUSB.app"
VERSION="1.0.0"

echo "==> Building release binaries"
swift build -c release --product WinUSB
swift build -c release --product winusb-cli
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/wimlib"
cp "$BIN/WinUSB" "$APP/Contents/MacOS/WinUSB"
cp "$BIN/winusb-cli" "$APP/Contents/MacOS/winusb-cli"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WinUSB</string>
  <key>CFBundleDisplayName</key><string>WinUSB</string>
  <key>CFBundleIdentifier</key><string>com.winusb.mac</string>
  <key>CFBundleExecutable</key><string>WinUSB</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>WinUSB writes the Windows installer files to your USB drive.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>WinUSB reads Windows ISO files from your Downloads folder.</string>
</dict>
</plist>
EOF

# ---- App icon
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# ---- Bundle wimlib (needed to split install.wim > 4 GB)
WIM="$(command -v wimlib-imagex || true)"
if [ -n "$WIM" ]; then
  WIM="$(realpath "$WIM")"
  LIB="$(otool -L "$WIM" | awk '/libwim/ {print $1}')"
  # Homebrew's install name may point at /opt/homebrew/opt/...; resolve to a real file.
  LIBFILE="$(realpath "$LIB")"
  echo "==> Bundling $WIM and $LIBFILE"
  cp "$WIM" "$APP/Contents/Resources/wimlib/wimlib-imagex"
  cp "$LIBFILE" "$APP/Contents/Resources/wimlib/$(basename "$LIB")"
  chmod u+w "$APP/Contents/Resources/wimlib/"*
  install_name_tool -change "$LIB" "@executable_path/$(basename "$LIB")" "$APP/Contents/Resources/wimlib/wimlib-imagex"
  install_name_tool -id "@executable_path/$(basename "$LIB")" "$APP/Contents/Resources/wimlib/$(basename "$LIB")"
  # Use bundled wimlib's license alongside it (wimlib is LGPLv3/GPLv3).
  PREFIX="$(dirname "$(dirname "$WIM")")"
  cp "$PREFIX"/COPYING* "$APP/Contents/Resources/wimlib/" 2>/dev/null || true
else
  echo "!!  wimlib-imagex not found — the app will still work, but ISOs with an"
  echo "    install.wim > 4 GB need it at runtime. Install with: brew install wimlib"
fi

echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP/Contents/Resources/wimlib/"*.dylib 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Resources/wimlib/wimlib-imagex" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/winusb-cli"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "    Optional DMG:  hdiutil create -volname WinUSB -srcfolder $APP -ov -format UDZO build/WinUSB.dmg"
