#!/bin/bash
# 一键发布：bump 版本 → 构建（自动烙更新地址）→ 更新 version.json → 推送 → GitHub Release
#
# 用法：
#   bash scripts/release.sh 0.5.0 "更新说明"
#
# 前提：
#   1. gh CLI 已安装并登录（~/.local/bin/gh 或 PATH 中）
#   2. 当前目录是已推送的 GitHub 仓库（version.json 已在仓库根目录）
#   3. 可选：签名公证（DSH_SIGN_IDENTITY / DSH_NOTARY_PROFILE 环境变量会透传给 build.sh）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: bash scripts/release.sh <版本号> [更新说明]}"
NOTE="${2:-DSH Desktop v${VERSION}}"
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "错误：版本号需为 x.y.z 格式"; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v gh >/dev/null 2>&1 || { echo "错误：未安装 gh CLI（brew install gh 或装到 ~/.local/bin）"; exit 1; }

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
  || { echo "错误：当前目录不是 GitHub 仓库或未登录 gh"; exit 1; }
UPDATE_URL="https://raw.githubusercontent.com/${REPO}/main/version.json"

CUR=$(grep -o 'VERSION="[^"]*"' build.sh | head -1 | cut -d'"' -f2)
if [ "$CUR" != "$VERSION" ]; then
  echo "==> 更新版本号 ${CUR} -> ${VERSION}"
  bash scripts/bump-version.sh "$VERSION"
fi

echo "==> 构建（更新地址：${UPDATE_URL}）"
DSH_UPDATE_URL="$UPDATE_URL" bash build.sh

DMG="build/DSH-Desktop-${VERSION}.dmg"
[ -f "$DMG" ] || { echo "错误：构建产物缺失 ${DMG}"; exit 1; }

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
DMG_URL="https://github.com/${REPO}/releases/download/v${VERSION}/DSH-Desktop-${VERSION}.dmg"

echo "==> 更新 version.json"
printf '{"version":"%s","dmg":"%s","sha256":"%s","note":"%s"}\n' \
  "$VERSION" "$DMG_URL" "$SHA" "$NOTE" > version.json
cat version.json
echo

echo "==> 提交并推送（version.json / Info.plist / build.sh）"
git add version.json DSHDesktop/Info.plist build.sh
git commit -m "release v${VERSION}" || echo "（无变更，跳过提交）"
git push

echo "==> 创建 GitHub Release 并上传 DMG"
gh release create "v${VERSION}" "$DMG" \
  --title "DSH Desktop v${VERSION}" \
  --notes "$NOTE"

echo ""
echo "发布完成！"
echo "  下载页: https://github.com/${REPO}/releases/latest"
echo "  更新源: ${UPDATE_URL}"
