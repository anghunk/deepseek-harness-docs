# 第 16 章 代理预设、目标与子代理

本章覆盖 dsh 的"会话层"高级机制：**agent preset**（每个会话的能力组合）、**goal**（同会话目标循环）、**subagent**（子代理接缝）、以及 plan/skill/compaction 等扩展。

## 16.1 agent preset：会话层组装

第 9 章讲过 profile/bundle 是**启动层**组装（决定"这个进程由哪些行组成"）。preset 是**会话层**组装（决定"每个会话看到哪些工具与提示词段落"）——两者正交。一个进程可以同时运行多个组装方式不同的 agent。

### 目录布局

```
$DSH_HOME/.agent-presets/<id>/     # 用户本地 preset
apps/cli/config/agent-presets/     # 部署交付的 preset（standard、code、cordis、minimal…）
├── agent.cordis.yml               # 组合文件：一份 Cordis 插件行列表
└── preset.yml                     # 显示元数据：name/description/order
```

- **目录名即 preset id**，必须匹配 `^[a-z0-9][a-z0-9-]*$`——id 会成为路径段，这是**包含边界**（`..`、分隔符会让组合文件落到授权根之外）；
- `preset.yml` **只承载显示文本**：`id`=目录名、`trust`=所在根（`system|user`），不可在元数据里改写——否则本地 preset 可伪装成官方件；
- 发现不记忆化：`list()`/`resolve()` 每次重读根——进程运行期间新写的 preset 立即可见，被删者下一次消失；
- **broken preset 保留在 roster 上**（目录占着 id，隐藏了就无可看可删），但每个挂载路径都前置拒绝它（`resolveMountable` 在 loader 之前就抛 `PresetMountError`）。

### standing mount：每进程一份组合

**最核心的设计决策：一个 preset 是每进程一份组合，而不是每会话一份**（设计笔记 `2026-08-08-per-preset-standing-mounts.md`）。原因：三个 host 读取端依赖"静态注册面"（cold `session.history` 的 presenter、projections 块、Typert 网关的 goals 解析）——每会话挂载会破坏它们。

- `ensureStanding(preset)`：单飞行（single-flight）——两个 agent 竞用首用共享一份组合；
- 挂载 scope key 是 `{ agentPreset: preset.id }`；
- **文件戳（stamp）**：`compositionStamp = mtimeMs + size`——编辑组合文件会启动下一代 ensureStanding；**已加入的会话保留其代次**；被取代的代次只在整树 teardown 回收；
- `mount(agentCtx, id)`：**唯一受支持的调用点是 agent factory 的 `setup(agentCtx)` hook**——只有在这里，join 是在 agent 尚未发布时安装的，组合被拒绝可整体回滚创建；
- `composeFrom(agentCtx, parentCtx)`：子 agent **加入父已运行的那份同一 standing 组合**（不是 re-resolve preset）——同一代插件对象/工具注册/提示段落；同步、无组合失败模式，in-process 子代理驱动在同步 setup 内使用；
- `recompose(agentCtx, id)`：re-link 到另一 preset——parent re-link 而非 unmount（standing 共享且持久，旧组合留给其它 agent）；仅当 agent 还没产出时合法（调用方自查）。

### 挂载的防护审计

`mountPreset` 把组合子 Include（`PresetTree`）挂到 agent scope 下，在两个 guard 上 fail-loud：

1. **`inactiveRows`**：仍在等待组合未提供的服务的行（`fiber.inject` 里 `ctx.get` 为 undefined 的名字）→ 逐行报诊断并 reject；
2. **`leakedServices`**：某行把服务发布进 **ROOT realm（无 isolate）** → 该服务是进程全局而非每会话，第二个会话挂同一 preset 会撞 → reject 并列出泄漏名。

另有四个防御性覆写：

- **`PresetTree.import`**：裸包名从 harness 自己的 base 解析（本地 preset 在用户 home，Node 向上 `node_modules` 走不到 harness 依赖）；
- **`PresetTree.write` 覆写为空**：preset 是输入，**从不作为持久化目标**——否则 Loader 会在销毁时把预设文件重写成 `[]`（首会话一结束就截断 shipped 组合）；
- `mounts` 集合按 fiber `uid === null` 观察式清理；
- `serviceForAgent(ctx, agent, name)`：浏览器 RPC 从外部请求"关于某个 agent 的某服务"时，穿过 entry-local realm 读到该 agent 的实例（只读地址）。

### isolate realm：preset 正确性的地基

- **发布服务的行必须放进带 `isolate` realm 的 group**（`cordis:group` + `isolate: { <label>: true }`）——不带则发布进 root realm = 进程全局，另一 preset 发布同名就撞；
- **共享 realm label 不是选项**：`provide()` 在第二个同 realm symbol 注册时 throw；label 联的是 REALM 而非实例；
- 隔离方向：realm 是"组内可见、组外（含 host 与其它 agent scope）不可见"的**单向遮蔽**；
- **host-plane vs agent-plane 判据**：一行若 host 行 `inject` 服务（inject 在任何 session 前解析、无可 key 的 agent），该服务必须留在 host composition；行发布全局服务/注册进程级单例（subagent 注册表、jobs、shell-env）也归 host-plane；而 planMode、workflowEngine 是 per-agent 的，用 entry-local realm 正确。

### 会话记录

`SessionHeader.agentPreset` 持久化"从哪个 preset 组合"——resume 恢复到不同组合会把模型再也无法执行的历史重放给它。创建后换 preset 经 `agent-preset/selected` 会话事件（log-only）；`resolveSessionPreset` 扫日志取**最新一次**选择（回放重建切换过的会话时不能只看创建时值）。

## 16.2 goal：同会话目标循环

`packages/goal/*` 四包：`goal`（领域核心 `ctx.goals`）、`goal-round-driver`（自动续跑）、`tool-goal`（模型工具）、`command-goal`（人类 `/goal` 命令）。

**目标状态由会话日志的 `goal/change` 事件驱动**（CAS 变更，自动满足"模型可见 ⟺ 已持久化"规则）：

- `GoalId` 品牌化；`GoalRef { id, revision }` CAS 身份，每次 accepted 变更 revision+1；
- `GoalPhase = 'active' | 'paused' | 'blocked' | 'complete'`——**phase 是持久化生命周期**；`activation = 'armed' | 'disarmed'` 是**进程内续跑资格**——两者分离（会话恢复后目标需要 re-arm）；
- `GoalOperation = create|edit|pause|resume|complete|block|clear`；
- 变更载荷：`GoalSnapshotChangeMeta`（完整快照）或 `GoalClearChangeMeta`（clear tombstone）；
- 每轮续跑以 `{ kind: 'goal', goalId, revision, round }` 消息源合并进 `MessageSourceMap`；
- 会话事件 `goal/change` + Cordis 事件 `goal/changed`（emit、scope 过滤）；
- `GoalService extends TypertRemoteService`——`@Remote` 标记的方法同时是网关端点（UI 可从浏览器调用）；
- `goal-round-driver` 监听 `agent/*` 事件驱动继续：agent 静默后检查目标是否 armed、是否有剩余轮次，经 `agent.inject()` 注入下一轮续跑消息。

## 16.3 subagent：子代理接缝

`packages/subagent/subagent` 定义接缝，providers 一长串：

| Provider | 形态 |
| --- | --- |
| `fork-in-process` / `spawn-in-process` / `in-process-driver` | 进程内子代理（同步 setup 内 composeFrom 父组合） |
| `subagent-acp` | ACP（Agent Client Protocol）代理（自动化传输层，支持成对的文本/图片提示与回答） |
| `subagent-claude-code` / `subagent-codex` | 外部产品委托（一次性任务，见下） |
| `subagent-dsh-sdk` | SDK 驱动 |

消费者是 `tool-subagent` 系列工具（`subagent`、`subagent_report` 等）。接缝语义：**从全新子 agent 到委托给另一产品的 turn**，Provider 变化同样广泛——这正是"可替换接缝"的极致体现。子代理注册表是进程单例（provider 名只能注册一次），因此留 host-plane。

**浏览器控制 Remote 迁移（0.1.2-alpha.1）**：浏览器控制操作（截图、点击、输入等）现在通过 `@Remote` 接口暴露，而非直接的 RPC 调用。`feat(subagent): migrate browser control to Remote` 把浏览器控制迁移到 Remote 模式，与第 17 章的类型化 RPC 架构保持一致。这允许浏览器端通过 `ctx.remote.subagent.browserControl.*` 调用 Host 侧的浏览器控制方法，享受 Remote 的类型安全与生命周期管理。

**Agent Teams（实验性）**：`packages/team/` 引入了实验性的 **Agent Teams** 功能，支持多个 Agent 协作完成复杂任务。`0.1.2-alpha.1` 新增了两个 profile：

- `dsh-agent-teams-cli`：CLI 版本的 Agent Teams profile；
- `dsh-agent-teams-web`：Web 版本的 Agent Teams profile。

Agent Teams 目前仍处于实验阶段，主要用于探索多 Agent 协作模式。

**产品提供方的可选安装（0.1.0-rc.7 起）**：生产 `dsh-base` **不再**依赖或挂载 `codex` / `claude-code` 两个可选提供方（安装排除决策）。选择产品集成的 Profile 需显式安装对应的提供方 Bundle（`dsh-subagent-codex` / `dsh-subagent-claude-code`）；其 patch 挂载默认实例，而 Profile 可在 host plane 挂载更多命名实例。两个产品都接受多个唯一的 `providerName` 值，同时保留 `codex` 与 `claude-code` 作为默认值。加载任一插件只注册休眠后端，产品进程到第一次实际委派才启动。每个 Bundle 把可执行文件选择交给包自有的产品运行时：Codex 包运行自身声明的 wrapper，Claude Code 包让锁定的 Agent SDK 选择私有原生可执行文件；两个提供方都不查询或回退宿主产品命令。Agent Preset 通过普通 `dsh-tool-subagent` 配置项的 `provider` 与 `toolName` 准确公开单个 agent 所需的已配置实例，而无需更改 Host 注册表。`standard` / `code` / `cordis` Agent Preset 中对应的工具行以 `backgroundMode: 'one-shot'` 声明：删除行的 `disabled` 字段后，可选参数 `run_in_background` 对由该 preset 组装的 agent 公开——省略或 `false` 在前台等待最终回答；显式 `true` 则经同步 Job 预检与登记后返回父级拥有的 Job id（由通用 `ctx.jobs` / `dsh-tool-jobs` 负责收集、取消与完成通知，见第 15 章），不新增任何产品专属后台状态。

## 16.4 plan / skill / compaction / spill

### plan：ctx.planMode

**没有 `ctx.plan`**——plan 服务是 `ctx.planMode`（`PlanModeController`）；模型侧退出是 `exit_plan_mode` 工具，人类侧是 `/plan` 命令；状态是对日志 `plan/mode` 事件的**纯折叠**。plan 模式在 preset 里用 entry-local realm（per-agent）。

### skill：ctx.skills

**没有 `ctx.skill`**——服务是 `ctx.skills`（`SkillRegistry`）。技能**不是**经 `ctx.systemPrompt` 注入，而是以**用户角色 `<system-reminder>` 目录消息**在 `agent/pre-step` 注入（`tool-skill` 提供 `skill` 工具；`skill-filesystem` 提供技能文件系统支持）。

### compaction：会话压缩

compaction 是**三维能力缝**（`compaction/compaction` 定义，`compaction-basic` 实现，`compaction-tool-result-pruner` 裁剪工具结果）：

- 向 `SessionEventMap` 声明合并 `compaction/start`/`summary`/`end` 事件（log-only）；
- 压缩通过 surface 的 `replace` 操作：摘要节点替换一批旧表面节点，`sourceEventSeqs` 完整列出被遮蔽节点；
- 触发：`/compact` 命令、自动策略、模型工具。

### spill：溢出

`spill/spill` + `spill-local` + `spill-policy`：**触发条件是单个工具结果超过 `maxInlineBytes` 上限**（不是"上下文整体太大"）——超限结果被溢出到本地文件，模型可见处只放引用，避免把超大内容塞进上下文。`tools/code-dispatch-log` waterfall 提供 run_code 子派发日志的内容替换口。

## 16.5 会话周边

- **session-query**：查询引擎（`tool-session-query` + SQLite 后端），Agent 可检索历史会话；
- **session-projection**：投影注册表 + 持久化缓存；
- **session-title**：会话标题生成（`ctx.sessionTitle` 唯一 provider，经 LLM）；
- **workflow**：工作流引擎缝（`workflow-worker-thread`、`tool-workflow`、`tool-ralph`）——多代理编排；
- **commands**：人类命令（`/goal`、`/plan`、`/compact`…），不经模型 turn 直接派发。

## 16.6 小结

- preset 是会话层组装：每进程一份 standing mount、文件戳换代、mount 审计（inactive rows / leaked services）、isolate realm 是正确性地基；
- goal 是同会话事件溯源目标：CAS 变更、phase 与 activation 分离、轮次驱动经 agent/inject 续跑；
- subagent 是接缝：进程内/ACP/外部产品多种 provider，注册表留 host-plane；产品提供方按 Profile 显式安装，`backgroundMode: 'one-shot'` 让同一运行可前台收集或走通用 Job 后台；
- plan（`ctx.planMode`）与 skill（`ctx.skills`）的命名与机制都和直觉不同，读代码时注意；
- compaction 用 surface replace 压缩；spill 把大内容溢出到文件。

至此，核心子系统全部解析完毕。下一部分进入 Web 客户端（第 17 章），然后是插件开发技巧（第 18-21 章）。
