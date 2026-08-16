#!/bin/bash
# DSH Desktop 一键安装脚本
# 两种运行方式：
#   1. 用户双击（交互模式）：询问 API Key、拷贝 App、自动启动
#   2. App 内置触发（DSH_INSTALL_GUI=1）：全程静默无交互，
#      装完由 App 自己继续启动；App 位于磁盘镜像（/Volumes/）时自动拷贝到 ~/Applications
set -u
cd "$(dirname "$0")" 2>/dev/null || cd "$(dirname "$BASH_SOURCE")"

GUI_MODE=0
[ "${DSH_INSTALL_GUI:-0}" = "1" ] && GUI_MODE=1

log()  { echo "[DSH 安装] $*"; }
fail() {
  echo; echo "[DSH 安装] 错误：$*"
  if [ "$GUI_MODE" = "0" ]; then echo; echo "请按回车退出…"; read -r _; fi
  exit 1
}

LOCAL_ROOT="$HOME/.local"
LOCAL_BIN="$LOCAL_ROOT/bin"
APP_NAME="DSH Desktop.app"
SCRIPT_DIR="$(pwd)"

# ---------- 0. 系统检查 ----------
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "${OS_MAJOR:-0}" -lt 13 ]; then
  fail "需要 macOS 13 及以上（当前 $(sw_vers -productVersion)）"
fi

# ---------- 1. node ----------
export PATH="$LOCAL_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

NODE_BIN=""
if command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
  log "检测到 node：${NODE_BIN}（$(node --version)）"
fi

if [ -z "$NODE_BIN" ]; then
  log "未检测到 node，开始自动安装…"
  if command -v brew >/dev/null 2>&1; then
    log "使用 Homebrew 安装 node…"
    brew install node || fail "brew 安装 node 失败，请手动安装后重试"
  else
    log "无 Homebrew，下载官方 node 二进制包（免 sudo）…"
    ARCH="$(uname -m)"; [ "$ARCH" = "arm64" ] || ARCH="x64"
    LTS_VER=$(curl -fsSL --connect-timeout 15 https://nodejs.org/dist/index.json \
      | grep -o '"version":"v22\.[0-9.]*"' | head -1 | grep -o 'v22\.[0-9.]*')
    [ -z "$LTS_VER" ] && fail "获取 node 版本失败，请检查网络后重试"
    log "下载 node $LTS_VER ($ARCH)…"
    curl -fL --connect-timeout 20 -o /tmp/node-dsh.tar.gz \
      "https://nodejs.org/dist/$LTS_VER/node-$LTS_VER-darwin-$ARCH.tar.gz" \
      || fail "下载 node 失败，请检查网络后重试"
    mkdir -p "$LOCAL_ROOT" "$LOCAL_BIN"
    rm -rf "$LOCAL_ROOT/nodejs"
    tar -xzf /tmp/node-dsh.tar.gz -C "$LOCAL_ROOT"
    mv "$LOCAL_ROOT/node-$LTS_VER-darwin-$ARCH" "$LOCAL_ROOT/nodejs"
    ln -sf "$LOCAL_ROOT/nodejs/bin/node" "$LOCAL_BIN/node"
    ln -sf "$LOCAL_ROOT/nodejs/bin/npm"  "$LOCAL_BIN/npm"
    ln -sf "$LOCAL_ROOT/nodejs/bin/npx"  "$LOCAL_BIN/npx"
    rm -f /tmp/node-dsh.tar.gz
    # 让终端里以后也能直接敲 node/npm/dsh
    if ! grep -q '\.local/bin' "$HOME/.zprofile" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
    fi
    export PATH="$LOCAL_BIN:$PATH"
    log "node 已安装：$(node --version)"
  fi
  command -v node >/dev/null 2>&1 || fail "node 安装后仍不可用"
fi

# ---------- 2. dsh ----------
if npm ls -g --depth=0 @deepseek-ai/dsh >/dev/null 2>&1; then
  log "已安装 @deepseek-ai/dsh，跳过"
else
  log "安装 @deepseek-ai/dsh（约 300MB，首次需要几分钟，请耐心等待）…"
  npm install -g @deepseek-ai/dsh --no-fund --no-audit \
    || fail "dsh 安装失败。若网络较慢，可先执行：npm config set registry https://registry.npmmirror.com 后重试"
  log "dsh 安装完成"
fi
# tarball 安装的 node 其全局 bin 不在 PATH 里，补一个软链方便终端使用
if [ -x "$LOCAL_ROOT/nodejs/bin/dsh" ] && [ ! -e "$LOCAL_BIN/dsh" ]; then
  ln -sf "$LOCAL_ROOT/nodejs/bin/dsh" "$LOCAL_BIN/dsh"
fi
if [ -x "$LOCAL_ROOT/nodejs/bin/pnpm" ] && [ ! -e "$LOCAL_BIN/pnpm" ]; then
  ln -sf "$LOCAL_ROOT/nodejs/bin/pnpm" "$LOCAL_BIN/pnpm"
fi

# ---------- 2.5 跨架构原生模块（Apple Silicon 上为 Rosetta x86_64 补 x64）----------
# macOS 26 在 Apple Silicon 上存在 XNU JIT(mprotect) 内核 bug，用 x86_64(Rosetta) 运行
# 可规避。但 dsh 的 sharp/koffi/node-addon-require-builtin 三个原生模块，npm 只会装当前
# 架构（arm64），这里手动补 x64 版本，让两套架构并存。npm 更新 dsh 后会把 x64 清掉，
# 所以本函数做成幂等，可在更新后重跑（DSH_INSTALL_CROSS_ARCH_ONLY=1 可单独触发）。
install_cross_arch_native() {
  [ "$(uname -m)" = "arm64" ] || return 0

  local NPM_ROOT
  NPM_ROOT="$(npm root -g 2>/dev/null)"
  [ -n "$NPM_ROOT" ] || NPM_ROOT="$LOCAL_ROOT/lib/node_modules"

  local NM="$NPM_ROOT/@deepseek-ai/dsh/node_modules"
  [ -d "$NM" ] || return 0

  local OTHER_ARCH="x64"
  local SPECS
  SPECS="$(node - "$NM" "$OTHER_ARCH" <<'NODE'
const fs = require("fs"), path = require("path");
const nm = process.argv[2], other = process.argv[3];
const map = {
  "sharp": ["@img/sharp-darwin-" + other, "@img/sharp-libvips-darwin-" + other],
  "koffi": ["@koromix/koffi-darwin-" + other],
  "node-addon-require-builtin": ["node-addon-require-builtin-darwin-" + other],
};
const out = [];
for (const [main, pkgs] of Object.entries(map)) {
  let p;
  try { p = JSON.parse(fs.readFileSync(path.join(nm, main, "package.json"), "utf8")); } catch { continue; }
  for (const pkg of pkgs) {
    const v = p.optionalDependencies && p.optionalDependencies[pkg];
    if (v) out.push(pkg + "@" + v);
  }
}
console.log(out.join(" "));
NODE
)"
  [ -n "$SPECS" ] || return 0

  local spec pkg ver name url dest tmpdir
  for spec in $SPECS; do
    pkg="${spec%@*}"; ver="${spec##*@}"
    name="${pkg#*/}"
    url="https://registry.npmjs.org/${pkg}/-/${name}-${ver}.tgz"
    if [[ "$pkg" == @* ]]; then
      dest="$NM/${pkg%%/*}/${pkg##*/}"
    else
      dest="$NM/$pkg"
    fi
    [ -f "$dest/package.json" ] && continue
    log "补装跨架构原生模块：${pkg}@${ver}"
    tmpdir="$(mktemp -d)"
    if curl -fsSL --connect-timeout 20 -o "$tmpdir/pkg.tgz" "$url"; then
      mkdir -p "$dest"
      if tar -xzf "$tmpdir/pkg.tgz" -C "$dest" --strip-components=1; then
        log "  完成：${pkg}"
      else
        log "  ${pkg} 解压失败（x86_64 兼容模式下部分原生能力不可用，重跑安装脚本可修复）"
      fi
    else
      log "  ${pkg} 下载失败（x86_64 兼容模式下部分原生能力不可用，重跑安装脚本可修复）"
    fi
    rm -rf "$tmpdir"
  done
}


if [ "${DSH_INSTALL_CROSS_ARCH_ONLY:-0}" = "1" ]; then
  # 仅补装跨架构原生模块（App 更新 dsh 后重新补齐 x64 二进制）
  install_cross_arch_native
  exit 0
fi

# 常规安装路径：dsh 装完后补齐 x64 原生模块（幂等）
install_cross_arch_native

# ---------- 3. API 凭据（可选，可稍后在 App「设置 → 模型」里补填）----------
CRED_FILE="$HOME/.dsh/.credentials.yaml"
if [ -f "$CRED_FILE" ]; then
  log "已存在凭据配置（${CRED_FILE}），跳过"
else
  API_KEY="${DEEPSEEK_API_KEY:-}"
  if [ "$GUI_MODE" = "0" ] && [ -z "$API_KEY" ] && [ -t 0 ]; then
    printf "请输入 DeepSeek API Key（sk-…，在 platform.deepseek.com 获取；稍后可在 App「设置 → 模型」里填，直接回车跳过）："
    read -r API_KEY
  fi
  if [ -z "$API_KEY" ]; then
    log "已跳过 API Key 配置：稍后打开 DSH，在「设置 → 模型」中填写即可"
  else
    mkdir -p "$HOME/.dsh"
    printf 'DEEPSEEK_API_KEY: %s\n' "$API_KEY" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    log "凭据已写入 ${CRED_FILE}"
  fi
fi


# ---------- 4. 安装 App ----------
SKIP_LAUNCH=0
if [ "$GUI_MODE" = "1" ]; then
  # App 内触发：App 位置由 App 自行处理（自动复制到应用程序文件夹，含替换/保留两者提示）
  log "App 安装位置由 DSH Desktop 自动处理"
else
  if [ ! -d "$SCRIPT_DIR/$APP_NAME" ]; then
    fail "未找到 ${APP_NAME}（请保持安装脚本与 App 在同一个文件夹内运行）"
  fi
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  if [ -d "$DEST/$APP_NAME" ]; then
    EXISTING_VER=$(defaults read "$DEST/$APP_NAME/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "未知")
    NEW_VER=$(defaults read "$SCRIPT_DIR/$APP_NAME/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "未知")
    echo "「DSH Desktop」已存在：已安装 ${EXISTING_VER} / 安装包 ${NEW_VER}"
    echo "  [1] 替换   [2] 保留两者   [3] 取消"
    printf "请选择 [1/2/3]："
    read -r CHOICE
    case "$CHOICE" in
      2)
        I=2
        while [ -d "$DEST/DSH Desktop $I.app" ]; do I=$((I + 1)); done
        KEEP="$DEST/DSH Desktop $I.app"
        cp -R "$SCRIPT_DIR/$APP_NAME" "$KEEP/"
        xattr -dr com.apple.quarantine "$KEEP" 2>/dev/null
        log "已保留两者：$KEEP（原版本未动，本次不自动启动）"
        SKIP_LAUNCH=1
        ;;
      3)
        log "已取消安装"
        exit 0
        ;;
    esac
  fi
  if [ "$SKIP_LAUNCH" = "0" ]; then
    rm -rf "$DEST/$APP_NAME"
    cp -R "$SCRIPT_DIR/$APP_NAME" "$DEST/"
    xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null
    log "App 已安装到 $DEST/$APP_NAME"
  fi
fi

# ---------- 5. 启动 ----------
if [ "$GUI_MODE" = "1" ]; then
  log "安装完成（由 App 继续启动）"
elif [ "$SKIP_LAUNCH" = "0" ]; then
  log "安装完成，正在启动 DSH…"
  open "$DEST/$APP_NAME"
else
  log "安装完成"
fi
echo "[DSH 安装] 完成！"
exit 0
