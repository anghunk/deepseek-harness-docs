# 第 12 章 工具系统与执行管道

`packages/core/tools`（约 5600 行）是 dsh 的工具中枢：**作用域工具注册表 + 受保护执行管道**。模型看到的每个工具（`read`、`bash`、`glob`、`grep`……）都注册在这里。

## 12.1 定位

`docs/subsystems/tools.md` 与 SA1 笔记的核心结论：

- 工具是**作用域化**的：注册进哪个 context，就只对那个作用域可见（全局工具 vs agent 预设工具）；
- 执行是**受保护**的：`tools/pre-execute` / `tools/execute` / `tools/post-execute` 三个 waterfall 让策略（权限、审批、沙箱包裹）可以拦截每次调用；
- 工具 schema 会**自动加入提示词组装**（经 `ctx.systemPrompt`）——注册一个工具 = 模型立刻可见（下个 step 起）；
- `packages/core/tools/src/types.ts` 向 session 的 `SessionEventMap` **声明合并**两个工具事件（`tool/call` 的配对事件，源码里唯一的反向类型注入），四包依赖链保持单向：`scope → system-prompt → session → tools`。

## 12.2 ToolDefinition：工具的"是什么"

```ts
interface ToolDefinition {
  schema: ToolSchema            // 模型可见的 JSON Schema
  execute: (input, context) => Promise<ToolExecutionResult>   // 业务执行
  // 可选：最终内容回调、UI 呈现回调（presentation）
}
```

`defineTool` DSL 提供类型化 schema 构造（`ValueSchemaSpec` / `ParameterSchemaSpec`），避免手写 JSON Schema；还支持 Python 类型映射（`py-types.ts`）——工具 schema 可以同时面向 TS 与 Python 消费方。

工具注册的核心在 `ToolRuntime`（SA1 行号证据）：`register`（注册工具）、`restrict`（作用域限制）、`guard`（守卫）、`schemas()`（组装给模型的 schema 列表）、`execute`（执行入口）。

## 12.3 执行管道：三个 waterfall

`docs/tool-execution-pipeline.md` 定义了完整管道。关键事件（`tools/*` 域）：

| 事件 | 模式 | 职责 |
| --- | --- | --- |
| `tools/pre-execute` | waterfall | 执行前策略：权限检查、审批、沙箱包裹、参数改写 |
| `tools/execute` | waterfall | 执行本身（默认调用 `definition.execute`） |
| `tools/post-execute` | waterfall | 执行后处理：结果改写、审计、工具私有 meta 呈现 |
| `tools/register` | emit | 工具注册通知 |

三个 waterfall 的 `next()` 语义一致：调用 `next()` 委派，不调用即接管（否决或替换）。审批系统的接入方式：`tools/pre-execute` 的监听者（审批插件）检查工具与参数，命中审批策略则挂起执行等待人工批准/拒绝（`docs/subsystems/approval.md`）。

### 执行身份的不可变性

工具执行上下文（`ToolExecutionContext`）是**不可变快照**：工具名、参数、调用者 agent、作用域……在分发时冻结。取消通过 `ABORTED` / `ABORTED_BEFORE_DISPATCH` 两态表达：尚未分发的调用直接标记 before-dispatch，已分发的在取消时置 ABORTED——日志里每个 `tool/call` 都有闭合的 `tool/result`。

## 12.4 与循环的衔接

第 11 章的调度器：模型返回 `tool/call*` → 循环按 model order 逐个 `tools/execute` → 每个调用写 `tool/call`（arguments 原样 JSON 字符串）与 `tool/result`（含 `meta`——工具私有、对核心不透明、必须 JSON 可序列化，`Session.append` 在源头校验）。

`tool/result` 的 `meta` 是设计亮点：工具可以在结果里附加呈现载荷（如 `dsh-tool-fs` 的结果时上下文 diff），核心不解析它，但持久化日志原样保留——重放时 UI 能还原完全相同的卡片。`presentResult` 是工具读取自己 meta 的入口。

## 12.5 工具呈现（presentation）

`core/agent-tool-presentation` 与 `packages/extensions` 下的 UI 包：工具的调用卡片（`tool.call.toolview` Slot，第 17 章）由工具的呈现回调 + 客户端渲染器共同决定。`ToolPresentation` 类型声明工具可提供的 UI 形态（文本、卡片、图表……）。

## 12.6 PTC mode：同一管道的复用

`packages/core/tools/src/ptc.ts`：**PTC mode（Process-Tool-Call mode，原 Code Mode）**（模型以代码而非工具调用表达操作的执行模式）复用同一条受保护管道——代码里的文件操作、命令执行仍然经过 fs/sandbox 策略与审批。这保证"无论模型用工具还是代码，安全边界一致"。PTC mode 通过 `run_code` 工具实现，支持 TypeScript 和 Python 两种 SDK 语言，每种语言有独立的 schema 描述和 SDK 指令。

`0.1.0-rc.7` 起，含图片的已结算子调用会经外层 `run_code` 结果**通用延后**：成功结算的子调用的最终 Native 内容若含图片，其完整有序内容被包装成带来源归属的用户消息、随外层结果进入模型上下文（下一次模型请求能看到持久图片），post-execute 替换/阻止仍然权威，纯文本结果不重复。分发桥接层从已结算的最终内容观察并转发，叶子工具无需感知父调用（第 15 章的附件接缝提供持久图片存储）。

## 12.7 工具注册的生命周期

工具注册本身是 fiber effect：插件卸载 → 工具自动消失 → `schemas()` 不再包含它 → 下个 step 模型不再看到它。"工具集随 preset 变化"由此自然实现：不同 agent 的 scope context 注册不同工具集，互不干扰（第 13、16 章）。

## 12.8 小结

- 工具 = schema + execute + 呈现；`defineTool` 类型化构造；
- 执行管道 = 三个 waterfall（pre/execute/post），策略在 pre 挂接，审批在其中；
- 工具注册即作用域化副作用；schema 自动进提示词组装；
- PTC mode（Process-Tool-Call mode）复用同一受保护管道；
- 执行身份不可变；取消两态闭合日志。

下一章：提示词组装与 scope 原语。
