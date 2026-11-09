#!/bin/zsh
# Archives Pigeon for iPhone and uploads it to App Store Connect (then it
# appears in TestFlight, ready to submit for review).
#   ios/release.sh
# Needs: Xcode signed in to your paid developer account, your team in
# Config/Local.xcconfig, and the app created in App Store Connect.
# The build number is the git commit count, so every upload is higher.
set -euo pipefail
cd "${0:A:h}"

BUILD=$(git rev-list --count HEAD)
VERSION=$(awk -F'"' '/MARKETING_VERSION/ { print $2; exit }' project.yml)
TEAM=$(awk -F'= *' '/DEVELOPMENT_TEAM/ { print $2; exit }' Config/Local.xcconfig)
echo "Pigeon $VERSION ($BUILD) for team $TEAM"

xcodegen generate >/dev/null
rm -rf build/Pigeon.xcarchive build/export
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Pigeon.xcarchive \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath build/Pigeon.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
echo "Uploaded Pigeon $VERSION ($BUILD). It shows up in App Store Connect → TestFlight after processing."
