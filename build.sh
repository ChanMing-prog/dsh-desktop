#!/bin/bash
# 构建 DSH Desktop.app + DMG
# 默认 ad-hoc 签名；设置 DSH_SIGN_IDENTITY 后改用 Developer ID 签名，
# 设置 DSH_NOTARY_PROFILE 后自动公证并装订（stapler）。
# 例：
#   DSH_SIGN_IDENTITY="Developer ID Application: XX (TEAMID)" \
#   DSH_NOTARY_PROFILE="my-notary-profile" bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DSH Desktop"
APP_DIR="build/${APP_NAME}.app"
VERSION="0.5.1"
DMG="build/DSH-Desktop-${VERSION}.dmg"

echo "==> 清理并创建 App 骨架"
rm -rf "${APP_DIR}" build/stage
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

echo "==> 编译 Swift 源码（universal：arm64 + x86_64）"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "${arch}-apple-macos13.0" \
    -o "build/${APP_NAME}-${arch}" \
    DSHDesktop/main.swift \
    -framework Cocoa -framework WebKit
done
lipo -create "build/${APP_NAME}-arm64" "build/${APP_NAME}-x86_64" \
  -output "${APP_DIR}/Contents/MacOS/${APP_NAME}"
rm -f "build/${APP_NAME}-arm64" "build/${APP_NAME}-x86_64"

echo "==> 生成图标（PNG → iconset → icns）"
mkdir -p build
node scripts/make-icon.mjs build/icon-1024.png
ICONSET="build/icon.iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" build/icon-1024.png --out "${ICONSET}/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" build/icon-1024.png --out "${ICONSET}/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${APP_DIR}/Contents/Resources/icon.icns"

echo "==> 写入 Info.plist / PkgInfo / 内置安装脚本"
cp DSHDesktop/Info.plist "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"
if [ -n "${DSH_UPDATE_URL:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :DSHUpdateURL ${DSH_UPDATE_URL}" "${APP_DIR}/Contents/Info.plist"
  echo "    更新地址: ${DSH_UPDATE_URL}"
fi
cp scripts/install.command "${APP_DIR}/Contents/Resources/install.sh"
chmod +x "${APP_DIR}/Contents/Resources/install.sh"

xattr -cr "${APP_DIR}" 2>/dev/null || true
# macOS 26 的 provenance / iCloud File Provider 属性会阻断 codesign，定向清除
find "${APP_DIR}" \( -type f -o -type d \) \
  -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
find "${APP_DIR}" \( -type f -o -type d \) \
  -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find "${APP_DIR}" \( -type f -o -type d \) \
  -exec xattr -d com.apple.fileprovider.fpfs#P {} \; 2>/dev/null || true

# ---------- 签名 ----------
if [ -n "${DSH_SIGN_IDENTITY:-}" ]; then
  echo "==> Developer ID 签名（$DSH_SIGN_IDENTITY）"
  codesign --force --deep --options runtime --timestamp \
    --sign "$DSH_SIGN_IDENTITY" "${APP_DIR}"
  codesign --verify --deep --strict "${APP_DIR}"
else
  echo "==> Ad-hoc 签名（未设置 DSH_SIGN_IDENTITY）"
  codesign --force --deep -s - "${APP_DIR}"
fi

# ---------- 组装 DMG 内容：App + 安装说明（安装逻辑已内置 App，无需单独脚本）----------
echo "==> 组装 DMG 内容"
mkdir -p build/stage
cp -R "${APP_DIR}" build/stage/
cp 安装说明.txt build/stage/安装说明.txt

echo "==> 打包 DMG"
hdiutil create -volname "${APP_NAME}" -srcfolder build/stage -ov -format UDZO \
  "$DMG" >/dev/null

# ---------- 公证 ----------
if [ -n "${DSH_NOTARY_PROFILE:-}" ]; then
  echo "==> 提交公证（keychain profile: $DSH_NOTARY_PROFILE）"
  xcrun notarytool submit "$DMG" --keychain-profile "$DSH_NOTARY_PROFILE" --wait
  echo "==> 装订公证票据"
  xcrun stapler staple "$DMG"
  echo "==> 校验公证"
  xcrun stapler validate "$DMG"
fi

echo ""
echo "完成："
echo "  App: ${APP_DIR}"
echo "  DMG: ${DMG}"
