# 第 14 章 LLM 适配器接缝

`packages/llm/llm`（约 950 行主文件 + 类型/消息/组装器）是 provider 无关的 LLM 词汇表与适配器接缝，注册为 `ctx.llm`。它是循环、会话日志、所有插件之间的共同语言。

## 14.1 消息词汇（message.ts）

```ts
interface Message {
  id: MessageId                       // crypto.randomUUID() 铸造
  role: 'system' | 'user' | 'assistant'
  content: ContentBlock[]
  source: MessageSource               // 谁生产的、什么形态
}
```

三个角色特化：

- `UserMessage`（role: 'user'）：提示、注入上下文、目标续跑；
- `AssistantMessage`（role: 'assistant'）：source 必带 provider + model；
- `ToolResultMessage`（role: 'user'）：content 是单一 `tool-result` 块，source 携带 `callId`——与调用耦合。

`MessageSourceMap`（可声明合并扩展）：

```ts
type MessageSource =
  | { kind: 'user' }
  | { kind: 'plugin'; plugin: string; form?: ContextForm }
  | { kind: 'model'; provider: string; model: string; replayState?: ReplayEnvelope }
  | { kind: 'tool'; callId: CallId }
```

`replayState` 是新版引入的**类型化 `ReplayEnvelope`**（`types.ts`，两个半区对 harness 保持不透明，只有"拆分"本身是共享词汇）：

```ts
interface ReplayEnvelope {
  response: unknown                        // 响应级适配器私有元数据（id、原生 stop reason）
  blocks?: readonly unknown[]              // 逐块条目，与发射块序列按索引对齐（可选）
}
```

适配器私有回放状态不再是任意 blob——`ReplayEnvelope` 把"响应级元数据"与"逐块元数据"拆开，组装器才能在不读任何半区的情况下让**存储的元数据始终描述存储的内容**（见 14.2 的 max-tokens 剪枝）。

`source.kind` 回答"谁生产的"，`form` 回答"是什么类型"——两轴独立。`ContextForm`（`instructions/catalog/snapshot/notice/relay/recall`）区分注入上下文的语义形态（非视觉）。所有消息构造（`createMessage` 等）都会 **deep-freeze**。

## 14.2 流式词汇（types.ts + assembler.ts）

`StreamChunk` 是流式协议，判别联合：

```ts
type StreamChunk =
  | { type: 'block-start'; index: number; blockType: string; ... }
  | { type: 'text-delta' | 'reasoning-delta'; index; text }
  | { type: 'tool-call-delta'; index; name?; arguments? }   // 参数保持原始 JSON 字符串
  | { type: 'block-end'; index; block: ContentBlock }
  | { type: 'usage'; ... }
  | { type: 'finish'; finish: FinishReason; replayState?: ReplayEnvelope }  // 终局，之后什么都不发
```

成功的 `finish` 可以携带 `ReplayEnvelope`（失败/中止不携带）。`FinishReasonMap`（可扩展）：`stop | tool-calls | max-tokens | aborted{failure} | error{failure}`。`ContentBlockMap`（可扩展）：`text | reasoning | image | tool-call | tool-result`。

`BlockAssembler`（assembler.ts:36-164）把 chunk 流增量组装成消息：

- 容忍纯 delta 协议（无 block-start/end 也能组装）；
- **对已关闭块再来的 delta 忽略**——防恶意/损坏适配器膨胀流；
- max-tokens 截断时**丢弃无法安全执行的 tool-call 块**，且对内容与元数据只做**一次**保留/丢弃决定：丢弃某个块时，`ReplayEnvelope` 在相同位置同步剪掉对应条目，保留的块保有各自条目（被截断响应的 reasoning/text 签名仍在）；条目数与发射块数不匹配的 envelope 整体丢弃——发行不当的适配器不得发布归属错误的元数据；
- 未闭合且未知的 blockType 抛错；
- `finish` 缺省 `{ kind: 'stop' }`。

## 14.3 适配器接缝

### LlmAdapter：唯一必需方法

```ts
abstract class LlmAdapter {
  abstract stream(options: GenerateOptions): AsyncIterable<StreamChunk>
  // 可覆盖：providerInfo / providerRetryPolicy / listModels / async resolveModel
}
```

一个适配器 = 一个 provider 的流式实现。`GenerateOptions` 是一次完整请求的参数：provider、model、reasoningEffort、messages、system、tools、temperature、maxTokens、stop、signal、sessionId、purpose（`'compaction' | 'session-title'`——压缩与标题生成复用同一接缝）。

### 注册协议

`ctx.llm.registerAdapter(providers, adapter)`：

- **原子全或无**：多个 provider 一次性注册，重复注册抛 `DUPLICATE_ADAPTER`；
- 返回 `AdapterRegistrationHandle`：既是 disposer 又带 `replace(providers)`（换路由）；
- `commitRoutes` 以同步节切换路由，无观测空隙——HMR 重载适配器时请求不会"看到"半套路由。

### prepareCall：冻结一次调用

`prepareCall`（index.ts:779-814）一次 exact-model 查询同时解析 config + context + retryPolicy + adapterDefaults，**冻结**后返回 one-shot `stream`：

- 复用或修改 config 抛 `INVALID_PREPARED_CALL`；
- 把"header 日志"与"分发"绑定到**同一 adapter 注册**——防止 HMR 换适配器后日志 header 与分发器错配（README:37）。

### llm/stream：waterfall

```ts
// streamWithRegistration: ctx.waterfall(this, 'llm/stream', options, () => adapterStream(options, prepared))
```

`llm/stream` 是 waterfall：监听者可以包裹（改写选项、包装流）、替换（自己出流）、或否决。最内层 `next` 是 `adapterStream`——**终局边界**：

- 适配器选择/迭代器构造/迭代失败 → 统一转成单个 `finish{error|aborted, failure}`；
- middleware/嵌套调用/清理/下游消费者失败 → **保持抛异常**（不吞掉调用方的错误）。

`adapterFailureChunk` 根据 `signal.aborted` 或错误 code 选择 `aborted` 还是 `error` 终局。

**回放状态的读侧纪律**（`max-token` 对齐修复后）：持久化内容权威——`toPiAssistant` 等重建逻辑把回放状态当作**保真度元数据**而非承重输入。读取方无法使用的状态（其它适配器的 kind、其它版本（含已落盘的旧平铺 v1 形式）、格式错误、块结构不再匹配内容）把该消息**降级**为既有的提供方无关转换，经适配器 `onReplayDegrade` 钩子上报 `INVALID_REPLAY_STATE` 诊断后请求继续执行——而不是像旧版那样在历史重建时硬失败（那样会永久卡死已污染会话）。

### 事件

| 事件 | 模式 | 语义 |
| --- | --- | --- |
| `llm/stream` | waterfall | 模型流式调用（循环与所有调用方必经） |
| `llm/adapters-updated` | emit | 适配器拓扑变化通知 |

## 14.4 配置、错误与重试

- `LlmCallConfig`：provider/model/reasoningEffort/temperature/maxTokens/stop——与日志 `request/header` 绑定；`callConfigEquals` 做字段级实变化检测（决定是否写新 header）；
- `deepFreeze` 迭代防环、**跳过 AbortSignal**（防止冻结破坏取消机制）；
- `markAgentLoopRequest`：区分循环构建的请求与独立辅助调用；
- `LlmError` extends `HarnessError`：`code` 为稳定字符串（`NO_ADAPTER`/`DUPLICATE_ADAPTER`/`AUTH`/`RATE_LIMIT`…），`failure` 冻结序列化；
- `ResolvedRetryPolicy`（normal/always + backoff）：服务只**存储**策略，**不执行重试**——重试由 `agent/request-error` + `dsh-llm-retry` 承担（第 11 章）。

## 14.5 具体适配器

`packages/llm/` 下还有：

- `llm-deepseek`：DeepSeek 官方适配器（reasoning effort 支持 `off` / `low` / `high` / `max`，默认 `high`；`low` 为 `0.1.0-rc.7` 新增级别，仅 `low`/`high`/`max` 会带上官方协议强度值，`off` 映射为 `thinking: disabled`）；`0.1.1-rc.1` 起发布视觉模型目录，默认包含 V4 Flash / V4 Pro / V4 Flash Vision Exp（`inputModalities: ['text', 'image']`），支持多模态图像输入；
- `llm-pi-ai`：Pi AI 适配器；
- `llm-retry`：重试策略实现；
- `token-meter`：token 计量。

加一个 provider = 实现 `LlmAdapter` + `registerAdapter`（官方 cookbook：`docs/cookbook/adding-an-llm-adapter.md`）。



### 14.5.1 模型发现改进（0.1.2-rc.1）

`0.1.2-rc.1` 对模型发现机制进行了重要改进：

**协议特定的模型列表发现**：

- `fix(llm): scope Anthropic /v1 handling to model discovery` 将 Anthropic 的 `/v1` 路径处理限定在模型发现范围内；
- 不同 provider 的模型列表端点现在可以独立配置和发现；
- `test(llm): replay Anthropic's documented model-listing example` 添加了 Anthropic 模型列表的录制回放测试；
- `test(llm): archive recorded provider model listings` 归档了各 provider 的模型列表快照，便于回归测试。

**配置头复用**：

- `fix(llm): reuse profile headers for model discovery` 模型发现现在复用 profile 的请求头配置；
- `fix(llm): validate configured provider headers` 验证配置的 provider 头信息；
- 这确保了模型发现请求与正常 LLM 请求使用一致的身份验证和配置。

**发现名称回退**：

- `test(llm): expect discovery name fallback` 添加了发现名称回退的测试覆盖；
- 当模型发现返回的名称与预期不符时，系统会尝试回退到兼容的名称格式。

这些改进提高了模型发现的健壮性和可测试性，特别是对于 Anthropic 等非标准模型列表协议的 provider。

## 14.6 小结

- 消息词汇三件套：Message/ContentBlock/StreamChunk，全部可声明合并扩展、构造即冻结；
- 适配器唯一必需方法是 `stream()`；注册原子全或无、路由可热换；
- `prepareCall` 冻结调用并绑定 adapter 注册，防 HMR 错配；
- `llm/stream` 是 waterfall：可包裹/替换/否决；失败在终局边界归一为 finish；
- 重试不在接缝内，而在 `agent/request-error`。

下一章：能力接缝——执行与沙箱。