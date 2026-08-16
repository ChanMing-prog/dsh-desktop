#!/bin/bash
# 版本号一键更新：同步 build.sh 与 Info.plist（CFBundleShortVersionString + CFBundleVersion）
# 用法: bash scripts/bump-version.sh 0.5.0
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:?用法: bash scripts/bump-version.sh <新版本号，如 0.5.0>}"
echo "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "错误：版本号需为 x.y.z 格式"; exit 1; }

OLD=$(grep -o 'VERSION="[^"]*"' build.sh | head -1 | cut -d'"' -f2)
[ -n "$OLD" ] || { echo "错误：build.sh 中未找到 VERSION"; exit 1; }

# build.sh（DMG 文件名使用）
sed -i '' "s/VERSION=\"${OLD}\"/VERSION=\"${NEW}\"/" build.sh

# Info.plist：短版本号 + 构建号（构建号 = git 提交数 + 1，保证单调递增）
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW}" DSHDesktop/Info.plist
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" DSHDesktop/Info.plist

echo "版本已更新：${OLD} -> ${NEW}（CFBundleVersion: ${BUILD}）"
echo "下一步：bash scripts/release.sh ${NEW} \"更新说明\""
