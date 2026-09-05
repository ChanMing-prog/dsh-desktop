// DSH Desktop — 把 DeepSeek Harness Web GUI 装进原生 macOS 桌面应用。
//
// 启动策略（默认）：
//   1. 探测 127.0.0.1:3080，若根页面 200 且含 `window.__DSH_BOOT__` → 复用该服务（会话同终端）
//   2. 否则 spawn 一个自己的 `dsh --profile web --port 0`，从 stdout 的
//      `dsh web: http://127.0.0.1:<port>` 行解析出实际端口
//   3. WKWebView 直接加载 http://127.0.0.1:<port>/ —— 必须直连 HTTP，
//      否则 browser-trust 围栏（Origin.host === Host）会拦截所有 API
//   4. 退出时仅杀掉自己拉起的服务；复用的 3080 不动
//
// 环境变量：
//   DSH_NODE_PATH         node 可执行文件绝对路径（默认自动探测）
//   DSH_BIN_PATH          dsh bin.js 绝对路径（默认 ~/.local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js）
//   DSH_DESKTOP_PORT      探测端口（默认 3080；测试用）
//   DSH_DESKTOP_SINGLE_INSTANCE  设为 0 关闭单实例
//   DSH_DESKTOP_AUTO_QUIT_SECONDS  启动 N 秒后自动退出（自动化测试钩子）
//   DSH_DESKTOP_HIDDEN   设为 1 不显示窗口（自动化测试钩子）

import AppKit
import WebKit
import Darwin
import CryptoKit

// MARK: - 配置

let DEFAULT_PROBE_PORT: UInt16 = 3080
let DSH_MARKER = "__DSH_BOOT__"
let FALLBACK_BUNDLE_ID = "com.local.dsh-desktop"

func env(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name]
}

// MARK: - 小工具

func isLocalURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = url.host?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "localhost"
}

func isOpenableExternally(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https" || scheme == "mailto"
}

func uniqueDownloadURL(_ base: URL) -> URL {
    let fm = FileManager.default
    var url = base
    let ext = base.pathExtension
    let stem = base.deletingPathExtension().lastPathComponent
    let dir = base.deletingPathExtension().deletingLastPathComponent()
    var i = 2
    while fm.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(stem) \(i)")
        if !ext.isEmpty { url = url.appendingPathExtension(ext) }
        i += 1
    }
    return url
}

// MARK: - 清理历史残留的视觉插件（0.4.6 及更早版本的自动安装产物）

/// 0.4.6 及更早版本会在每次启动时自动把视觉插件装进 profile 的 `dependencies`（file: 链接
/// 指向 DMG 内的 Resources/dsh-vision）和 `dsh.profile.bundles`，并在 node_modules 创建
/// 对应目录。包名可能是 `@deepseek-ai/dsh-vision`、`@chanming-prog/dsh-vision` 或其它
/// 含 "dsh-vision" 的变体；0.4.7+ 已不再安装，但已污染的 profile 不会被自动清理。
///
/// 本函数在每次启动时做幂等清理：扫描 ~/.dsh/profiles 下所有 profile 的 package.json，
/// 用名称模式匹配（任何包含 "dsh-vision" 的依赖/bundle 名）移除相关条目，并删除
/// node_modules 里已安装的插件目录（含 pnpm 虚拟 store 的副本）。
/// 无残留时不做任何事，可安全地在每次启动时调用。
@discardableResult
func purgeLegacyVisionPlugins() -> Bool {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let profilesDir = "\(home)/.dsh/profiles"
    guard let profiles = try? fm.contentsOfDirectory(atPath: profilesDir) else { return false }
    var changed = false
    for profile in profiles {
        let dir = "\(profilesDir)/\(profile)"
        let pkgPath = "\(dir)/package.json"
        guard fm.fileExists(atPath: pkgPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: pkgPath)),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        var didModify = false

        // 1. 从 dsh.profile.bundles 移除含 dsh-vision 的包
        if var dsh = json["dsh"] as? [String: Any],
           var profileCfg = dsh["profile"] as? [String: Any],
           var bundles = profileCfg["bundles"] as? [String] {
            let before = bundles
            bundles.removeAll { $0.contains("dsh-vision") }
            if bundles.count != before.count {
                profileCfg["bundles"] = bundles
                dsh["profile"] = profileCfg
                json["dsh"] = dsh
                didModify = true
                NSLog("dsh-desktop: 已从 profile %@ bundles 移除：%@", profile,
                      before.filter { $0.contains("dsh-vision") }.joined(separator: ", "))
            }
        }

        // 2. 从 dependencies 移除含 dsh-vision 的包（旧版安装器写入的 file: 链接）
        if var deps = json["dependencies"] as? [String: Any] {
            let visionKeys = deps.keys.filter { $0.contains("dsh-vision") }
            if !visionKeys.isEmpty {
                for key in visionKeys { deps.removeValue(forKey: key) }
                if deps.isEmpty {
                    json.removeValue(forKey: "dependencies")
                } else {
                    json["dependencies"] = deps
                }
                didModify = true
                NSLog("dsh-desktop: 已从 profile %@ dependencies 移除：%@",
                      profile, visionKeys.joined(separator: ", "))
            }
        }

        if didModify {
            do {
                let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try out.write(to: URL(fileURLWithPath: pkgPath), options: .atomic)
                changed = true
            } catch {
                NSLog("dsh-desktop: 写回 profile %@ package.json 失败：%@", profile, error.localizedDescription)
            }
        }

        // 3. 删除 node_modules 里所有含 dsh-vision 的目录
        //    注意：只删除 vision 包子目录本身，不删除 scope 目录（避免误删同 scope 下其他包）
        let nmDir = "\(dir)/node_modules"
        // pnpm 虚拟 store：.pnpm 下的哈希目录
        let pnpmDir = "\(nmDir)/.pnpm"
        if let entries = try? fm.contentsOfDirectory(atPath: pnpmDir) {
            for entry in entries where entry.contains("dsh-vision") {
                let path = "\(pnpmDir)/\(entry)"
                try? fm.removeItem(atPath: path)
                NSLog("dsh-desktop: 已删除 %@", path)
            }
        }
        // node_modules 下的包：顶层条目 + @scoped 目录下的子目录
        if let nmEntries = try? fm.contentsOfDirectory(atPath: nmDir) {
            for entry in nmEntries where entry != ".pnpm" {
                let path = "\(nmDir)/\(entry)"
                if entry.contains("dsh-vision") {
                    // 顶层条目本身含 vision（如直接安装的 dsh-vision）
                    try? fm.removeItem(atPath: path)
                    NSLog("dsh-desktop: 已删除 %@", path)
                } else if entry.hasPrefix("@") {
                    // scope 目录：只删除含 vision 的子包，不删 scope 目录本身
                    if let scoped = try? fm.contentsOfDirectory(atPath: path) {
                        for sub in scoped where sub.contains("dsh-vision") {
                            let subPath = "\(path)/\(sub)"
                            try? fm.removeItem(atPath: subPath)
                            NSLog("dsh-desktop: 已删除 %@", subPath)
                        }
                    }
                }
            }
        }
    }
    return changed
}

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}

func htmlPage(title: String, body: String, spinner: Bool = false) -> String {
    let spin = spinner ? "<div class=\"spinner\"></div>" : ""
    return """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>\(title)</title>
    <style>body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;background:#f5f6f8;color:#333;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;margin:0;gap:14px}
    h1{font-size:20px;margin:0}p{font-size:14px;color:#666;max-width:600px;text-align:center;line-height:1.7;margin:0}
    .spinner{width:32px;height:32px;border:3px solid #d0d3d9;border-top-color:#4D6BFE;border-radius:50%;animation:spin 1s linear infinite}
    @keyframes spin{to{transform:rotate(360deg)}}</style></head>
    <body>\(spin)\(body)</body></html>
    """
}

// MARK: - 运行环境发现（GUI 进程 PATH 不可靠，必须解析绝对路径）

func findNodeExecutable() -> String? {
    let fm = FileManager.default
    if let v = env("DSH_NODE_PATH"), fm.isExecutableFile(atPath: v) { return v }
    let home = fm.homeDirectoryForCurrentUser.path
    var candidates = [
        "\(home)/.local/bin/node",
        "\(home)/.local/nodejs/bin/node",
        "\(home)/.volta/bin/node",
        "\(home)/.nvm/current/bin/node",
        "\(home)/.npm-global/bin/node",
        "\(home)/.asdf/shims/node",
        "\(home)/.local/share/mise/shims/node",
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
    ]
    let nvmRoot = "\(home)/.nvm/versions/node"
    if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
        candidates.insert(contentsOf: versions.sorted(by: >).map { "\(nvmRoot)/\($0)/bin/node" }, at: 0)
    }
    let voltaRoot = "\(home)/.volta/tools/image/node"
    if let versions = try? fm.contentsOfDirectory(atPath: voltaRoot) {
        candidates.insert(contentsOf: versions.sorted(by: >).map { "\(voltaRoot)/\($0)/bin/node" }, at: 0)
    }
    let fnmRoot = "\(home)/Library/Application Support/fnm/node-versions"
    if let versions = try? fm.contentsOfDirectory(atPath: fnmRoot) {
        candidates.insert(contentsOf: versions.sorted(by: >).map { "\(fnmRoot)/\($0)/installation/bin/node" }, at: 0)
    }
    for c in candidates where fm.isExecutableFile(atPath: c) { return c }
    // PATH 兜底：逐个目录找 node（覆盖任意自定义安装位置）
    for dir in (env("PATH") ?? "").split(separator: ":").map(String.init) where !dir.isEmpty {
        let p = "\(dir)/node"
        if fm.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

func findDshEntry(nodePath: String?) -> String? {
    let fm = FileManager.default
    if let v = env("DSH_BIN_PATH"), fm.fileExists(atPath: v) { return v }
    let home = fm.homeDirectoryForCurrentUser.path
    var candidates: [String] = []
    // 从 node 路径反推全局 prefix：<prefix>/bin/node → <prefix>/lib/node_modules/...
    // 覆盖 Homebrew(/opt/homebrew、/usr/local)、~/.local、nvm 各版本目录等所有常见布局
    if let nodePath = nodePath {
        let prefix = URL(fileURLWithPath: nodePath)
            .deletingLastPathComponent().deletingLastPathComponent().path
        candidates.append("\(prefix)/lib/node_modules/@deepseek-ai/dsh/lib/bin.js")
    }
    candidates += [
        "\(home)/.local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
        "\(home)/.local/nodejs/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
        "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
        "/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
        "\(home)/.npm-global/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
    ]
    let voltaRoot = "\(home)/.volta/tools/image/node"
    if let versions = try? fm.contentsOfDirectory(atPath: voltaRoot) {
        candidates.insert(contentsOf: versions.sorted(by: >).map { "\(voltaRoot)/\($0)/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" }, at: 0)
    }
    let fnmRoot = "\(home)/Library/Application Support/fnm/node-versions"
    if let versions = try? fm.contentsOfDirectory(atPath: fnmRoot) {
        candidates.insert(contentsOf: versions.sorted(by: >).map { "\(fnmRoot)/\($0)/installation/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" }, at: 0)
    }
    for c in candidates where fm.fileExists(atPath: c) { return c }
    return nil
}

// MARK: - 版本检查（自动更新提示）

struct RemoteRelease: Codable {
    var version: String
    var dmg: String?
    var sha256: String?
    var note: String?
}

/// 更新地址：环境变量 DSH_UPDATE_URL 优先，其次 Info.plist 的 DSHUpdateURL
func updateCheckURL() -> String? {
    if let v = env("DSH_UPDATE_URL"), !v.isEmpty { return v }
    if let v = Bundle.main.object(forInfoDictionaryKey: "DSHUpdateURL") as? String, !v.isEmpty { return v }
    return nil
}

func currentAppVersion() -> String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
}

/// 比较版本号（semver 风格：支持 "0.1.0-rc.6" 这类预发布版本；正式版 > 预发布版）
func compareVersion(_ a: String, _ b: String) -> ComparisonResult {
    func parse(_ s: String) -> (numbers: [Int], prerelease: String) {
        let parts = s.split(separator: "-", maxSplits: 1)
        let core = String(parts[0])
        let pre = parts.count > 1 ? String(parts[1]) : ""
        let nums = core.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        return (nums, pre)
    }
    let pa = parse(a)
    let pb = parse(b)
    let n = max(pa.numbers.count, pb.numbers.count)
    for i in 0..<n {
        let x = i < pa.numbers.count ? pa.numbers[i] : 0
        let y = i < pb.numbers.count ? pb.numbers[i] : 0
        if x != y { return x < y ? .orderedAscending : .orderedDescending }
    }
    if pa.prerelease.isEmpty && !pb.prerelease.isEmpty { return .orderedDescending }
    if !pa.prerelease.isEmpty && pb.prerelease.isEmpty { return .orderedAscending }
    if pa.prerelease == pb.prerelease { return .orderedSame }
    return pa.prerelease < pb.prerelease ? .orderedAscending : .orderedDescending
}

// MARK: - DeepSeek Harness（dsh 运行时）版本检查

/// dsh 版本数据源：环境变量 DSH_DSH_REGISTRY_URL 优先，其次 Info.plist，最后 npm registry
func dshRegistryURL() -> String? {
    if let v = env("DSH_DSH_REGISTRY_URL"), !v.isEmpty { return v }
    if let v = Bundle.main.object(forInfoDictionaryKey: "DSHRegistryURL") as? String, !v.isEmpty { return v }
    return "https://registry.npmjs.org/@deepseek-ai/dsh/latest"
}

/// 本机已装 dsh 版本：bin.js → <包目录>/package.json
func installedDshVersion(entry: String?) -> String? {
    guard let entry = entry else { return nil }
    let pkg = URL(fileURLWithPath: entry)
        .deletingLastPathComponent()   // lib
        .deletingLastPathComponent()   // <pkg>
        .appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: pkg),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = obj["version"] as? String else { return nil }
    return version
}

func sha256Hex(of url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - 探测已有 DSH 服务

func probeDsh(port: UInt16, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
    guard let url = URL(string: "http://127.0.0.1:\(port)/") else { completion(false); return }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    URLSession.shared.dataTask(with: request) { data, _, error in
        guard error == nil,
              let data = data,
              let text = String(data: data, encoding: .utf8),
              text.contains(DSH_MARKER) else {
            completion(false)
            return
        }
        completion(true)
    }.resume()
}

/// 端口是否可绑定：尝试 bind 一个 TCP socket。
/// dsh 绑定固定端口被占用时会直接崩溃（EADDRINUSE），不会回退，
/// 因此在决定是否用固定端口前必须先确认端口真的空闲。
func isPortBindable(_ port: UInt16) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    var on: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return bindResult == 0
}

// MARK: - 自起 DSH 服务管理

final class DshServer {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private(set) var url: URL?
    private var onURL: ((URL) -> Void)?
    private var onFail: ((String) -> Void)?

    init(nodePath: String, dshEntry: String, port: UInt16 = 0) {
        process.executableURL = URL(fileURLWithPath: nodePath)
        // --no-open：dsh web-app 的 openBrowser 默认是 true，会弹出系统浏览器；
        //            App 自己用 WKWebView 加载，不需要弹浏览器。
        // --port <n>：优先固定端口（默认可被调用方注入），端口被占用时由
        //             dsh 自动落到系统分配的随机端口；App 从 stdout 解析实际端口加载。
        process.arguments = [dshEntry, "--profile", "web", "--port", String(port), "--no-open"]
        process.standardOutput = outPipe
        process.standardError = errPipe

        // GUI 启动的进程 PATH 只有系统目录，补全常用路径，让 dsh 及其工具链能解析命令
        var processEnv = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:\(home)/.local/bin"
        processEnv["PATH"] = "\(extraPath):\(processEnv["PATH"] ?? "")"
        process.environment = processEnv

        // 工作目录放到 home，避免相对路径落到 "/"
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    }

    func start(onURL: @escaping (URL) -> Void, onFail: @escaping (String) -> Void) {
        self.onURL = onURL
        self.onFail = onFail

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self, self.url == nil else { return }
                self.onFail?("DSH 服务进程意外退出（exit code \(proc.terminationStatus)）")
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            // dsh web 新版会打印带启动 token 的完整 URL（?token=...），首次访问用它换签名 cookie。
            // 取到行尾（非空白）整串，避免只截端口而丢掉 token 导致 401。
            if let range = text.range(of: #"dsh web: http://\S+"#, options: .regularExpression),
               let url = URL(string: text[range].replacingOccurrences(of: "dsh web: ", with: "")) {
                DispatchQueue.main.async {
                    guard let self = self, self.url == nil else { return }
                    self.url = url
                    self.onURL?(url)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                NSLog("[dsh web] %@", text)
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onFail?("无法启动 DSH 服务：\(error.localizedDescription)")
            }
        }
    }

    /// SIGTERM → 等 3 秒 → SIGKILL 兜底
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    private var server: DshServer?
    private var serverIsExternal = false
    private var bootstrapAttempted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // 安装源自安装：在打开完整界面之前完成（安装器行为）。
        // 从 DMG/下载/桌面双击时，先弹安装对话框 → 安装 → 自动打开新副本并退出，
        // 不启动完整 DSH 页面。
        if performInstallIfNeeded() { return }

        buildMenu()
        createWindow()
        boot()

        // 启动 5 秒后后台检查更新（DSH_DESKTOP_UPDATE_CHECK=0 可关闭）
        if env("DSH_DESKTOP_UPDATE_CHECK") != "0" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.checkForUpdates(manual: false)
            }
            // 10 秒后检查 DeepSeek Harness（dsh 运行时）更新
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.checkDshUpdate(manual: false)
            }
        }

        // 自动化测试钩子：N 秒后走完整退出流程
        if let secs = env("DSH_DESKTOP_AUTO_QUIT_SECONDS"), let delay = Double(secs) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: 安装源自安装（打开完整界面之前执行）

    /// 从安装源（DMG 卷 / 下载 / 桌面）运行时，先完成安装再退出。
    /// 返回 true 表示安装流程已接管（正在安装或已安装完成，无需继续启动 UI）。
    /// 返回 false 表示无需安装（已安装副本 / 非安装源 / 用户取消 / 安装失败），调用方继续正常启动。
    func performInstallIfNeeded() -> Bool {
        // 开发/测试豁免：DSH_DESKTOP_NO_SELFCOPY=1 时不做任何自安装
        if env("DSH_DESKTOP_NO_SELFCOPY") == "1" { return false }

        let bundlePath = Bundle.main.bundlePath
        let appName = (bundlePath as NSString).lastPathComponent
        guard let destDir = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first else { return false }
        let dest = destDir.appendingPathComponent(appName)
        let fm = FileManager.default

        // 已在应用程序文件夹运行 → 无需安装
        if bundlePath == dest.path { return false }

        // 仅当从可识别的「安装源」位置运行才安装：
        //   磁盘镜像 /Volumes/、下载与桌面（用户把 App 拖出 DMG 后的常见位置）
        let isInstallSource = bundlePath.hasPrefix("/Volumes/")
            || bundlePath.contains("/Downloads/")
            || bundlePath.contains("/Desktop/")
        guard isInstallSource else { return false }
        NSLog("dsh-desktop: install-source launch (%@), running installer before UI", bundlePath)

        // 已存在同名 App → 替换 / 保留两者 / 取消
        var target = dest
        if fm.fileExists(atPath: dest.path) {
            let existingVersion = Bundle(path: dest.path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
            let incoming = currentAppVersion()
            let decision: String
            if let override = env("DSH_DESKTOP_SELFCOPY_CHOICE") {
                decision = override   // 测试钩子: 1=替换 2=保留两者 3=取消
            } else {
                let alert = NSAlert()
                alert.messageText = "「DSH Desktop」已存在"
                alert.informativeText = "已安装版本：\(existingVersion)\n安装包版本：\(incoming)\n\n要替换现有版本，还是保留两者？"
                alert.addButton(withTitle: "替换")
                alert.addButton(withTitle: "保留两者")
                alert.addButton(withTitle: "取消")
                switch alert.runModal() {
                case .alertFirstButtonReturn: decision = "1"
                case .alertSecondButtonReturn: decision = "2"
                default: decision = "3"
                }
            }
            switch decision {
            case "2":
                let stem = (appName as NSString).deletingPathExtension
                var i = 2
                while fm.fileExists(atPath: destDir.appendingPathComponent("\(stem) \(i).app").path) { i += 1 }
                target = destDir.appendingPathComponent("\(stem) \(i).app")
            case "3":
                NSLog("dsh-desktop: install cancelled by user, continuing normal launch from install source")
                return false
            default:
                break
            }
        }

        // 同步安装（安装器行为：先装完，再切换，不显示任何 App 界面）
        do {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(atPath: bundlePath, toPath: target.path)
            // 定向清除隔离属性与 provenance（注意：不能用 xattr -cr 清空全部属性，
            // 会破坏代码签名的密封资源校验，导致「已不能再打开」）
            let xattrProc = Process()
            xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProc.arguments = ["-dr", "com.apple.quarantine", target.path]
            try? xattrProc.run()
            xattrProc.waitUntilExit()
            let provProc = Process()
            provProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            provProc.arguments = ["-dr", "com.apple.provenance", target.path]
            try? provProc.run()
            provProc.waitUntilExit()
            // 刷新 LaunchServices 注册，避免旧签名缓存导致首次打开校验失败
            let lsreg = Process()
            lsreg.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
            lsreg.arguments = ["-f", target.path]
            try? lsreg.run()
            lsreg.waitUntilExit()
            NSLog("dsh-desktop: installed to %@", target.path)
        } catch {
            NSLog("dsh-desktop: install failed: %@", error.localizedDescription)
            return false
        }

        // 打开新副本并退出当前安装器实例
        NSLog("dsh-desktop: launching installed copy at %@", target.path)
        NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.terminate(nil)
        }
        return true
    }


    // MARK: 版本检查

    private var updateChecked = false

    @objc func checkForUpdatesAction() {
        checkForUpdates(manual: true)
    }

    func checkForUpdates(manual: Bool) {
        guard let urlStr = updateCheckURL(), let url = URL(string: urlStr) else {
            if manual { showUpdateAlert(title: "检查更新", message: "未配置更新地址。") }
            return
        }
        if updateChecked && !manual { return }
        updateChecked = true

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, error == nil, let data = data,
                  let release = try? JSONDecoder().decode(RemoteRelease.self, from: data),
                  !release.version.isEmpty else {
                if manual {
                    DispatchQueue.main.async {
                        self?.showUpdateAlert(title: "检查更新", message: "获取更新信息失败，请稍后重试。")
                    }
                }
                return
            }
            DispatchQueue.main.async {
                let current = currentAppVersion()
                if compareVersion(release.version, current) == .orderedDescending {
                    if !manual {
                        let defaults = UserDefaults.standard
                        if defaults.string(forKey: "lastUpdatePrompt") == release.version { return }
                        defaults.set(release.version, forKey: "lastUpdatePrompt")
                    }
                    NSLog("dsh-desktop: update available %@ (current %@)", release.version, current)
                    self.promptUpdate(release)
                } else if manual {
                    self.showUpdateAlert(title: "检查更新", message: "当前已是最新版本（\(current)）。")
                }
            }
        }.resume()
    }

    func promptUpdate(_ release: RemoteRelease) {
        // 测试钩子：静默模式只记日志，不弹窗不下载
        if env("DSH_DESKTOP_UPDATE_SILENT") == "1" {
            NSLog("dsh-desktop: [update-silent] would prompt v%@", release.version)
            return
        }
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.version)"
        alert.informativeText = release.note ?? ""
        alert.addButton(withTitle: "下载更新")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            downloadUpdate(release)
        }
    }

    func downloadUpdate(_ release: RemoteRelease) {
        guard let dmgStr = release.dmg, let url = URL(string: dmgStr) else {
            showUpdateAlert(title: "更新", message: "更新包地址无效。")
            return
        }
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            showUpdateAlert(title: "更新", message: "找不到下载文件夹。")
            return
        }
        let dest = uniqueDownloadURL(downloadsDir.appendingPathComponent("DSH-Desktop-\(release.version).dmg"))
        URLSession.shared.downloadTask(with: url) { [weak self] tmpURL, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard error == nil, let tmpURL = tmpURL else {
                    self.showUpdateAlert(title: "更新", message: "下载失败：\(error?.localizedDescription ?? "未知错误")")
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tmpURL, to: dest)
                    if let want = release.sha256, !want.isEmpty {
                        let got = sha256Hex(of: dest)
                        guard got == want.lowercased() else {
                            try? FileManager.default.removeItem(at: dest)
                            self.showUpdateAlert(title: "更新", message: "下载文件校验失败（SHA256 不匹配），请稍后重试。")
                            return
                        }
                    }
                    NSWorkspace.shared.open(dest)
                    self.showUpdateAlert(title: "更新",
                                         message: "已下载更新包并打开。\n在打开的窗口里双击「DSH Desktop」即可完成升级（会自动替换已装版本，已装组件跳过）。")
                } catch {
                    self.showUpdateAlert(title: "更新", message: "保存更新包失败：\(error.localizedDescription)")
                }
            }
        }.resume()
    }

    func showUpdateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: DeepSeek Harness（dsh）更新检查

    private var dshUpdateChecked = false

    @objc func checkDshUpdateAction() {
        checkDshUpdate(manual: true)
    }

    func checkDshUpdate(manual: Bool) {
        guard let urlStr = dshRegistryURL(), let url = URL(string: urlStr) else { return }
        if dshUpdateChecked && !manual { return }
        dshUpdateChecked = true

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, error == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = obj["version"] as? String, !latest.isEmpty else {
                if manual {
                    DispatchQueue.main.async {
                        self?.showUpdateAlert(title: "检查 Harness 更新", message: "获取版本信息失败，请稍后重试。")
                    }
                }
                return
            }
            DispatchQueue.main.async {
                guard let current = installedDshVersion(entry: findDshEntry(nodePath: findNodeExecutable())) else {
                    if manual {
                        self.showUpdateAlert(title: "检查 Harness 更新", message: "未检测到本机的 dsh 安装。")
                    }
                    return
                }
                if compareVersion(latest, current) == .orderedDescending {
                    if !manual {
                        let defaults = UserDefaults.standard
                        if defaults.string(forKey: "lastDshUpdatePrompt") == latest { return }
                        defaults.set(latest, forKey: "lastDshUpdatePrompt")
                    }
                    NSLog("dsh-desktop: dsh update available %@ (current %@)", latest, current)
                    self.promptDshUpdate(latest: latest, current: current)
                } else if manual {
                    self.showUpdateAlert(title: "检查 Harness 更新", message: "DeepSeek Harness 已是最新版本（\(current)）。")
                }
            }
        }.resume()
    }

    func promptDshUpdate(latest: String, current: String) {
        // 测试钩子：静默模式只记日志
        if env("DSH_DESKTOP_DSH_SILENT") == "1" {
            NSLog("dsh-desktop: [dsh-update-silent] would prompt %@ (current %@)", latest, current)
            return
        }
        let decision: String
        if let override = env("DSH_DESKTOP_DSH_CHOICE") {
            decision = override   // 测试钩子: 1=立即升级 2=稍后
        } else {
            let alert = NSAlert()
            alert.messageText = "DeepSeek Harness 有新版"
            alert.informativeText = "当前版本：\(current)\n最新版本：\(latest)\n\n源码仓库：github.com/deepseek-ai/deepseek-harness\n\n是否立即升级（约 300MB，视网络需要几分钟）？"
            alert.addButton(withTitle: "立即升级")
            alert.addButton(withTitle: "稍后")
            decision = alert.runModal() == .alertFirstButtonReturn ? "1" : "2"
        }
        if decision == "1" {
            runDshUpgrade(latest: latest)
        }
    }

    func runDshUpgrade(latest: String) {
        NSLog("dsh-desktop: upgrading dsh to %@ ...", latest)

        // npm 绝对路径：优先 node 同级目录，找不到再依赖 PATH
        var npmPath = "npm"
        if let node = findNodeExecutable() {
            let sibling = URL(fileURLWithPath: node).deletingLastPathComponent().appendingPathComponent("npm")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { npmPath = sibling.path }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: npmPath)
        task.arguments = ["install", "-g", "@deepseek-ai/dsh@latest", "--no-fund", "--no-audit"]
        var taskEnv = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:\(home)/.local/bin:\(home)/.local/nodejs/bin"
        taskEnv["PATH"] = "\(extraPath):\(taskEnv["PATH"] ?? "")"
        task.environment = taskEnv

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let lock = NSLock()
        var tail = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[dsh-upgrade] %@", text)
            lock.lock()
            tail += text
            if tail.count > 8192 { tail = String(tail.suffix(8192)) }
            lock.unlock()
        }
        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if proc.terminationStatus == 0 {
                    NSLog("dsh-desktop: dsh upgraded to %@", latest)
                    // 自己拉起的服务立即重启生效；复用的外部服务下次启动生效
                    if !self.serverIsExternal, self.server != nil {
                        self.server?.stop()
                        self.startOwnServer()
                        self.showUpdateAlert(title: "升级完成", message: "DeepSeek Harness 已升级到 \(latest)，服务已自动重启生效。")
                    } else {
                        self.showUpdateAlert(title: "升级完成", message: "DeepSeek Harness 已升级到 \(latest)。\n下次启动 DSH 时生效。")
                    }
                } else {
                    lock.lock()
                    let detail = String(tail.suffix(1200))
                    lock.unlock()
                    self.showUpdateAlert(title: "升级失败", message: "升级进程退出码 \(proc.terminationStatus)。\n可在终端手动执行 npm install -g @deepseek-ai/dsh@latest\n\n日志末尾：\n\(htmlEscape(detail))")
                }
            }
        }
        do {
            try task.run()
        } catch {
            showUpdateAlert(title: "升级失败", message: "无法启动 npm：\(error.localizedDescription)")
        }
    }

    func createWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "DSH"
        window.minSize = NSSize(width: 940, height: 620)
        window.setFrameAutosaveName("DSHMainWindow")
        window.isReleasedWhenClosed = false
        window.center()

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.addObserver(self, forKeyPath: "title", options: [.new], context: nil)
        window.contentView = webView

        showLoading()
        if env("DSH_DESKTOP_HIDDEN") != "1" {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: 启动流程

    func boot() {
        let probePortStr = env("DSH_DESKTOP_PORT") ?? String(DEFAULT_PROBE_PORT)
        let probePort = UInt16(probePortStr) ?? DEFAULT_PROBE_PORT

        probeDsh(port: probePort, timeout: 2.5) { [weak self] healthy in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if healthy {
                    self.serverIsExternal = true
                    NSLog("dsh-desktop: reusing existing server at http://127.0.0.1:%d", probePort)
                    if let url = URL(string: "http://127.0.0.1:\(probePort)/") {
                        self.load(url: url)
                    }
                } else {
                    self.startOwnServer()
                }
            }
        }
    }

    func startOwnServer() {
        guard let node = findNodeExecutable() else {
            if bootstrapAttempted {
                showFatal("找不到 node",
                          "本机未检测到 node 运行时。<br>请重新运行安装脚本安装 node，<br>或通过环境变量 DSH_NODE_PATH 指定 node 的绝对路径。")
            } else {
                bootstrapAttempted = true
                runBootstrapInstaller()
            }
            return
        }
        guard let entry = findDshEntry(nodePath: node) else {
            if bootstrapAttempted {
                showFatal("找不到 dsh",
                          "已找到 node：\(node)<br>但未找到 @deepseek-ai/dsh。<br>请在终端执行 <code>npm install -g @deepseek-ai/dsh</code> 后重试，<br>或通过环境变量 DSH_BIN_PATH 指定 bin.js 的绝对路径。")
            } else {
                bootstrapAttempted = true
                runBootstrapInstaller()
            }
            return
        }
        NSLog("dsh-desktop: spawning own server (node %@)", node)
        // 优先绑定固定端口（3080）：固定端口让每次启动的 URL 一致，
        // 终端 dsh web / App 也能复用同一服务。先确认端口空闲再绑定——
        // dsh 绑定被占用端口会直接崩溃（EADDRINUSE），不会回退随机端口。
        // 端口被占时回退到 --port 0（系统分配随机端口），App 从 stdout
        // 解析实际端口加载，行为不变。
        let port: UInt16 = isPortBindable(DEFAULT_PROBE_PORT) ? DEFAULT_PROBE_PORT : 0
        if port == DEFAULT_PROBE_PORT {
            NSLog("dsh-desktop: using fixed port %d", DEFAULT_PROBE_PORT)
        } else {
            NSLog("dsh-desktop: port %d unavailable, falling back to random port", DEFAULT_PROBE_PORT)
        }
        let server = DshServer(nodePath: node, dshEntry: entry, port: port)
        self.server = server
        server.start(
            onURL: { [weak self] url in
                NSLog("dsh-desktop: own server ready at %@", url.absoluteString)
                self?.load(url: url)
            },
            onFail: { [weak self] message in
                self?.showFatal("DSH 启动失败", message)
            }
        )
    }

    // MARK: 内置自动安装（首次运行缺少 node/dsh 时触发）

    func runBootstrapInstaller() {
        NSLog("dsh-desktop: runtime missing, starting bootstrap installer")
        webView.loadHTMLString(
            htmlPage(title: "DSH",
                     body: "<p>首次运行，正在自动安装运行环境…</p><p style=\"font-size:12px;color:#999\">需下载 node + dsh（约 300MB），视网络速度需要几分钟。<br>请保持网络连接，安装完成后将自动打开。</p>",
                     spinner: true),
            baseURL: nil)

        guard let scriptURL = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            showFatal("自动安装失败", "找不到内置安装脚本（Contents/Resources/install.sh）。")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]

        var taskEnv = ProcessInfo.processInfo.environment
        taskEnv["DSH_INSTALL_GUI"] = "1"
        taskEnv["DSH_APP_BUNDLE"] = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:\(home)/.local/bin"
        taskEnv["PATH"] = "\(extraPath):\(taskEnv["PATH"] ?? "")"
        task.environment = taskEnv

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let lock = NSLock()
        var tail = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[dsh-install] %@", text)
            lock.lock()
            tail += text
            if tail.count > 8192 { tail = String(tail.suffix(8192)) }
            lock.unlock()
        }
        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if proc.terminationStatus == 0 {
                    self.startOwnServer() // 重试；bootstrapAttempted 已置位，再失败会显示具体原因
                } else {
                    lock.lock()
                    let detail = String(tail.suffix(1200))
                    lock.unlock()
                    self.showFatal("自动安装失败",
                                   "安装脚本退出码 \(proc.terminationStatus)。<br>可双击安装包内的「安装.command」手动安装，或检查网络后重试。<br><br><details><summary>安装日志（末尾）</summary><pre>\(htmlEscape(detail))</pre></details>")
                }
            }
        }
        do {
            try task.run()
        } catch {
            showFatal("自动安装失败", "无法启动安装脚本：\(error.localizedDescription)")
        }
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    @objc func reload() {
        if let url = webView.url, isLocalURL(url) {
            webView.reload()
        }
    }

    func showLoading() {
        webView.loadHTMLString(
            htmlPage(title: "DSH", body: "<p>正在启动 DSH 服务，请稍候…</p>", spinner: true),
            baseURL: nil)
    }

    func showFatal(_ title: String, _ message: String) {
        NSLog("dsh-desktop: %@ — %@", title, message)
        webView.loadHTMLString(htmlPage(title: title, body: "<h1>\(title)</h1><p>\(message)</p>"), baseURL: nil)
    }

    // MARK: 菜单

    func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DSH", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let checkUpdateItem = NSMenuItem(title: "检查更新…", action: #selector(AppDelegate.checkForUpdatesAction), keyEquivalent: "")
        checkUpdateItem.target = self
        appMenu.addItem(checkUpdateItem)
        let checkDshItem = NSMenuItem(title: "检查 DeepSeek Harness 更新…", action: #selector(AppDelegate.checkDshUpdateAction), keyEquivalent: "")
        checkDshItem.target = self
        appMenu.addItem(checkDshItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 DSH", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DSH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        let reloadItem = NSMenuItem(title: "重新加载", action: #selector(AppDelegate.reload), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        viewMenuItem.submenu = viewMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: NSApplicationDelegate

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // 只清理自己拉起的服务；复用的外部服务（如终端里跑的 3080）不动
        if !serverIsExternal {
            server?.stop()
        }
    }

    // MARK: KVO —— 窗口标题跟随页面标题

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "title" {
            let title = (change?[.newKey] as? String) ?? ""
            window.title = title.isEmpty ? "DSH" : title
        }
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate / WKDownloadDelegate

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if !isLocalURL(url) {
            // 非本地导航一律转到系统浏览器（about: 之类的内部地址直接吞掉）
            if isOpenableExternally(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        NSLog("dsh-desktop: navigation failed: %@", error.localizedDescription)
    }
}

extension AppDelegate: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open 一律交给系统浏览器
        if let url = navigationAction.request.url, isOpenableExternally(url) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

extension AppDelegate: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = uniqueDownloadURL(downloadsDir.appendingPathComponent(suggestedFilename))
        NSLog("dsh-desktop: saving download to %@", destination.path)
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSLog("dsh-desktop: download finished")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("dsh-desktop: download failed: %@", error.localizedDescription)
    }
}

// MARK: - 入口

// 清理 0.4.6 及更早版本自动安装的视觉插件残留（幂等，无残留时无副作用）。
// 放在单实例检查之前：即使新副本因「已有旧版在运行」而立即退出，
// 残留也已被清理，下次启动不会再加载视觉插件。
purgeLegacyVisionPlugins()

// 单实例：已有实例则激活它并退出。
// 例外：从安装源（DMG 卷 / 下载 / 桌面）运行的实例不退出——
// 需要保留进程完成「自动安装到应用程序文件夹」，完成后它会自动切换到新副本。
let bundleID = Bundle.main.bundleIdentifier ?? FALLBACK_BUNDLE_ID
if env("DSH_DESKTOP_SINGLE_INSTANCE") != "0" {
    let bundlePath = Bundle.main.bundlePath
    let isInstallSource = bundlePath.hasPrefix("/Volumes/")
        || bundlePath.contains("/Downloads/")
        || bundlePath.contains("/Desktop/")
    if !isInstallSource {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        if let existing = others.first {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            exit(0)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
