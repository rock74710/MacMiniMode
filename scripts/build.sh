#!/bin/bash
# 構建通用二進位制、應用包和安裝包：build/MacMiniMode-<版本>.pkg
#
# 鑰匙串裡有 Developer ID 證書時自動簽名；再設定 NOTARY_PROFILE 就會公證並裝訂票據。
#   APP_IDENTITY    "Developer ID Application: ..."（預設自動查詢）
#   PKG_IDENTITY    "Developer ID Installer: ..."（預設自動查詢）
#   NOTARY_PROFILE  xcrun notarytool store-credentials 時起的名字
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(cat VERSION)}
MIN_OS=12.0
BUILD=build
ROOT=$BUILD/root
APP=$ROOT/Applications/MacMiniMode.app
DAEMON=$ROOT/Library/PrivilegedHelperTools/macmini-moded
PKG=$BUILD/MacMiniMode-$VERSION.pkg

find_identity() {
    security find-identity -v | sed -n "s/.*\"\($1: .*\)\"/\1/p" | head -n 1
}
# ADHOC=1：本機自用，不去鑰匙串裡找證書，一律 ad-hoc 簽名、安裝包不簽名。
if [ "${ADHOC:-0}" = 1 ]; then
    APP_IDENTITY=""
    PKG_IDENTITY=""
else
    APP_IDENTITY=${APP_IDENTITY:-$(find_identity "Developer ID Application")}
    PKG_IDENTITY=${PKG_IDENTITY:-$(find_identity "Developer ID Installer")}
fi
NOTARY_PROFILE=${NOTARY_PROFILE:-}

compile() {
    local source=$1 output=$2 name
    name=$(basename "$output")
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macos$MIN_OS" "$source"/*.swift -o "$BUILD/obj/$name-$arch"
    done
    lipo -create "$BUILD/obj/$name-arm64" "$BUILD/obj/$name-x86_64" -output "$output"
}

echo "==> 編譯 ${VERSION}（arm64 + x86_64）"
rm -rf "$BUILD"
mkdir -p "$BUILD/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources" \
    "$(dirname "$DAEMON")" "$ROOT/Library/LaunchDaemons" "$ROOT/Library/LaunchAgents"

compile Sources/daemon "$DAEMON"
compile Sources/menubar "$APP/Contents/MacOS/MacMiniMode"

sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
install -m 755 scripts/uninstall.sh Resources/macminimode "$APP/Contents/Resources/"
install -m 644 Resources/com.macminimode.daemon.plist "$ROOT/Library/LaunchDaemons/"
install -m 644 Resources/com.macminimode.menubar.plist "$ROOT/Library/LaunchAgents/"

echo "==> 簽名"
if [ -n "$APP_IDENTITY" ]; then
    echo "    $APP_IDENTITY"
    SIGN=(codesign --force --options runtime --timestamp --sign "$APP_IDENTITY")
else
    echo "    未找到 Developer ID Application 證書，使用 ad-hoc 簽名"
    SIGN=(codesign --force --sign -)
fi
"${SIGN[@]}" --identifier com.macminimode.daemon "$DAEMON"
"${SIGN[@]}" "$APP"

echo "==> 打包"
# 不關掉 relocatable 的話，安裝器會把應用裝到它在磁碟上找到的同名副本那裡。
pkgbuild --analyze --root "$ROOT" "$BUILD/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$BUILD/component.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$BUILD/component.plist"
pkgbuild --root "$ROOT" \
    --component-plist "$BUILD/component.plist" \
    --scripts Installer/scripts \
    --identifier com.macminimode.pkg \
    --version "$VERSION" \
    --install-location / \
    --ownership recommended \
    "$BUILD/MacMiniMode-component.pkg" >/dev/null

sed "s/@VERSION@/$VERSION/g" Installer/distribution.xml > "$BUILD/distribution.xml"
PRODUCT=(productbuild --distribution "$BUILD/distribution.xml" --resources Installer/Resources --package-path "$BUILD")
if [ -n "$PKG_IDENTITY" ]; then
    echo "    $PKG_IDENTITY"
    PRODUCT+=(--sign "$PKG_IDENTITY" --timestamp)
else
    echo "    未找到 Developer ID Installer 證書，安裝包未簽名"
fi
"${PRODUCT[@]}" "$PKG" >/dev/null

if [ -n "$PKG_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> 公證"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
fi

# README 的下載按鈕指向 releases/latest/download/MacMiniMode.pkg，發版時把這個不帶版本號的副本一起上傳。
cp "$PKG" "$BUILD/MacMiniMode.pkg"

echo "==> 完成：$PKG"
if [ -z "$PKG_IDENTITY" ]; then
    echo "    未簽名：只適合本機測試，別人下載後會被 Gatekeeper 攔截"
elif [ -z "$NOTARY_PROFILE" ]; then
    echo "    已簽名但未公證：設定 NOTARY_PROFILE 後重新構建"
else
    echo "    已簽名並公證，可以直接分發"
fi
