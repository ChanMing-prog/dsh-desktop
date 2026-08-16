// configure-vision.mjs — 为 llm-pi-ai 写入/更新视觉 provider 配置段
// 用法: node configure-vision.mjs [--base-url URL] [--model ID] [--name NAME]
//                                  [--context-window N] [--api-key KEY] [--route ROUTE]
// 通过 DSH_ROOT 环境变量定位 dsh 安装树里的 js-yaml（createRequire 锚定）
import { createRequire } from "node:module";
import { readFileSync, writeFileSync, mkdirSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const argv = process.argv.slice(2);
function arg(name, fallback) {
  const i = argv.indexOf(name);
  return i !== -1 && argv[i + 1] !== undefined ? argv[i + 1] : fallback;
}

const baseURL = arg("--base-url", "https://open.bigmodel.cn/api/paas/v4");
const modelId = arg("--model", "glm-4v-flash");
const modelName = arg("--name", "视觉识别模型");
const contextWindow = Number(arg("--context-window", "128000"));
const apiKey = arg("--api-key", "");
const route = arg("--route", "vision");
const credentialEnv = "VISION_API_KEY";

const dshRoot = process.env.DSH_ROOT;
if (!dshRoot) {
  console.error("缺少 DSH_ROOT 环境变量（dsh 安装目录）");
  process.exit(2);
}
const require = createRequire(join(dshRoot, "noop.js"));
const yaml = require("js-yaml");

const settingsPath = join(homedir(), ".dsh", "settings.yaml");
const credentialsPath = join(homedir(), ".dsh", ".credentials.yaml");

// ---------- settings.yaml ----------
let settings = {};
try {
  const loaded = yaml.load(readFileSync(settingsPath, "utf8"));
  if (loaded && typeof loaded === "object") settings = loaded;
} catch {
  // 文件缺失或损坏：从空开始（保守：损坏时不覆盖，直接报错退出）
  if (settings === undefined) {
    console.error("settings.yaml 解析失败，未做任何修改");
    process.exit(1);
  }
}

const ns = settings["llm-pi-ai"] ?? {};
const providers = ns.providers ?? {};
const profile = {
  displayName: "视觉识别",
  apiKeyEnv: credentialEnv,
  api: "openai-completions",
  baseURL,
  models: [
    {
      id: modelId,
      name: modelName,
      contextWindow,
      input: ["text", "image"]
    }
  ]
};
providers[route] = profile;
ns.providers = providers;
settings["llm-pi-ai"] = ns;

mkdirSync(join(homedir(), ".dsh"), { recursive: true });
writeFileSync(settingsPath, yaml.dump(settings, { lineWidth: 120 }), "utf8");
console.log(`[vision] settings.yaml 已更新：路由 ${route} → ${baseURL}（模型 ${modelId}）`);

// ---------- credentials.yaml ----------
if (apiKey) {
  let credentials = {};
  try {
    const loaded = yaml.load(readFileSync(credentialsPath, "utf8"));
    if (loaded && typeof loaded === "object") credentials = loaded;
  } catch {}
  credentials[credentialEnv] = apiKey;
  mkdirSync(join(homedir(), ".dsh"), { recursive: true });
  writeFileSync(credentialsPath, yaml.dump(credentials, { lineWidth: 120 }), "utf8");
  chmodSync(credentialsPath, 0o600);
  console.log(`[vision] 凭据已写入 ${credentialEnv}`);
} else {
  console.log("[vision] 未提供 API Key，稍后可在 DSH 设置 → 模型 中配置");
}
