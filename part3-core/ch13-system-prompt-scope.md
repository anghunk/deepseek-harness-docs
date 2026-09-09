# 第 13 章 提示词组装与作用域

本章覆盖两个紧密配合的包：`core/scope`（每代理作用域注册原语，库无服务）与 `core/system-prompt`（提示词分节与工具 schema 组装，`ctx.systemPrompt`）。

## 13.1 scope：作用域原语

`packages/core/scope`（约 560 行）**没有注册任何 Cordis 服务**——它是一组被 session/system-prompt/tools 共同消费的纯库原语（依赖链最底层）。

### 核心抽象

- **`ScopeKey`**：一个不透明对象身份（惰性、不检视内容）。默认实现直接用活 `Agent` 对象本身作为 key；
- **`Scoped<T>`**：仅编译期品牌——事件声明 `'agent/created'(this: Scoped<Agent>, ...)` 意味着"携带 agent 载体、按作用域过滤派发"；
- **`Scope` / `ScopeLayer`**：一个作用域的上下文（`ctx`）+ 释放（`rawDispose` 保留 Cordis 确切 disposer 身份供有序组合；`dispose()` 是共享静默边界）；
- **`ScopedLayers<L>`**：eager global 层 + 惰性 exact-scope 层。**读不建层**；注册（`effect`）同时决定"可见性 + effect 归属"，收集同步 undo，整层空时回收 scoped 层；
- **`NamedEntries` / `AnonymousEntries`**：有序条目表；Named 带重名诊断（同层重名报错），Anonymous 每项独立身份；返回幂等逐项 undo。

### 两个相反的传播方向

`ScopedLayers` 的注释点出一个精妙设计（`index.ts:32-39`）：**一个 `scopeParents` 关系同时驱动两个方向**——

1. **注册视图向下继承**：子作用域可见其祖先作用域层（`chainLayers`）——agent 作用域能看到全局层的注册；
2. **事件接受向上延伸**：带祖先标签的监听者能收到发往任意后代键的事件（`scopeTarget` 的 filter）——全局监听者收到所有 agent 的事件，agent 专属监听者只收自己的。

这是"全局工具 + 每 agent 工具"、"全局事件 + 每 agent 事件"能共存于同一套注册表的机制。

## 13.2 system-prompt：组装与排序

`packages/core/system-prompt`（约 600 行）注册 `ctx.systemPrompt` 服务，职责：**注册有序 system 节、动态上下文、工具 schema providers 与 `{{variable}}`，在每次模型步前按角色组装、排序、渲染成完整提示词**。

### 注册面

| 抽象 | 语义 |
| --- | --- |
| `PromptSection { name, order, text, complete? }` | system 节。`order` 决定拼接顺序；`complete: true` 的节是"整段提示"——多于一个有效 complete 节会使组装失败；waterfall 之后恢复该节为唯一节 |
| `PromptContext { name, order, text }` | 动态上下文，物化为**持久 user-role 快照**（这就是 `agent.inject()` 提示词侧的表达） |
| 工具 providers | `systemPrompt.tools(...)`——`SessionStore` 与 `ToolRuntime` 构造时向它登记工具 provider，组装时产出模型可见的工具 schema 列表 |
| 变量 | `{{variable}}` 渲染 |

`assemble(context)` 输出**可合并扩展**的 `PromptAssembly { sections, contexts, tools, variables }`，然后跑 `system-prompt/assemble` **waterfall**——专家监听者可以改写组装结果（`complete` 节除外）。

### 部署 persona 前缀与后缀

`0.1.3-alpha.2` 起，配置中的 `persona` 字段拆分为 `personaPrefix` 和 `personaSuffix` 两个独立模板：

- **`personaPrefix`**（order `0`）：位于第一方指导之前的全局 persona 前缀模板，通常包含模型名称介绍
- **`personaSuffix`**（order `10200`）：位于第一方指导之后的全局 `deployment:persona-suffix` 模板，携带环境信息

第一方段落按以下顺序渲染：harness 身份（order `-1000`）→ 部署 persona 前缀（order `0`）→ 可复用指令（包括生成的工具 SDK 和结构化输出指导）→ 环境后缀：harness 源码（order `10000`）、Web 表层（order `10100`）、部署 persona 后缀（order `10200`）。

这种前缀/后缀分离使 KV Cache 复用更稳定：模型、persona 前缀、工具与前置指令一致时，不同源码路径、本地 Web URL 或 persona 后缀值不会改变可复用的第一方前缀。

### 事件

| 事件 | 模式 | 语义 |
| --- | --- | --- |
| `system-prompt/assemble` | waterfall | 改写组装结果（每次模型步前） |
| `system-prompt/change` | emit | 注册面变化（节/工具/变量增删） |

第 1 章提到的"harness source 提示词节"（`addHarnessSourceSection`，`app-boot/index.ts:821-829`）就是一个 `systemPrompt.section({ name, order: -99, text })` 调用——引导 Agent 知道 harness checkout 在哪。

## 13.3 组装如何发生

每次模型步前，循环调用 `ctx.systemPrompt.assemble(...)`：

1. 按作用域收集：全局层 + 该 agent 的 exact 层（节、上下文、工具 provider）；
2. 按 `order` 排序节，拼接文本；
3. 渲染变量、物化动态上下文；
4. 收集工具 schema（注册的工具自动可见）；
5. 派发 `system-prompt/assemble` waterfall（可改写）；
6. **V3 起**（`0.1.5-alpha.1`）：渲染后的提示词作为 `system/message` surface 事件写入会话日志（位于 surface 节点 0），而非 `request/header` 的 `system` 字段。提示词变更通过 surface 替换表达：首次渲染追加 `system/message`，后续变更替换 surface 节点 0，未变则不操作。`request/header` 仅记录 `config` 和 `tools`，不再包含系统提示词——这使提示词变更与工具变更在日志中可区分（前者是 `system/message` 替换，后者是 `request/header` reason `change`）。

## 13.4 作用域如何让"每 agent 能力集"成立

把三块拼起来：

- **agent 创建时**：`setup(agentCtx)` 在 agent 的 scope context 上装载 preset 插件（第 16 章）；
- preset 插件注册的工具/提示词节/事件监听器都落在 `agentCtx` 的 scope 层；
- 该 agent 的循环在 `agentCtx` 内运行 → `assemble` 只看到本 agent 的层 + 全局层；
- agent 销毁 → scope 回卷 → 注册全部撤销。

于是"每个会话拥有不同能力集"（如不同 preset 给不同工具）不需要任何全局状态——只是作用域层的叠加与回收。

## 13.5 小结

- scope 是纯库原语：ScopeKey/Scoped/ScopedLayers，一个 parent 关系同时驱动"注册向下继承"与"事件向上延伸"；
- system-prompt 注册有序节/上下文/工具 providers/变量，每次模型步前组装 + waterfall 可改写；
- **V3 起**（`0.1.5-alpha.1`）：组装结果作为 `system/message` surface 事件写入日志（surface 节点 0），而非 `request/header.system`。提示词变更通过 surface 替换表达，与工具变更在日志中可区分；
- 作用域层让每 agent 能力集自然成立，销毁即回卷。

下一章：LLM 适配器接缝。
