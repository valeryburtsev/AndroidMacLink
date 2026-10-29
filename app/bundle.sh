#!/bin/bash
# Build "Phone Mac Link.app": a release build wrapped in an app bundle and signed for local use.
#   ./bundle.sh            -> build/Phone Mac Link.app
# The app's name is Phone Mac Link since 2026-10-10. Its identifier (com.winphone.app), its
# executable and its folders keep the old name, so that the saved account, the phone's link,
# the permissions macOS has granted and the settings all carry over.
# Notification Center and the Keychain need a bundle identifier, which a bare executable lacks.
set -euo pipefail
cd "$(dirname "$0")"
# The linker would otherwise record the deployment target as the SDK the app was built with,
# and macOS then draws the app in the look of that old system instead of the current one.
sdk="$(xcrun --show-sdk-version)"
swift build -c release --product WinPhone -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk" 2>&1 | grep -E "error|Compiling|Build complete" | tail -3
bin="$(swift build -c release --show-bin-path)/WinPhone"
# Made beside the app and put in its place only when whole: a copy launched in the middle of
# a build (by a click, or macOS bringing it back) once found no Info.plist and was aborted.
final="build/Phone Mac Link.app"
app="build/.Phone Mac Link.app.new"
rm -rf "$app" "build/WinPhone.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/WinPhone"
# The icon is drawn by tools/icon/make-icon.swift and kept as a file.
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# And as an asset catalog, the form newer macOS looks for first (CFBundleIconName): Notification
# Center drew a blank placeholder for this app with the .icns alone (2026-10-15), while Finder
# and the Dock drew the icon. Made from the same .icns when Xcode's asset compiler is there.
iconname=""
if [ -f Resources/AppIcon.icns ] && xcrun --find actool >/dev/null 2>&1; then
  work="$(mktemp -d)"
  iconutil -c iconset Resources/AppIcon.icns -o "$work/AppIcon.iconset"
  set_dir="$work/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$set_dir"
  cp "$work/AppIcon.iconset/"*.png "$set_dir/"
  images=""
  for size in 16 32 128 256 512; do
    for scale in 1 2; do
      if [ "$scale" = 2 ]; then file="icon_${size}x${size}@2x.png"; else file="icon_${size}x${size}.png"; fi
      [ -f "$set_dir/$file" ] && images="$images{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"$file\"},"
    done
  done
  printf '{"images":[%s],"info":{"version":1,"author":"xcode"}}' "${images%,}" > "$set_dir/Contents.json"
  printf '{"info":{"version":1,"author":"xcode"}}' > "$work/Assets.xcassets/Contents.json"
  if xcrun actool --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
       --app-icon AppIcon --output-partial-info-plist "$work/partial.plist" "$work/Assets.xcassets" >/dev/null 2>&1; then
    iconname="AppIcon"
  else
    echo "asset catalog not made; the .icns alone is used"
  fi
  rm -rf "$work"
fi
# A build number of its own for every build: macOS keeps what it knows of an app (its icon
# among it) by identifier and version, and an unchanging number keeps an old picture alive.
build_number="$(date +%Y%m%d%H%M%S)"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.winphone.app</string>
    <key>CFBundleName</key><string>Phone Mac Link</string>
    <key>CFBundleDisplayName</key><string>Phone Mac Link</string>
    <key>CFBundleExecutable</key><string>WinPhone</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>${iconname:-AppIcon}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>${build_number}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Phone Mac Link connects directly to your phone on the local network to receive files you share from it.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Phone Mac Link uses Bluetooth to show, answer and place your phone's calls from this Mac.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key><array><dict>
        <key>CFBundleTypeName</key><string>File to send to the phone</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>None</string>
        <key>LSItemContentTypes</key><array><string>public.data</string></array>
    </dict></array>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>com.winphone.app.link</string>
        <key>CFBundleURLSchemes</key><array><string>winphone</string></array>
    </dict></array>
</dict>
</plist>
PLIST
# Sign with a development identity when one exists: the Keychain ties the app's saved state to
# its signature, and an ad hoc signature changes with every build, which makes macOS ask again
# after each rebuild. Set WINPHONE_ADHOC=1 to force ad hoc signing.
identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
if [ -n "$identity" ] && [ -z "${WINPHONE_ADHOC:-}" ] && codesign --force --sign "$identity" "$app" 2>/dev/null; then
  echo "signed with $identity"
else
  codesign --force --sign - "$app" 2>&1 | tail -1
  echo "signed ad hoc"
fi
# Swapped in as late as possible, the old copy out and the whole new one in.
rm -rf "$final"
mv "$app" "$final"
echo "built $final"
