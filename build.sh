#!/bin/zsh
# Builds BillRenamer.app into the project root.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="BillRenamer.app"
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/BillRenamer "$APP/Contents/MacOS/BillRenamer"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# The binary references @rpath/Sparkle.framework — point rpath at Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/BillRenamer"

xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
xattr -cr "$APP"
codesign --force --sign - "$APP"

# iCloud/Finder can stamp com.apple.FinderInfo onto nested bundles after
# signing. That xattr invalidates the signature of Sparkle's XPC services,
# and macOS then refuses to launch Installer.xpc — updates download but never
# install. Clear once more, then verify DEEPLY: plain `codesign -v` is shallow
# and does not look inside the framework, so it misses exactly this failure.
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"
