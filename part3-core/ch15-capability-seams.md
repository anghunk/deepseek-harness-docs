# 第 15 章 能力接缝：执行与沙箱

本章解剖 dsh 的"执行家族"：文件系统、沙箱、子进程、shell、终端、后台作业、审批。它们共同构成"抽象接缝 → 本地实现 → 模型工具消费"的分层家族——**Definition 只声明能力与边界，Provider 拥有执行世界，Consumer 负责把 per-call 策略交给能力并渲染结果**。一次 Provider 替换，整个产品随之迁移。

## 15.1 家族总览

| ctx 服务 | 角色 | Definition | Provider(s) | 主要 Consumer |
| --- | --- | --- | --- | --- |
| `ctx.fs` | seam | `packages/fs/fs` | `fs-local`、`fs-sandbox`、`fs-e2b` | `tool-fs` |
| `ctx.sandbox` | seam | `packages/sandbox/sandbox` | `sandbox-local`、`sandbox-windows-acl` | `bash-sandbox`、`terminal-bash` |
| `ctx.sandboxPolicy` | core | `sandbox-policy` | — | 两个强制族共用 |
| `ctx.subprocess` | seam | `packages/subprocess/subprocess` | `subprocess-local`、`subprocess-e2b` | `bash-*`、LSP、子代理 |
| `ctx.shell` | seam | `packages/shell/shell` | `bash-local`、`bash-sandbox`、`pwsh-local` | `tool-bash` |
| `ctx.terminals` | seam | `packages/terminal/terminal` | `terminal-bash` | `tool-terminal` |
| `ctx.jobs` | seam | `packages/jobs/jobs` | `jobs-local` | `tool-jobs`、`tool-bash`(bg)、`tool-subagent`(one-shot bg) |
| `ctx.codeRuntime` | seam | `packages/code-runtime/code-runtime` | `code-runtime-worker` | Code Mode |
| `ctx.storage` | seam | `packages/storage/storage` | `storage-json`、`storage-sqlite` | 各持久化域 |
| `ctx.attachments` / `ctx.credentials` | seam | `attachment` / `credentials` | `attachment-local` / `credentials-local` | LLM 适配器、Web/ACP/MCP 图片入口、Code Mode |
| `ctx.fileUploads` | seam | `client/file-upload` | `file-upload` | Agent-scoped staged file uploads |
| `ctx.approval` | seam | `interaction/user-approval` | `acp`(桥) | `tools`、`tool-bash`、`tool-fs` |

**接缝语义设计核心**：多个同族 Provider（本地/沙箱/远程 e2b）通过"一次只装一个对应 ctx 服务的实现"热切换，工具层与策略层不感知后端差异——这是全书最值得强调的架构主线之一。

## 15.2 通用语言：结构化错误与品牌化 ID

- **`HarnessError`**（`@deepseek-ai/dsh-llm`）：所有能力错误的基类，带 `code` 字段；工具注册表把 `{ name, code }` 原样放进 `isError` 结果——重试/权限/UI 层不看消息文本直接分支；
- **品牌化 ID**：`FsTargetKey`/`FsVersion`、`ApprovalRequestId`、`JobId`——"包装成类型但不做输入校验"的字符串。官方注释强调：消费方**不得解析** targetKey、**不得解释** version——接缝把"宿主路径"与"执行世界路径"二元划分。

## 15.3 ctx.fs：文件系统接缝

### Definition（`packages/fs/fs/src/index.ts`）

- `resolve(path, opts)` → `FsTarget`：把用户/模型路径解析成该执行世界的稳定目标（local 后端 normalize+realpath；远程后端可能一次回环，故设计为 async）；
- `processPath(target)` / `fileUrl(target)`：返回"本执行世界内子进程能打开 / 真正的 file: URI"——与不透明的 `targetKey` 区分，消费方可把 `processPath` 传给另一个 OS 能力；
- `contains(parent, child)`：规范包含判定；
- `stat`/`lstat`：`lstat` 不 follow 最终 symlink，能报 `symlink` 供信任边界拒绝；
- `readText`/`streamText`/`readBytes`：字节读取**必带 `maxBytes` 上限**，超限报 `FS_TOO_LARGE` 而非无界缓冲；
- `writeText`/`editText`：**原子**写/字面编辑，可选版本守卫（`expected`），可带 `sandboxPolicy`（per-call 沙箱策略）；
- `sandboxMode` getter：后端"默认是否自带沙箱"的能力事实（`fs-sandbox` 覆写为部署默认）。

### Provider 对比

- **`fs-local`**：朴素本地实现，直通 OS；
- **`fs-sandbox`**：沙箱栅栏——每个操作经 `ctx.sandbox.confine` 包裹后再执行；
- **`fs-e2b`**：远程执行世界（E2B 沙箱）。

### 伴生策略：fs-observation-policy

`fs/*` 事件（`fs/observed`、`fs/write-intent` 等）携带**不透明的 actor 对象**（`ToolExecution`），策略插件结构性窄化（`actor.agent.session` 作 owner）。文件操作被观察、被策略过滤，工具本身不内置策略。

## 15.4 ctx.sandbox：沙箱接缝

### Definition（`packages/sandbox/sandbox/src/index.ts`）

唯一抽象方法：

```ts
abstract confine(argv: readonly string[], policy: SandboxPolicy): ConfinedArgv
```

- **语义**：把"将要 spawn 的确切 argv"包成受某个 host-path 文件策略的执行。容器/microVM/远程执行是"替换整条能力接缝"的兄弟实现，**不是** `ctx.sandbox` 的 provider；
- **per-call 策略**：`SandboxMode = 'read-only' | 'workspace-write' | 'danger-full-access'`，策略随调用携带——同一时刻两个消费方可要求不同边界（bash 只读、子代理可写状态目录）；已批准的升级重试就是带更宽策略的新调用。`danger-full-access` 消费方直接 spawn 原始 argv，不调用 `ctx.sandbox`；
- **`ConfinedArgv`**：替换 argv + enforcement（`full | partial`）+ 该后端私有的 denial 方言（bwrap 报 EROFS、Landlock 报 EACCES、Seatbelt 报 EPERM）+ runner 失败规则；
- **失败关闭**：没有可用后端时抛 `SandboxUnavailableError`（`SANDBOX_UNAVAILABLE`），**绝不允许静默非受控放行**。

### 升级编排：escalation.ts

bash/fs 两个强制族共用的"升级编舞"：

- `WIDER_MODES`：`read-only → [workspace-write, danger-full-access]` 严格更宽阶梯——**执行期检查，绝不烘进工具 schema**；
- `validateEscalationArgs`：`sandbox_permissions` 与 `justification` 必须成对、理由为非空句子；
- 统一模型可见词汇：`[sandbox: file access denied under ${mode} mode]` 与 `[sandbox: escalation available — retry this exact ${subject} once …]`；
- `approveEscalation`：执行前失败关闭序列——先判严格更宽（不更宽绝不提示人），再查 approval/agent，然后 `approval.approver.request(...)`，把 `allowed-once` 印到这一次调用。`EscalationApprover` 是**结构性闭包**而非 approval 服务类型——本包不依赖 approval/agent 包。

### 策略唯一归属：ctx.sandboxPolicy

`SandboxPolicyService` 是"部署默认 mode + workspace-write 根 + per-session 解析"的唯一主人：

- 默认 `mode: 'read-only'`（**失败安全默认**，要可写须显式 opt-in）；
- `resolve()` 优先级：已批准显式 mode > session 日志最后一条 `sandbox/mode` 事件的 fold > 部署默认；`workspaceRoot` 取 `session.header.cwd`（session 不可变 cwd 即工作区边界）；
- host-path canonicalize 先于词法归一（`realpathSync.native`——`/tmp` 在 darwin 是 `/private/tmp` 这类陷阱）；
- per-session 覆盖是**持久化会话事件**（`sandbox/mode`，log-only 可重放），`setSandboxMode` 是唯一写路径；
- 向 `systemPrompt` 注入 `sandbox:policy` 运行时上下文段落，把当前 mode/根描述进模型历史。

### sandbox-local：平台 runner 链

```ts
PLATFORM_CHAINS = { linux: ['bwrap','landlock'], darwin: ['seatbelt'], win32: ['windows-acl'] }
```

- bwrap 只读 profile：`['--ro-bind','/','/','--dev','/dev','--proc','/proc','--die-with-parent']`，workspace-write 追加 `--tmpfs /tmp` + `--bind workspaceRoot`；
- 功能探测仲裁：单一候选免探测；多候选按链序 `probeRunner`（bwrap exit 0 → full；seatbelt `sandbox-exec -p <read-only profile> -- true`…），探测预算默认 5000ms；无可用 runner **fail-closed** 抛 `SandboxUnavailableError`；
- Windows：`CreateRestrictedToken`（`DISABLE_MAX_PRIVILEGE|LUA_TOKEN|WRITE_RESTRICTED`）+ restricting SIDs + per-path 排他锁 + 每次调用派生 logon SID，fail-closed，绝不无限制 spawn。

## 15.5 审批：ctx.approval

### Definition（`packages/interaction/user-approval/src/index.ts`）

- `ApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'`——闭合、失败关闭；`allowed-once` 是唯一授予，只授予被问的这一个动作；
- `ApprovalPolicy = 'ask' | 'never'`——`never` 确定性返回 rejected（严格 headless/CI 姿态）；
- `ApprovalRequest` **故意不含工具参数**——answerer 用 `callId` 把提示贴到已流式到达的工具调用上，避免第二份会漂移的渲染副本；
- `request()` 要求 **open turn**——`approval/asked` + `approval/decided` 审计对必须被持久化日志的 turn 边界包住，turn 之间裸事件在 reload 时会被当 crash 尾巴丢弃；
- `decide()`：signal abort → `cancelled`；**`never` 策略在派发前就地判**（即使 `prepend: true` 后挂的监听器也绕不开）；否则 `ctx.waterfall(scopeTarget(this, agent), 'approval/request', req, () => 'unavailable')`；throwing answerer 用 `unavailable` 关闭问题——**绝不让 answerer 崩溃打开工具调用**；
- 事件：`approval/request`（waterfall，按 agent 过滤）、`approval/asked`/`approval/decided`（emit 审计）、`approval/policy`（策略事件）。

### tools 管线内的审批门

审批不埋在个别工具里，而在 `ctx.tools` 的执行管线：

- `tools/pre-execute`（waterfall）返回 `allow | deny | ask`；**`ask` 触发 `serviceAsk`**：机会式 `ctx.get('approval')`（没有则退化为 deny）→ `approval.request({ agent, toolName, callId, reason, signal })` → 结果映射（`allowed-once → allow`；`rejected/cancelled/unavailable →` 各自 deny reason，让模型区分"人拒绝"与"无渠道"）；
- 沙箱升级的审批**独立接入**（escalation 在工具内部、任何命令执行之前调 `ctx.approval.request`），不经过 tools/ask。

### 执行管道全景（tools/src/index.ts）

`createExecution`（冻结参数）→ **pre-policy**（`tools/pre-execute`，含 ask 门）→ **单调守卫**（`guard()`，后续监听者无法撤销）→ **around-dispatch**（`tools/execute` → `dispatchToolBody`）→ **post-policy**（`tools/post-execute`：`accept|block|replace`）→ 内容 finalize → 最终通知（`tools/result` emit，只读冻结结果）。

`ToolExecution`（`exec`）携带 `rootCallId` + 不透明 `token` + `agent/callId/name/signal`，被**原样**当 actor 传给 `fs/*` 事件——fs 观察策略、审批都用 `exec.agent` 作 owner。这就是"fs/* 事件只带不透明 object actor、政策插件结构性窄化"的统一落点。

## 15.6 子进程 / shell / 终端

- **`ctx.subprocess`**：`spawn` 抽象（argv、cwd、env、stdio）；`subprocess-local` 直通；`subprocess-e2b` 远程。bash、PTY、LSP、子代理全部消费它；
- **`ctx.shell`**：`execute(command, opts)` 抽象；`bash-local`（裸）/`bash-sandbox`（沙箱包裹 argv）/`pwsh-local`；`tool-bash` 消费；
- **`ctx.terminals`**：持久终端（PTY 生命周期：create/attach/input/output/exit）；`terminal-bash` 实现，`tool-terminal` 消费——终端会话跨工具调用存活，是交互式工作流的基础。

**沙箱如何包裹 argv（端到端）**：`bash-sandbox` 把命令构造成 `[...runnerArgv, '--', ...argv]`（bwrap/seatbelt 的 `--` 分隔符），runner 失败按 `fatalSignatures` 分类，denial 按方言签名识别并转成统一 `[sandbox: ...]` 标记喂给模型。

## 15.7 后台作业：ctx.jobs

`JobRegistry`（`packages/jobs/jobs`）：`start({ kind, label, owner, run })` 注册长任务；返回 `JobId`；配套通用控制工具 `job_kill`/`job_list`/`job_output`；完成经 `agent/*` 事件通知；`tool-bash` 的 `run_in_background`、终端 `pty-send` 与产品 subagent 的 one-shot 后台运行（`backgroundMode: 'one-shot'`，第 16 章）都走它。任务生命周期（发布后）归 `job_kill`/所有者销毁，不再归 `exec.signal`（第 19 章）。

> **事件纠错**：不存在 `jobs/*` 事件——jobs 用 `onJobDone`/`onJobsChanged` 监听器而非 Cordis 事件；也不存在 `tool/start`、`tool/error` 事件——工具的生命周期事实就是会话事件 `tool/call` + `tool/result`（`tools/result` 是只读观察、`tools/change` 是注册表脏标记）。另外 `tool-fs` 的工具名是裸的 `read`/`write`/`edit`/`read_image`（没有 `ws_*` 前缀），且 write 路径不调 `ctx.fs.stat`——存在性检查由 fs provider 内部的 probe 守卫完成。

## 15.8 其他接缝速览

- **`ctx.storage`**：键值存储 seam（`storage-json`/`storage-sqlite`），`storageDomain` 分域；
  - **`ctx.attachments`**：附件 seam（`attachment` 定义 / `attachment-local` 内容寻址实现）。角色无关的 `ImageBlock` 只携带**引用**（`ImageAttachmentRef`），base64 绝不进会话事件。`0.1.0-rc.7` 起提供**批次准入** `saveImages(inputs)`：由接缝统一持有图片数量/总字节/单张字节/完整解码 MIME 校验/尺寸/像素数等限制，**先校验全部成员再写任何成员**、按序提交，整批成功才返回引用——失败不返回部分引用。Web 上传、ACP 内联图片与 MCP 图片投影都经这条共享入口（各入口先自证"确切路由支持图片输入"，再委托 `saveImages`）；Code Mode 把含图片的已结算子结果经外层 `run_code` 结果延后为带来源归属的上下文。`0.1.1-rc.2` 起，图片准入采用**宽源信封**（32MiB / 100MP / 单边 16384px）配合**确定性规范编码**：准入不再直接拒绝大源，而是持久化一份规范编码——EXIF 方向烘焙进像素、元数据剥离、长边按部署配置的规范目标缩放（默认 2048px）；PNG 调色板用于 alpha/PNG/GIF 源，JPEG 源走固定质量阶梯（85/75/60/45）直到字节目标（默认 1MiB）满足；预算内的 PNG/JPEG/WebP 逐字节透传以保证相同源去重到同一内容地址，GIF 始终重编码为 PNG 第一帧以固定"第一帧"语义。`read_image` 工具在存储发生缩放时额外在输出信封中报告原始尺寸（`sourceWidth`/`sourceHeight`）与坐标缩放因子，供程序化消费方将附图中测量的坐标映射回原始文件；
- **`ctx.credentials`**：凭据 seam（`credentials-local`），LLM 适配器读取 API key；
- **`ctx.codeRuntime`**：Code Mode 的代码执行运行时（worker thread）。

## 15.9 设计亮点小结

1. **一次 Provider 替换迁移整个产品**：fs/subprocess 共享执行世界，指向远程沙箱则 Bash/PTY/LSP 全部随之迁移；
2. **策略随调用携带**（per-call sandbox policy）而非固定在 provider；
3. **失败关闭**：无沙箱后端 → `SandboxUnavailableError`；审批无渠道 → `unavailable`；`never` 策略派发前就地判；
4. **统一升级编舞**：严格更宽阶梯执行期检查，审批与沙箱词汇单一来源；
5. **策略即持久化事件**：`sandbox/mode`、`approval/policy`、`permission/preset` 都是可重放审计日志；
6. **不透明 actor**：`fs/*` 事件带 `ToolExecution` 对象而非结构化身份，策略插件自行窄化；
7. **平台 runner 链 + 探测仲裁 + 方言识别**：跨 Linux/macOS/Windows 统一沙箱语义。

下一章：代理预设、目标与子代理。
