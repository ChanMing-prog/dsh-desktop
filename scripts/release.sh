#!/bin/bash
# 发布脚本：上传 DMG 到 GitHub Release 并更新 version.json
#
# 用法：
#   bash scripts/release.sh 0.4.0 "更新说明"
#
# 前提：
#   1. 已安装 gh CLI 并登录（brew install gh && gh auth login）
#   2. 项目已推到 GitHub 仓库，仓库根目录已存在 version.json（可先用下面模板建）
#   3. 先按目标版本构建：VERSION 已在 build.sh 中改好，bash build.sh
#      （或 DSH_UPDATE_URL=... bash build.sh 一起注入更新地址）
#
# version.json 模板：
#   {"version":"0.4.0","dmg":"","sha256":"","note":""}
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: bash scripts/release.sh <版本号> [更新说明]}"
NOTE="${2:-DSH Desktop v${VERSION}}"
DMG="build/DSH-Desktop-${VERSION}.dmg"

[ -f "$DMG" ] || { echo "错误：找不到 $DMG，请先 bash build.sh（确认 VERSION=$VERSION）"; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "错误：未安装 gh CLI（brew install gh）"; exit 1; }

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
  || { echo "错误：当前目录不是 GitHub 仓库或未登录 gh"; exit 1; }

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
DMG_URL="https://github.com/${REPO}/releases/download/v${VERSION}/DSH-Desktop-${VERSION}.dmg"

echo "==> 更新 version.json"
printf '{"version":"%s","dmg":"%s","sha256":"%s","note":"%s"}\n' \
  "$VERSION" "$DMG_URL" "$SHA" "$NOTE" > version.json
cat version.json
echo

echo "==> 提交并推送 version.json"
git add version.json
git commit -m "release v${VERSION}" || echo "（无变更，跳过提交）"
git push

echo "==> 创建 GitHub Release 并上传 DMG"
gh release create "v${VERSION}" "$DMG" \
  --title "DSH Desktop v${VERSION}" \
  --notes "$NOTE"

echo ""
echo "发布完成！更新地址（填入 DSH_UPDATE_URL 重新构建分发版）："
echo "  https://raw.githubusercontent.com/${REPO}/main/version.json"
