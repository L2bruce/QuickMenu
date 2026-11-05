#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "=========================================="
echo "    🔨 Building QuickMenu (Native macOS)  "
echo "=========================================="

# 1. Regenerate templates
echo "-> [1/6] Preparing templates..."
python3 Templates/generate_templates.py >/dev/null

BUILD_DIR="$DIR/build"
APP_NAME="QuickMenu.app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME"
EXT_NAME="QuickMenuSyncExtension.appex"
EXT_BUNDLE="$APP_BUNDLE/Contents/PlugIns/$EXT_NAME"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/Templates"
mkdir -p "$EXT_BUNDLE/Contents/MacOS"
mkdir -p "$EXT_BUNDLE/Contents/Resources/Templates"

# Copy Templates & Resources
cp Templates/新建* "$APP_BUNDLE/Contents/Resources/Templates/"
cp Templates/新建* "$EXT_BUNDLE/Contents/Resources/Templates/"
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Copy Info.plist
cp HostApp/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Extension/Info.plist "$EXT_BUNDLE/Contents/Info.plist"

# 2. Compile Extension
echo "-> [2/6] Compiling FinderSync Extension..."
xcrun swiftc -O \
    -target arm64-apple-macos14.0 \
    -framework Cocoa \
    -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -module-name QuickMenuSyncExtension \
    Extension/FinderSyncExtension.swift \
    Extension/FileOperations.swift \
    -o "$EXT_BUNDLE/Contents/MacOS/QuickMenuSyncExtension"

# 3. Compile Host App
echo "-> [3/6] Compiling Host App..."
xcrun swiftc -O \
    -target arm64-apple-macos14.0 \
    -framework Cocoa \
    -framework FinderSync \
    HostApp/main.swift \
    HostApp/AppDelegate.swift \
    Extension/FileOperations.swift \
    -o "$APP_BUNDLE/Contents/MacOS/QuickMenu"

# 4. Code Sign
echo "-> [4/6] Code signing bundles (Ad-hoc)..."
codesign -s - --force --entitlements Resources/Extension.entitlements "$EXT_BUNDLE"
codesign -s - --force "$APP_BUNDLE"

echo "-> [5/6] Installing to /Applications/..."
# Kill any existing instance
pkill -f "QuickMenu" 2>/dev/null || true

# Copy to /Applications
rm -rf "/Applications/$APP_NAME"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME"

# 5. Register with LaunchServices and PlugInKit
echo "-> [6/6] Registering plugin with macOS..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME"
pluginkit -a "/Applications/$APP_NAME/Contents/PlugIns/$EXT_NAME"
pluginkit -e use -i com.bruce.QuickMenu.QuickMenuSyncExtension

echo "=========================================="
echo "    🎉 Build & Installation Complete!     "
echo "=========================================="
echo ""
echo "QuickMenu 已安装至 /Applications/QuickMenu.app"
echo "若要启用，请确保在系统设置中勾选访达扩展："
echo "系统设置 -> 隐私与安全性 -> 扩展 -> 访达 (勾选 QuickMenu Extension)"
