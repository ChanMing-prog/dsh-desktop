# DSH Desktop

把 DeepSeek Harness Web GUI（`dsh web`，默认 127.0.0.1:3080）装进原生 macOS 桌面应用。

纯 Swift + WKWebView 实现，无 Electron、无第三方依赖，产物约 530KB（universal：Apple Silicon + Intel）。

仓库：https://github.com/ChanMing-prog/dsh-desktop
下载：https://github.com/ChanMing-prog/dsh-desktop/releases

## 工作原理

```
启动
 ├─ 探测 http://127.0.0.1:3080/（2.5s 超时）
 │   200 且含 window.__DSH_BOOT__ ──► 复用该服务（与终端会话同屏）
 │
 └─ 不健康 ──► spawn `node <dsh>/lib/bin.js --profile web --port 0`
               解析 stdout 的 `dsh web: http://127.0.0.1:<port>` 行
               └─► WKWebView 直连该端口
退出 ──► 只杀自己拉起的服务；复用的 3080 不动（SIGTERM → 3s → SIGKILL）
```

关键设计：

- **必须直连 `http://127.0.0.1:<port>`**：DSH 的 browser-trust 围栏要求
  `Origin.host === Host`，用 `file://` 或自定义协议会被拦截全部 API。
- **GUI 进程 PATH 不可靠**：Finder 启动的 App 只有系统 PATH，因此用绝对路径
  调 `node` 和 `bin.js`（自动探测 /opt/homebrew、/usr/local、nvm、volta、
  ~/.local 等常见前缀），并给子进程补全 PATH。
- 窗口菜单自带拷贝/粘贴/全选（WKWebView 必需），Cmd+R 重载；
  非本地链接、`window.open` 交给系统浏览器；下载自动存到 `~/Downloads`。
- 单实例：重复打开只会激活已有窗口。

## 环境变量

| 变量 | 作用 |
|---|---|
| `DSH_NODE_PATH` | node 绝对路径（默认自动探测） |
| `DSH_BIN_PATH` | dsh `bin.js` 绝对路径（默认按 node 前缀 + 常见全局目录探测） |
| `DSH_NODE_ARCH` | 自起 node 的架构（如 `x86_64`，经 `/usr/bin/arch` 启动；需先装 Rosetta） |
| `DSH_NODE_OPTIONS` | 追加给自起 node 的 Node.js 选项（如 `--jitless`） |
| `DSH_DESKTOP_PORT` | 探测端口（默认 3080） |
| `DSH_DESKTOP_SINGLE_INSTANCE=0` | 关闭单实例 |
| `DSH_DESKTOP_AUTO_QUIT_SECONDS` / `DSH_DESKTOP_HIDDEN` | 自动化测试钩子 |

## 构建

```bash
bash build.sh
# 注入自动更新地址（发布给别人的正式版）：
DSH_UPDATE_URL="https://raw.githubusercontent.com/<你>/<仓库>/main/version.json" bash build.sh
# 有 Developer ID 证书时再叠加签名公证：
DSH_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
DSH_NOTARY_PROFILE="my-notary-profile" bash build.sh
```

产物：`build/DSH Desktop.app`、`build/DSH-Desktop-<版本>.dmg`
（DMG 内含 App + 安装说明；App 内嵌安装脚本，双击 App 即自动安装：
复制到应用程序文件夹 + 首次运行缺少运行环境时自动静默安装）。

依赖：Xcode Command Line Tools（swiftc/sips/iconutil/codesign），macOS 13+。

## 分发（给别人装）

DMG 发给对方 → **双击 `DSH Desktop` 即可**：

- 首次打开自动安装运行环境（node + dsh，约 300MB），装完自动进入；
  被 Gatekeeper 拦时右键 → 打开（一次性）
- API Key 可在安装时跳过，装好后在 App「设置 → 模型」里补填

未公证的 DMG 首次打开需右键→打开；**签名+公证后零提示**。

## 自动更新

**App 本身**：启动后 5 秒后台请求 `DSHUpdateURL`（Info.plist，构建时注入）指向的
`version.json`，发现新版本弹提示框，一键下载新 DMG（SHA256 校验）。
对方双击新 DMG 里的 App 即完成升级（弹「替换/保留两者/取消」选择）。

**DeepSeek Harness 运行时（dsh）**：启动后 10 秒查询
`DSHRegistryURL`（默认 https://registry.npmjs.org/@deepseek-ai/dsh/latest），
发现新版弹提示框，一键执行 `npm install -g @deepseek-ai/dsh@latest`，
升级后自动重启 App 自起的服务（复用的外部服务下次启动生效）。
菜单栏「DSH → 检查 DeepSeek Harness 更新…」可手动检查。

`version.json` 格式：

```json
{"version":"0.4.0","dmg":"https://…/DSH-Desktop-0.4.0.dmg","sha256":"…","note":"更新说明"}
```

发布流程（需 GitHub 仓库 + gh CLI，一条命令全自动）：

```bash
# 版本号改齐（build.sh + Info.plist）、构建（自动烙更新地址）、
# 更新并推送 version.json、创建 GitHub Release 上传 DMG —— 全部自动完成
bash scripts/release.sh 0.5.0 "更新说明"

# 或分步执行：
bash scripts/bump-version.sh 0.5.0   # 只改版本号（build.sh + Info.plist）
DSH_UPDATE_URL="https://raw.githubusercontent.com/<你>/<仓库>/main/version.json" bash build.sh
```

## 已知限制

- **依赖对方机器能装 node + dsh**（dsh 安装约 333MB，由安装脚本代装，未打包进 App）。
- **API 凭据需要对方自己的 DeepSeek API Key**（安装时引导输入）。
- App 被强杀（SIGKILL）时自起服务可能残留为孤儿进程；正常退出不会。
- WKWebView 为 Safari 内核，个别 Web 特性可能与 Chrome 有差异。
- 项目不要放在 iCloud 同步目录（如 `~/Documents`）：File Provider 的
  `com.apple.fileprovider.fpfs#P` 属性会阻断 codesign，同步还可能导致文件丢失。
