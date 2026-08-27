#!/bin/zsh
# Publishes a new version: ./release.sh 1.1.0
# Builds the app, zips it into releases/, signs it, regenerates the Sparkle
# appcast, and pushes everything to GitHub. Installed apps pick the update
# up automatically.
set -euo pipefail
cd "$(dirname "$0")"

if [[ $# -ne 1 ]]; then
    echo "Usage: ./release.sh <version>   e.g. ./release.sh 1.1.0" >&2
    exit 1
fi
VERSION="$1"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist

./build.sh

mkdir -p releases
ZIP="releases/BillRenamer-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent BillRenamer.app "$ZIP"

# Signs each zip with the EdDSA key from the login keychain and rewrites
# releases/appcast.xml.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast releases/ \
    --download-url-prefix "https://raw.githubusercontent.com/Yiannismtx/BillRenamer/main/releases/"

git add releases Resources/Info.plist
git commit -m "Release $VERSION"
git push origin main

echo ""
echo "Released $VERSION. Installed apps will see the update on their next check."
