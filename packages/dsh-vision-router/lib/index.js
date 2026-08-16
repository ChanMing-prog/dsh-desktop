// DSH vision router
//
// 会话中出现图片内容时，自动把模型请求路由到配置好的多模态 provider
// （llm-pi-ai 上名为 `visionProvider` 的路由），其余情况保持用户选择不变。
//
// 判定来源（两层）：
//   1. agent/pre-step 的实时消息（新附加的图片，立刻生效）
//   2. agent.session 事件日志扫描（惰性、每个 agent 一次）——
//      覆盖「会话恢复后历史图片仍在请求历史里」的场景
//
// 路由策略：
//   - 当前模型已声明 image 输入 → 不干预
//   - 已显式选择视觉路由 → 不干预
//   - 其余含图请求 → 切到视觉路由上第一个声明 image 输入的模型
import z from "@deepseek-ai/schemastery";
import { contentHasImage } from "@deepseek-ai/dsh-llm";

export const name = "vision-router";
export const Config = z.object({
  // llm-pi-ai 的多模态 provider 路由名
  visionProvider: z.string().default("vision")
});

// agent 循环实例 → 该会话是否含图（图片一旦进入历史就永不消失，只需置位）
const visionSessions = new WeakMap();
// 消息产生型会话事件
const SURFACE_EVENT_TYPES = new Set(["user/message", "assistant/message", "tool/result"]);

function messageHasImage(message) {
  return Array.isArray(message?.content) && contentHasImage(message.content);
}

function sessionHasVision(agent) {
  const cached = visionSessions.get(agent);
  if (cached !== undefined) return cached;
  let found = false;
  const events = agent?.session?.events;
  if (Array.isArray(events)) {
    for (const event of events) {
      if (!SURFACE_EVENT_TYPES.has(event?.type)) continue;
      if (messageHasImage(event.data)) {
        found = true;
        break;
      }
    }
  }
  visionSessions.set(agent, found);
  return found;
}

function markVision(agent) {
  visionSessions.set(agent, true);
}

export function apply(ctx, config) {
  ctx.on("agent/pre-step", async (payload, next) => {
    const decision = await next();
    const { agent } = payload;
    const candidates = [payload.messages, decision?.messages];
    for (const messages of candidates) {
      if (Array.isArray(messages) && messages.some(messageHasImage)) {
        markVision(agent);
        break;
      }
    }
    return decision;
  });

  ctx.on("agent/request", async (payload, next) => {
    const resolved = await next();
    const { agent, signal } = payload;
    if (!sessionHasVision(agent)) return resolved;

    const provider = resolved.provider ?? "";
    if (provider === config.visionProvider) return resolved;

    const llm = ctx.get("llm");
    if (llm === undefined) return resolved;

    // 当前模型支持图片就不干预
    try {
      const current = await llm.resolveModelInfo(provider, resolved.model, signal);
      if ((current.inputModalities ?? []).includes("image")) return resolved;
    } catch {
      // 未知路由/模型：继续尝试接管
    }

    // 视觉路由可用且含多模态模型 → 接管
    try {
      const models = await llm.listModels(config.visionProvider);
      const visionModel = models.find((model) => (model.inputModalities ?? []).includes("image"));
      if (visionModel === undefined) return resolved;
      // 视觉模型一般不接受文本模型的思考档位，剥离继承来的 reasoningEffort
      const { reasoningEffort: _inheritedEffort, ...withoutInheritedEffort } = resolved;
      ctx.logger.info("vision-router: routing to %s/%s", config.visionProvider, visionModel.id);
      return {
        ...withoutInheritedEffort,
        provider: config.visionProvider,
        model: visionModel.id
      };
    } catch (error) {
      ctx.logger.warn("vision-router: vision route unavailable: %s", String(error));
      return resolved;
    }
  });
}
