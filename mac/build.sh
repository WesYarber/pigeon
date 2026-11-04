#!/bin/zsh
# Builds Pigeon.app (menu bar receiver) with just the Xcode command line tools.
set -euo pipefail
# The repo root, worked out before the cd below (after it, a relative $0 such as
# ./mac/build.sh would resolve against mac/ and land one level too deep).
ROOT="${0:A:h:h}"
cd "${0:A:h}"

APP=build/Pigeon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Icons are generated from ../icons/make_icons.swift (one drawing for every size).
swift ../icons/make_icons.swift build/icons >/dev/null
cp build/icons/AppIcon.icns build/icons/MenuBarIcon*.png "$APP/Contents/Resources/"

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/Pigeon" \
  Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.wesyarber.pigeon</string>
  <key>CFBundleName</key><string>Pigeon</string>
  <key>CFBundleExecutable</key><string>Pigeon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>net.wesyarber.pigeon</string>
    <key>CFBundleURLSchemes</key><array><string>pigeon</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Anything</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>public.item</string><string>public.folder</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# The Share menu extension (mac/ShareExtension). Extensions must be sandboxed.
EXT="$APP/Contents/PlugIns/PigeonShare.appex"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
cp build/icons/AppIcon.icns "$EXT/Contents/Resources/"
swiftc -O -swift-version 5 -parse-as-library -application-extension -module-name PigeonShare \
  -target "$(uname -m)-apple-macos13.0" \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/Contents/MacOS/PigeonShare" \
  ShareExtension/*.swift
cat > "$EXT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.wesyarber.pigeon.share</string>
  <key>CFBundleName</key><string>Pigeon</string>
  <key>CFBundleDisplayName</key><string>Pigeon</string>
  <key>CFBundleExecutable</key><string>PigeonShare</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key><string>PigeonShareViewController</string>
    <key>NSExtensionAttributes</key>
    <dict>
      <key>NSExtensionActivationRule</key>
      <dict>
        <key>NSExtensionActivationSupportsFileWithMaxCount</key><integer>50</integer>
        <key>NSExtensionActivationSupportsImageWithMaxCount</key><integer>50</integer>
        <key>NSExtensionActivationSupportsMovieWithMaxCount</key><integer>50</integer>
        <key>NSExtensionActivationSupportsText</key><true/>
        <key>NSExtensionActivationSupportsWebURLWithMaxCount</key><integer>1</integer>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST
cat > build/share.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
PLIST

# Remember where this was built from and which commit, for Settings → Update Pigeon.
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ "$COMMIT" != unknown ] && [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT+"; fi
plutil -insert PigeonSourceDir -string "$ROOT" "$APP/Contents/Info.plist"
plutil -insert PigeonCommit -string "$COMMIT" "$APP/Contents/Info.plist"

# Signing. macOS remembers Keychain "Always Allow" answers per app, and for an
# app without an Apple Team ID it ties them to that exact build, which is why
# every update used to ask for your password again (once per Keychain item).
# Signing with your Apple Development certificate (free with any Apple ID via
# Xcode > Settings > Accounts) gives every build the same Team ID, so updates
# keep their access. Override with PIGEON_SIGN_IDENTITY="<name or SHA-1>".
IDENTITY="${PIGEON_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"(Apple Development|Developer ID Application|Mac Developer):/ { print $2; exit }')
fi
if [[ -z "$IDENTITY" ]]; then
  echo "No Apple Development certificate found, so macOS may ask for Keychain access after each update."
  echo "To fix: open Xcode > Settings > Accounts, add your Apple ID, then Manage Certificates > + > Apple Development."
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" --entitlements build/share.entitlements "$EXT" # inside out
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $PWD/$APP"
