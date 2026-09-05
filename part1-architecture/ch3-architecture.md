# 第 3 章 总体架构

本章是全书的总纲。我们回答三个问题：**为什么"一切皆插件"能成立**、**一个运行的 dsh 是什么**、以及 **能力如何被组织成可替换的接缝**。

## 3.1 一切皆插件：Cordis 的承诺

dsh 的架构承诺（`docs/architecture.md`）：

> There is no privileged core to patch: you extend dsh by mounting a plugin beside the others, and registrations are effects that unwind when their plugin unloads.

翻译过来：**不存在需要打补丁的特权核心**。要扩展 dsh，只需在旁边挂载一枚插件；所有注册（服务、事件、工具、提示词分节……）都是"可逆副作用"，插件卸载时自动回卷。

这个承诺由 Cordis 的四个机制支撑（详见第二部分）：

1. **Context 即服务仓库**：插件通过 `ctx.<key>` 找到服务（`ctx.tools`、`ctx.llm`、`ctx.sessions`…），而不是 import 具体实现；
2. **inject 声明依赖**：插件声明需要的服务，Cordis 让它在依赖就绪后才启动——**装载顺序由依赖关系表达，而不是手工编排**；
3. **类型化事件**：服务通过声明合并定义事件，以 `emit` / `waterfall` / `parallel` / `serial` 派发，实现观察、包裹、扇出、串行等语义；
4. **可逆副作用**：一切注册都挂在 `ctx.effect()` 上，卸载插件时按注册逆序自动清理。

## 3.2 一个运行的 dsh：Profile 与 Bundle

一个运行的 dsh 是**从空根配置开始、按顺序叠加 patch 层而组合出的插件树**。

```mermaid
flowchart TD
    A[空根配置 cordis.yml = []] --> B[bundle 1 patch 层]
    B --> C[bundle 2 patch 层]
    C --> D[... 更多 bundle]
    D --> E[profile 的 cordis.patch.yml]
    E --> F[用户级 $DSH_HOME/cordis.patch.yml]
    F --> G[--patch 覆盖层 / 遥测开关]
    G --> H[最终插件树]
```

分层语义（`apps/cli/src/profile-boot.ts`）：

- **Profile（配置档）**：存放在 Harness 主目录（默认 `~/.dsh`）下的命名组合。`dsh.profile` 清单字段列出它堆叠的 bundles、持有的外部插件与用户自己的 `cordis.patch.yml`。`web` 与 `headless` 是随附模板；
- **Bundle（捆绑包）**：Cordis 配置行 + 它们装载的代码的分发格式，让上层任何 patch 都能覆盖它插入的行。每个 bundle 在自己的 `package.json` 的 `dsh.bundle` 字段声明 patch 文件；
- **三层内置 bundle**：
  - `dsh-base`：每个 profile 的第一层——模型适配器、工具、持久化、沙箱与审批策略、设置、凭据、遥测；
  - `dsh-web-app`：在 base 之上增加浏览器应用；
  - `dsh-headless`：无服务器的一次性运行器。

**Patch 目标按 id 寻址**：要么整行替换某条配置，要么 `insert` 新行。想看机器实际启动的树：

```sh
dsh --profile web --dump-config
```

打印出的任何一行，都可以用你自己的 patch 替换。这条命令的实现（`renderConfigDump`，`packages/boot/app-boot/src/index.ts:379`）会逐层重放 patch 算法，并在输出中标注每行的来源文件与被哪些层 patch 过。

## 3.3 双平面：Host 与 Client

dsh 的运行时横跨两个平面，**各有一棵独立的 Cordis 插件树**：

| | Host | Client |
| --- | --- | --- |
| 运行位置 | Node.js 进程 | 浏览器页面 |
| 能力 | 文件、命令、进程、网络、Agent/Session、工具注册 | 页面主题、布局、当前页状态、工具卡片 |
| 通信 | — | `host.call(method, args)` 包私有 JSON RPC（Client→Host） |

Host 侧还有 `api-remotes`：通过 `@Remote` 注解把 Host 服务方法暴露给 Client，构建期由 Typert 生成两侧契约与运行时装配（`docs/api-gateway.md`）。浏览器通过 WebSocket 之类的连接通道与 Host 保持同步（详见第 17 章）。

## 3.4 核心包与 ctx 键

`docs/architecture.md` 给出核心包的职责矩阵：

| 包 | 拥有什么 | ctx 键 |
| --- | --- | --- |
| `core/session` | append-only `SessionEvent` 日志与内存存储 | `ctx.sessions` |
| `core/system-prompt` | 提示词分节与工具 schema 组装 | `ctx.systemPrompt` |
| `core/tools` | 作用域工具注册表与受保护执行管道 | `ctx.tools` |
| `core/agent` | `Agent` 接口、实时注册表、`agent/*` 事件 | `ctx.agents` |
| `core/agent-loop` | 实现该接口的默认驱动 | `ctx.agentLoop` |
| `core/scope` | 每代理作用域注册原语 | 库，无键 |
| `llm/llm` | 消息与流式词汇 + 适配器接缝 | `ctx.llm` |

## 3.5 事件：三个领域

事件是 dsh 的扩展点。`docs/architecture.md` 把事件分为三个领域，选对领域是多数改动里的第一个决策：

1. **会话事件（durable facts）**：追加进日志并通过 `session/event` 广播。当"事实必须跨重载存活"时使用。例如 `turn/start`、`user/message`、`assistant/message`、`tool/result`；
2. **Agent 事件（live）**：`agent/*`，携带活的 `Agent`：inbox、step、status、request、validation、continuation。用于观察或拦截在途工作；
3. **能力事件（seam）**：把策略与适配器挂到接缝上（`fs/*`、`tools/*`、`telemetry/*`），不 import 循环。

**关键原则——"模型可见即已记录"（model-visible means logged）**：任何进入模型请求的内容必须能从日志重建，运行时不变式强制这一点。因此，新的模型可见输入必须新增会话事件类型（扩展 `SessionEventMap` 并从日志渲染），而不是临时拼接。

## 3.6 Turn 流程一瞥

**step** = 一次模型请求 + 它调用的工具；**turn** = 零或多个 step（打开于首个输入被认领之前，关闭于"无所亏欠"之时）：

```text
turn/start
  claim next-step input plus one queued message
  assemble prompt sections + tool schemas
  -> agent/pre-step                   reject | enter(messages)
     step/start
     append entered messages as user/message
     derive model history from the log
     agent/request -> llm/stream -> agent/assistant-stream start -> chunk* -> assistant/message/attempt -> end
     tool/call* -> tools/pre-execute -> tools/execute -> tools/post-execute -> tool/result*
     step/end
  -> agent/turn-stopping
turn/end
```

其中 `turn/*`、`step/*`、`user/message`、`assistant/*`、`tool/*` 是持久会话事件；其余是三个领域的实时扩展点。`agent/pre-step`、`agent/request`、`llm/stream` 与三个 `tools/*` 事件是 **waterfall**（监听者必须调用 `next()` 委派），`agent/turn-stopping` 是串行且没有 `next()`。第 11 章将逐行追踪这段流程的实现。

## 3.7 能力接缝：三件套模式

**接缝（seam）**是可替换能力的组织方式，包含三个角色：

1. **Service Definition**：声明接口；
2. **Service Provider**：实现它；
3. **Consumer**：消费它，通常是模型可见的工具。

一个包可以身兼多角，但**一个角色构不成接缝**——新增能力意味着设计全部三个角色（`docs/capability-seams.md`）。

接缝是"一次替换 Provider 改变整个产品"的原因：文件系统与子进程 Provider 共享同一个执行世界，把二者指向远程沙箱，Bash、PTY、LSP 就跟着一起迁移，无需为每个消费者分叉实现。子代理 Provider 同样多变——从全新子 agent 到委托给另一个产品的 turn（第 16 章展开）。

## 3.8 新行为放哪里：官方决策表

`docs/architecture.md` 的"Where new behavior goes"是扩展 dsh 的第一索引，摘录核心条目：

| 目标 | 机制 |
| --- | --- |
| 添加模型提供商 | 在 `ctx.llm` 注册适配器 |
| 添加模型可见能力 | 注册到 `ctx.tools`；其 schema 加入提示词组装 |
| 给某个会话不同的能力集 | 组合一个 agent preset；那里的服务行需要 `isolate` realm |
| 添加 shell 执行 | 注册 `ctx.shell` 后端；本地实现经 `ctx.subprocess` 派生进程 |
| 添加人类命令 | 注册到 `ctx.commands`，不经模型 turn 直接派发 |
| 添加后台工作 | 注册到 `ctx.jobs`；`job_*` 工具收集/停止它们 |
| 拦截请求/工具/turn | 使用其 `agent/*` 或 `tools/*` 事件 |
| 添加模型可见上下文 | 调用 `agent.inject()`，落在下一次被接纳的请求里 |
| 添加 UI / 编辑器集成 | 驱动 `ctx.agents`，从 `session/event` 渲染 |
| 添加持久会话状态 | 扩展 `SessionEventMap`，从日志渲染与重放 |
| 分叉活会话 | `ctx.sessions.fork(source, boundary?, childSessionId?)` |
| 把注册作用域限制到一个 agent | 使用该 agent 的 `agent.ctx` |

## 3.9 小结

- dsh = 空根 + 分层 patch 组合出的插件树（Profile/Bundle）；
- 两个平面（Host/Client）各有一棵 Cordis 树，通过 RPC 通信；
- 核心能力以 `ctx` 服务 + 三领域事件呈现；
- 可替换能力以"定义/提供者/消费者"三件套组织；
- "模型可见即已记录"是会话层的不变式。

接下来的第二部分，我们从 vendored Cordis 源码开始，把"插件树"这个抽象彻底拆开。
