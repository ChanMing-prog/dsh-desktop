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

# ---------- 2.5 视觉识别插件（dsh-vision：自定义端点识图）----------
install_vision_plugin() {
  PLUGIN_DIR="${1:-}"
  [ -n "$PLUGIN_DIR" ] && [ -f "$PLUGIN_DIR/package.json" ] || return 0
  command -v dsh >/dev/null 2>&1 || { log "未找到 dsh CLI，跳过视觉插件"; return 0; }
  if ! command -v pnpm >/dev/null 2>&1; then
    log "安装 pnpm（插件管理所需）…"
    npm install -g pnpm --no-fund --no-audit >/dev/null 2>&1 || { log "pnpm 安装失败，跳过视觉插件"; return 0; }
    export PATH="$LOCAL_BIN:$PATH"
  fi
  log "安装视觉识别插件…"
  if dsh plugin --profile web add "file:$PLUGIN_DIR" >/dev/null 2>&1; then
    log "视觉识别插件已安装（设置 → 插件 → 视觉识别 可配置自定义端点）"
  else
    log "视觉插件安装失败（不影响主功能，可稍后重装）"
  fi
}

# 写入自定义视觉端点配置（llm-deepseek 段 + 凭据），已配置过则跳过
write_vision_config() {
  local BASE_URL="$1" MODEL="$2" KEY="${3:-}"
  local SETTINGS="$HOME/.dsh/settings.yaml"
  mkdir -p "$HOME/.dsh"
  if grep -q "visionBackend:" "$SETTINGS" 2>/dev/null; then
    log "视觉识别已配置过，跳过配置写入"
  else
    if grep -q "^llm-deepseek:" "$SETTINGS" 2>/dev/null; then
      printf '  visionBackend: custom\n  visionBackendBaseURL: %s\n  visionBackendModel: %s\n' \
        "$BASE_URL" "$MODEL" >> "$SETTINGS"
    else
      printf '\nllm-deepseek:\n  visionBackend: custom\n  visionBackendBaseURL: %s\n  visionBackendModel: %s\n' \
        "$BASE_URL" "$MODEL" >> "$SETTINGS"
    fi
    if [ -n "$KEY" ]; then
      if [ -f "$HOME/.dsh/.credentials.yaml" ] && grep -q "DSH_VISION_CUSTOM_API_KEY" "$HOME/.dsh/.credentials.yaml" 2>/dev/null; then
        : # 已有 Key，保留
      else
        printf 'DSH_VISION_CUSTOM_API_KEY: %s\n' "$KEY" >> "$HOME/.dsh/.credentials.yaml"
        chmod 600 "$HOME/.dsh/.credentials.yaml"
      fi
    fi
    log "视觉识别已配置：$BASE_URL（$MODEL）"
  fi
}

if [ "${DSH_INSTALL_VISION_ONLY:-0}" = "1" ]; then
  # 仅补装视觉能力（App 启动自检：老版本升级后自动补装）
  PLUGIN_DIR_GLOBAL=""
  if [ -n "${DSH_APP_BUNDLE:-}" ] && [ -d "${DSH_APP_BUNDLE}/Contents/Resources/dsh-vision" ]; then
    PLUGIN_DIR_GLOBAL="${DSH_APP_BUNDLE}/Contents/Resources/dsh-vision"
  elif [ -d "$SCRIPT_DIR/$APP_NAME/Contents/Resources/dsh-vision" ]; then
    PLUGIN_DIR_GLOBAL="$SCRIPT_DIR/$APP_NAME/Contents/Resources/dsh-vision"
  fi
  install_vision_plugin "$PLUGIN_DIR_GLOBAL"
  exit 0
fi

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

# ---------- 3.5 视觉能力 ----------
# 定位 App 内嵌的视觉插件目录
if [ "$GUI_MODE" = "1" ] && [ -n "${DSH_APP_BUNDLE:-}" ]; then
  PLUGIN_DIR_GLOBAL="${DSH_APP_BUNDLE}/Contents/Resources/dsh-vision"
elif [ -d "$SCRIPT_DIR/$APP_NAME/Contents/Resources/dsh-vision" ]; then
  PLUGIN_DIR_GLOBAL="$SCRIPT_DIR/$APP_NAME/Contents/Resources/dsh-vision"
else
  PLUGIN_DIR_GLOBAL=""
fi
install_vision_plugin "$PLUGIN_DIR_GLOBAL"

# 交互模式：可选引导配置自定义视觉端点（OpenAI 兼容）
if [ "$GUI_MODE" = "0" ] && [ -t 0 ] && [ -f "$PLUGIN_DIR_GLOBAL/package.json" ]; then
  if ! grep -q "visionBackend:" "$HOME/.dsh/settings.yaml" 2>/dev/null; then
    printf "配置视觉识别模型？（直接回车跳过，之后可在 DSH 设置 → 插件 → 视觉识别 中配置）[y/N]："
    read -r VISION_YN
    if [ "$VISION_YN" = "y" ] || [ "$VISION_YN" = "Y" ]; then
      printf "接口地址 baseURL（OpenAI 兼容，如 https://token-plan-cn.xiaomimimo.com/v1）："
      read -r VISION_BASE_URL
      printf "模型 ID（如 mimo-v2.5 / glm-4v-flash / qwen-vl-plus）："
      read -r VISION_MODEL
      printf "视觉 API Key（可回车跳过，之后在设置中补）："
      read -r VISION_KEY
      if [ -n "$VISION_BASE_URL" ] && [ -n "$VISION_MODEL" ]; then
        write_vision_config "$VISION_BASE_URL" "$VISION_MODEL" "$VISION_KEY"
      else
        log "未填写完整，跳过视觉配置（之后可在设置中配置）"
      fi
    fi
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
