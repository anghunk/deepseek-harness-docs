# 第 11 章 Agent 循环：turn/step 状态机

本章解剖 `packages/core/agent` 与 `packages/core/agent-loop`：Agent 接口如何声明、默认驱动如何实现、turn/step 状态机如何运转。

## 11.1 两个包的职责划分

| 包 | 职责 | ctx 键 |
| --- | --- | --- |
| `core/agent` | `Agent` 接口、实时注册表、initiator 作用域、`agent/*` 事件词汇 | `ctx.agents` |
| `core/agent-loop` | 默认驱动 `ReactLoopAgent`（唯一的 `Agent` 具体实现） | `ctx.agentLoop` |

关键设计：**扩展插件依赖 `agent`（含需要发起者 Agent 时），从不直接依赖 `agent-loop`**——循环保持可替换。`Agent` 的创建经 `ctx.agents.setFactory()` 注册的 `AgentFactory` 委托给循环（`docs/subsystems/core.md`）。

## 11.2 Agent 句柄

```ts
interface Agent {
  readonly id: SessionId
  readonly options: AgentOptions
  readonly session: Session        // 活会话；日志是持久事实源
  readonly inbox: Inbox            // 待办工作的持久投影
  readonly status: AgentStatus     // 'idle' | 'running'
  readonly ctx: Context            // agent 作用域 context（第 13 章 scope）
  cancel(cause: AgentCancelCause, options?: CancelOptions): void
  whenIdle(): Promise<void>
  runMaintenance<T>(task): Promise<T>
  send(message: UserMessage, target: InboxTarget, wakeup: boolean): void
  followup(message: UserMessage): void
  steer(message: UserMessage): void
  inject(message: UserMessage): void
}
```

### 输入通道：三种语义

`Agent` 的输入通道按"何时被模型看到"区分（`docs/subsystems/core.md`）：

- **`followup`**：普通后续 turn（next-turn 边界），入队并唤醒驱动；
- **`steer`**：转向（steering）——正在运行的驱动在**下一个 step 边界**消费；空闲驱动则开一个新 turn；
- **`inject`**：注入上下文——**不唤醒**驱动；运行中在最近的 step 边界被认领，空闲时留在 inbox 等后续唤醒。这就是第 1 章提到的"injected context waits in the inbox until another message does"。

底层统一走 `send(message, target, wakeup)`：`InboxTarget = 'next-turn' | 'next-step'`。

### Inbox：持久化的待办投影

Inbox 是两条有序待处理消息列表（next-turn / next-step），由持久事件 `agent/inbox/spliced` 重建。变更操作（append/prepend/replace/remove/clear/splice/claim）先落日志再改内存；`claim(target)` 按"全部 next-step 输入 + turn 边界时一条 next-turn 消息"取出提案批次。配套通知事件：`agent/inbox/inserted`、`agent/inbox/claimed`、`agent/inbox/discarded`。

### 取消

```ts
type AgentCancelCause =
  | { kind: 'user' } | { kind: 'parent' }
  | { kind: 'hook'; reason: string } | { kind: 'disposed' }
```

`cancel(cause, { keepInbox? })`：清空队列与转向工作（除非 `keepInbox`）并中止活动 turn。原因被拷贝进运行时 `AbortSignal.reason`（TS 强制的同进程输入；监听者无权自行分类）。持久 `turn/end` 只保留粗粒度 `{ kind: 'aborted' }`——**谁**请求的取消需要单独的事件，不重载终态。

## 11.3 ReactLoopAgent：驱动实现

`agent-loop/src/agent.ts`（约 1600 行）实现驱动。核心不变量（SA2 笔记）：

> 每个请求从 session 日志**纯函数重建**（`deriveMessages` + `requestHeader` 折叠），请求信封本身也写入日志（`request/header` 事件）——历史、信封、工具 schema 全部可重建。

### turn/step 循环

```text
turn/start
  claim next-step input + 一条 next-turn 消息
  assemble prompt sections + tool schemas
  → agent/pre-step (waterfall)         reject | enter(messages)
     step/start
     每条已进入消息 → user/message
     request/header + request/context（仅变化时）→ 日志
     agent/request (waterfall) → 冻结调用配置
     llm/stream (waterfall) → agent/assistant-stream start → chunk* → assistant/message/attempt → end
     tool/call* → 工具调度 → tool/result*
     step/end
     模型还欠请求或 next-step 有新输入 → claim → 下一个 step
  → agent/turn-stopping (serial)       欠尽时的串行检查点
turn/end
```

源码关键位置（`agent.ts`）：

- `turn()` 主体：`dispatch.serial('agent/turn-stopping', { turn, signal })`（`agent.ts:296`）在 while 循环内——监听者反对（返回 bail 值）→ 循环重读 inbox 再跑一步（`target='next-step'`）；
- `step()`：`agent/pre-step` waterfall 之后 `step/start`，追加 `user/message` 批次，组装请求，`agent/request` waterfall 冻结配置，`llm/stream` 取流，消费 chunk 发出 `agent/assistant-stream` 帧，收尾写入 `assistant/message`（成功，嵌入精确 stream 和 usage）或 `assistant/attempt`（失败/重试/取消/流错误，嵌入精确 stream），随后工具调度；
- 工具调度按 **model-ordered commit**：按模型返回顺序逐个 `tools/execute`，未执行的调用合成 `tool/result`（skipped 标记）。

### 三个 waterfall 的 next() 语义

| 事件 | next() 语义 |
| --- | --- |
| `agent/pre-step` | `next()` 返回 `PreStepDecision`（默认保留当前消息）；不调用 next 并返回 `{ kind: 'reject' }` / `{ kind: 'enter', messages }` 即接管 |
| `agent/request` | `await next()` 得到机器将用的配置（首次为 agent options，之后为已记录的 header）；返回替换即切换。**不能改消息**——模型可见内容必须走持久通道 |
| `agent/request-error` | 返回 `{ kind: 'retry' }` 且不调 next() 即接管恢复；next() 委派；默认 undefined 终局 |

> **文档勘误**：`docs/architecture.md:84` 的 waterfall 清单遗漏了 `agent/request-error`（`runtime-types.ts:260` 明确 `@mode waterfall`）。另外官方 `core.md` 称 `agent/request-error` 在 "step closes" 之后触发，源码实际次序为：`agent/assistant-stream chunk* → assistant/message/attempt → agent/request-error → step/end（finally）→ agent/error → turn/end`——即 request-error 在 step/end **之前**。若监听者返回 retry，step 根本不会关闭。

### agent/request-error 与重试

`LlmRuntime` 只把失败归一为 terminal finish，**不在 `llm/stream` 里执行重试**；重试完全由 `agent/request-error` + `dsh-llm-retry` 承担（`llm` README）。原因：一次带重复 chunk 的 wrapper 没有持久 attempt 边界，重试放在 step 关闭边界的瀑布里才能安全重建。`ResolvedRetryPolicy`（normal/always + backoff）由适配器注册时声明，`agent/request-error` 载荷携带它。

## 11.4 agent/* 事件全景

| 事件 | 模式 | 语义 |
| --- | --- | --- |
| `agent/created` | emit | 完整 agent + 活会话发布；同步 throw 否决发布 |
| `agent/disposed` | emit | 离开注册表（驱动静默 + 作用域回卷之后、会话分离之前） |
| `agent/error` | emit | step/turn 出错（即使错误无 turn 内位置也会上报） |
| `agent/status` | emit | 状态迁移（idle ↔ running） |
| `agent/session-start` | emit | 会话生命周期开始（startup/resume/clear/compact） |
| `agent/inbox/inserted` / `claimed` / `discarded` | emit | inbox 变更通知 |
| `agent/inbox/spliced` | emit | 持久变更记录（重建来源） |
| `agent/pre-step` | **waterfall** | 拒绝或改写进入 step 的消息 |
| `agent/request` | **waterfall** | 替换冻结调用配置 |
| `agent/request-error` | **waterfall** | 失败恢复（retry） |
| `agent/turn-stopping` | serial | turn 欠尽前的检查点（无 next） |

除 `agent/turn-stopping`（serial、无 next）外，其余决策点均为 waterfall。所有事件带 `Scoped<Agent>` 载体（按 agent 作用域过滤派发）。

## 11.5 创建与所有权

`ctx.agents.create(options)` / `resume(options)` 经注册的 factory 创建，返回 `AgentHandle { agent, dispose() }`——**disposer 是能力（capability）**：只有持有者能拆除该 agent。`dispose()` 顺序：停循环 → 等退出 → 注销 → 移除会话 → 回卷作用域世界。

创建选项 `CreateAgentOptions` 的关键字段：`meta`（cwd、fork 谱系、种子边界、来源分类、委托深度）、`seed`（fork 重放前缀）、`setup(agentCtx)`（**在 id 发布前**组合 agent 的作用域世界——注册到 `agentCtx` 的一切在 `agent/created` 与首次提示词组装前就绪）；setup 拒绝/commit 抛错/所有者卸载都会回滚事务。

`agent/created` 是"完整可用的 agent 已发布"的信号；`agent/session-start` 才是第一个启动驱动扩展点（setup 只是组合）。

## 11.6 发起者作用域（Initiator）

`ctx.agents.currentInitiator()` / `requireInitiator()` / `withInitiator(agent, op)` / `withoutInitiator(op)`：进程内的因果归属（谁发起了这次异步调用链）。语义边界明确：

> Ambient presence is neither liveness proof nor authorization.

"在场不等于存活，更不等于授权"。`withInitiator` 只做归属，不校验身份；`withoutInitiator` 用于延迟共享定时器、队列泵、监视器等不应继承"第一个碰巧初始化它们的人"的场景。循环每次驱动都在 `withInitiator(agent)` 内运行。

## 11.7 设计亮点（源码验证）

1. **请求可重建不变量**：header（配置 + 渲染系统提示词 + 组装工具 schema）全量入日志，`foldRequestHeader` 从日志重建——任何请求都是日志的纯函数；
2. **max-tokens 粘滞**：turn 内任一 step 触顶 → 整个 turn 记 `max-tokens`；
3. **融合调度器**：工具调用按 model order 逐个 commit，scope 失配的调用合成 skipped `tool/result`，日志永远闭合；
4. **取消收敛**：`AbortSignal.reason` 携带取消原因；取消后提交的唤醒输入排队到下一 turn（`agent-loop` 的 wake latch 修复，见 `.agents/notes/implemented/bug-fix/2026-08-07-cancel-convergence-wake-latch.md`）；
5. **whenIdle 的整个 agent 语义**：观察"整个 agent 达到静默"，而非某条消息的结算——调用者可自行定义"收据到静默"的运行区间。

## 11.8 小结

- `agent` 声明接口与事件；`agent-loop` 是唯一实现，扩展插件只依赖 `agent`；
- 输入三通道：followup（下一 turn）/ steer（最近 step 边界）/ inject（不唤醒，等下次唤醒）；
- turn/step 事件流完整可重建；三个决策 waterfall 的 next() 语义各异；
- `agent/request-error` 是官方 waterfall 清单的遗漏项，且触发于 step/end 之前；
- 创建事务（setup → 发布 → 启动）可整体回滚；disposer 即能力。

下一章：工具系统。
