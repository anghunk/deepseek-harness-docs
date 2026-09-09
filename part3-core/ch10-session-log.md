# 第 10 章 会话日志：事件溯源核心

`packages/core/session` 是 dsh 的心脏：**会话（Session）是追加型（append-only）的类型化事件日志**，是整个 Agent 交互历史的唯一事实源。模型看到的 LLM 消息历史**从日志派生**，从不单独存储；重放就是从同一批事件重新派生。

> Source: `packages/core/session/src/types.ts`

## 10.1 为什么是事件溯源

`docs/subsystems/session.md` 的定位：

> A `Session` is an **append-only log** of typed `SessionEvent`s — the single source of truth for an agent's whole interaction history. The LLM message history is *derived* from the log, never stored separately; replay is re-derivation from the same events.

事件溯源带来几个关键性质：

1. **可重建性**：任何请求都是日志的纯函数（request/header 事件记录了完整请求信封）；
2. **可重放性**：UI、遥测、fork、resume 全部派生自同一条流；
3. **不可变性**：事件在写入时深冻结，日志不可被改写；
4. **可扩展性**：插件通过声明合并向 `SessionEventMap` 添加事件类型，无需改动核心。

配套不变式（官方强调）：

> **Model-visible means logged.** Anything that reaches a model request must be reconstructable from the log, and a runtime invariant asserts it.

"模型可见即已记录"——任何进入模型请求的内容必须能从日志重建。因此，新增模型可见输入 = 新增会话事件类型（扩展 `SessionEventMap` 并从日志渲染），而不是在循环里临时拼接。

## 10.2 SessionEventMap：事件词汇表

`SessionEventMap`（`types.ts`）是会话事件的完整词汇表，**merge-extensible**（插件声明合并扩展，如 compaction 接缝添加 `compaction/start`/`summary`/`end`）。核心事件（`docs/subsystems/session.md` 的 type-equiv 块）：

| 事件 | 载荷 | 语义 |
| --- | --- | --- |
| `turn/start` | `{ turn }` | 打开 turn（在认领输入/跑 pre-step 之前） |
| `turn/end` | `{ turn, reason }` | 关闭 turn，reason ∈ `TurnEndReasonMap` |
| `step/start` / `step/end` | `{ turn, step }` | 一个 step 的边界（一次模型调用 + 其工具执行） |
| `user/message` | `UserMessage` | 用户角色消息：直接提示、`agent.inject()` 注入上下文、目标续跑轮 |
| `assistant/message` | `{ turn, step, message, stream, usage? }` | 组装好的助手消息，**嵌入精确紧凑带时间 stream**（`AssistantStreamRecord[]`），携带 token 用量 |
| `assistant/attempt` | `{ turn, step, stream }` | 未产生 surface message 的模型 attempt——失败、重试、取消或 stream error attempt 的持久 stream |
| `tool/call` | `{ turn, step, callId, name, arguments }` | 模型请求一次工具调用（arguments 是模型原始 JSON 字符串，**不解析**） |
| `tool/result` | `{ turn, step, message, error?, meta? }` | 工具完成的模型可见结果 + 可选内部失败标识 + 工具私有 meta |
| `system/message` | `{ turn, step, message }` | 系统提示词作为 surface 节点（V3 新增），渲染后的提示词住在 surface 上而非 `request/header` |
| `todo/write` | `{ todos }` | 任务清单整体快照（仅日志 UI 状态，不进派生历史） |
| `request/header` | `{ header, reason }` | 下一个请求的完整信封（配置+工具 schema，**V3 起不再包含系统提示词**） |
| `request/context` | `RequestContext` | 路由元数据（provider/model/contextWindow） |
| `session/end-seed` | `{ inherited? }` | 种子（resume/fork/replay）结束边界；fork 子会话带 `inherited: true` 标记 |

**只记事实，不记中间态**：turn/step 边界、embedded streams、usage 都是"事实"；`request/header` 以全量快照记录（latest wins 重建）；`todo/write` 也是全量快照。**V2 格式移除 `assistant/chunk`**——每次模型 attempt 的 stream 直接嵌入 `assistant/message` 或 `assistant/attempt`，保持 `seq` 连续性同时消除冗余事件信封。**V3 格式（0.1.5-alpha.1）将系统提示词迁入 surface**——`system/message` 成为 surface 事件，`request/header` 不再包含 `system` 字段，提示词变更通过 surface 替换表达。

## 10.3 SessionEvent：日志条目

```ts
// types.ts（docs/subsystems/session.md type-equiv）
type SessionEvent<T extends SessionEventType = SessionEventType> = {
  [K in SessionEventType]: {
    type: K
    seq: SessionSeq        // 单调序号（V3 起使用 SessionSeq 品牌类型），seq = log.length
    time: number         // epoch ms
    data: SessionEventMap[K]
    ignorable?: true     // 可安全跳过的纯信息记录
  } & (K extends SurfaceEventType ? {
    sourceEventSeqs?: SessionSeq[]   // 引用的更早事件 seq（V3 起使用 SessionSeq 品牌）
    surfaceOp: SurfaceOp        // V3 起必填：'append' | { op: 'replace', startSeq, endSeq }
  } : object)
}[T]
```

设计要点：

- **真判别联合**：按 `type` 判别（而非独立的 type/data 联合），`switch (event.type)` 自动收窄 `event.data`；
- **ignorable 标记**：缺省 = 必需。读者遇到无法识别且无标记的事件**必须拒绝重建**，而不是静默丢弃——"忘记标记宁可过度拒绝，也不可静默续用一个被掏空的会话"；
- **Surface 元数据**：**V3 起四种消息产生型事件**（`SurfaceEventType = 'system/message' | 'user/message' | 'assistant/message' | 'tool/result'`）**必须**携带 `surfaceOp`——编译器在 `Session.append` 调用点强制这一约束。**V2 格式中 `assistant/message` 不能携带 `sourceEventSeqs`**（类型系统强制为 `never`），因为 stream 已直接嵌入；只有 `system/message`、`user/message` 和 `tool/result` 可以引用更早事件。**V3 格式**（`0.1.5-alpha.1`）将 `surfaceOp` 从可选改为必填，`sourceEventSeqs` 从 `number[]` 改为 `SessionSeq[]`（品牌类型），替换端点从 `start`/`end` 改为 `startSeq`/`endSeq`。

## 10.4 Surface：派生历史的唯一入口

**四种**消息产生型事件构成**有序表面（surface）**（V3 起包含 `system/message`）。`SurfaceOp`：

- `'append'`：正常追加到尾部；
- `{ op: 'replace', startSeq, endSeq }`：用本事件**替换** `startSeq..endSeq` 范围内的表面节点（`startSeq === endSeq` 单节点替换），被遮蔽的节点必须全部出现在 `sourceEventSeqs` 中——这是 **compaction（上下文压缩）** 的机制：压缩后一个摘要节点替换一批旧消息，派生历史立即反映压缩。**V3 起**（`0.1.5-alpha.1`）端点字段从 `start`/`end` 改名为 `startSeq`/`endSeq`，使用 `SessionSeq` 品牌类型。

`Session.surface` 是活的只读投影：`nodes`（模型可见顺序的表面事件 seq 列表）+ `replaceGeneration`（位置替换的单调计数，增量消费者据此区分"纯尾部增长"与"重写"）。

**派生规则**（`deriveMessages()`，**V3 起唯一派生路径**）：

- `system/message` → 系统消息（V3 新增，空 content 投影为 `null` 不贡献协议消息）；
- `user/message` → 用户消息（content 原样）；
- `assistant/message` → 助手消息；**空 content 的 assistant/message 被跳过**（max-tokens 截断仍记录 stream/usage/provider/model，但不进模型转录）；
- `tool/result` → 携带 `tool-result` 块的用户消息；
- `assistant/attempt` → 派生时**跳过**（仅日志记录，不产生模型历史）。

**V3 格式变更**（`0.1.5-alpha.1`）：`deriveMessages()` 以遍历 surface 作为**唯一派生路径**，不再对没有 surface 标记的会话回退到线性扫描。缺少必填 `surfaceOp` 标记的 surface 事件无效。

注意：v2 格式不再存在 `assistant/chunk` 事件——stream 直接嵌入 `assistant/message` 或 `assistant/attempt`。

## 10.5 Session 公开 API

```ts
declare class Session {
  static create(id, seed?, header?)          // 分离式创建（replay/fork）
  static fromRestore(id, seed, header)       // 持久化恢复
  get surface(): SessionSurface
  get events(): readonly SessionEvent[]      // 深冻结快照
  get seq(): number                          // 下一个 seq = 日志长度
  append(type, data, opts?): SessionEvent    // 追加（热路径同步，无 I/O）
  deriveMessages(): Message[]                // 派生模型历史（缓存 + 冻结）
  requestHeader(): EpochHeader | undefined   // 折叠后的请求信封
  requestContext(): RequestContext | undefined
}
```

### append 的防御

`Session.append`（`packages/core/session/src/session.ts`）是全书防御性最强的函数之一：

- **无损 JSON 校验**：`data` 必须可无损 JSON 序列化（拒绝 BigInt、函数、symbol、undefined、负零、非有限数、循环引用、稀疏数组、Map/Set/Date/类实例……）——`isJsonValue` 在写入时校验，坏事件在源头被拒，持久化后端永远只见到合法事件；
- **单遍读写**：一次递归遍历同时完成"读、校验、拷贝"（防止有状态 getter 给校验一个值、给存储另一个值）；
- **表面契约校验**：marker 形态与资格、source 引用唯一、位置替换合法、遮蔽覆盖完整；
- **深冻结**：事件及嵌套数据在接纳时冻结，类型转换也无法改写持久历史；
- **重入拒绝**：append 接受/发布边界未闭合时再次 append 会拒绝。

### 持久化接缝

`Session` 本身**不实现持久化**——持久化是插件：订阅 `session/event` 事件、在 `session/flush`（parallel 检查点）排水。`ctx.sessions.flush(session)` 是唯一的 flush 入口（store 拥有 carrier，`docs/subsystems/session.md`）。JSONL 与 SQLite 后端见 `docs/subsystems/persistence.md`；崩溃恢复会合成 `{ kind: 'interrupted' }` 的 `turn/end`（循环本身从不发出该 reason）。

## 10.6 SessionStore：ctx.sessions

`SessionStore`（`packages/core/session/src/index.ts`）管理活会话：

| 方法 | 语义 |
| --- | --- |
| `create(id?, opts?)` | 创建并发布活会话（seed 事件 = replay/fork） |
| `prepare / enter / announce` | 分阶段生命周期：先构建（不进 store）→ 安装发布钩子并入库 → 派发 `session/created`（同步 throw 可否决并回滚）。`create` 是三步的便捷封装；需要"会话与循环按序拆卸"的调用方（agent factory）用三步版 |
| `get / list` | 查询 |
| `fork(source, boundary?, childSessionId?)` | 分叉：选 source 事件前缀（含 boundary seq，默认到当前末尾），要求前缀结束于 turn 之间（不得切开打开的 turn），深克隆种子事件 + 子会话元数据（parentSession、seedLength、继承 cwd） |
| `flush(session)` | 持久化检查点 |

## 10.7 会话事件：session/* 域

| 事件 | 模式 | 语义 |
| --- | --- | --- |
| `session/created` | emit | 创建公告；同步 throw 否决并回滚 |
| `session/disposed` | emit | 离开 store（含发布回滚）；只发一次 |
| `session/event` | emit | **提交后**的追加流（fire-and-forget，监听者快照在入队前解析、回调在入队后执行） |
| `session/flush` | parallel | 持久化检查点 |

四个事件都是 scope-filtered（`Scoped<Session>`）：agent 作用域监听者只收到经该 agent context 进入的会话事件——UI 订阅某个 agent 会话流的底层机制。


## 10.8 会话持久化重构：Handle-Based Seam

`0.1.2-alpha.4` 引入了会话持久化的重要架构变更（`refactor(session-persistence)!: handle-based seam with a lifecycle-owned write path`）：

**Handle-Based 生命周期管理**：

- 持久化写入路径现在由**生命周期拥有的句柄**管理，而非直接持有会话引用；
- `SessionPersistenceHandle` 封装了写入语义，与会话生命周期解耦；
- 这种重构使得持久化后端可以更好地管理资源生命周期，避免悬挂引用；
- 崩溃恢复语义保持不变，但内部实现更加健壮。

这一变更影响了所有持久化后端（JSONL、SQLite），但对外部 API 无破坏性变化。

## 10.9 会话投影缓存：跨版本读取兼容性

`0.1.2-alpha.5` 改进了会话投影缓存（`session-projection-cache`）的健壮性：

**跨版本兼容性**：

- `fix(session-projection-cache): keep upgraded caches readable and boots safe across domain versions` 确保升级后的缓存仍可读取；
- 引入**版本读取兼容性**（`feat(storage): version read compatibility and backup-and-skip salvage for per-record units`）；
- 当缓存格式不兼容时，采用**备份并跳过**策略而非硬失败；
- 这保证了会话在升级后能够快速恢复，不会因为缓存格式变化而卡死。

**Schema 变更.fixture 规则**：

- 新增规则：当 fixture 依赖的 schema 发生变更时，必须同步更新 fixture 或明确标记为预期失败；
- 这防止了缓存投影的静默损坏。

## 10.10 会话轮次大纲投影

`0.1.2-alpha.3` 引入了**会话轮次大纲**功能（`session-turn-outline`）：

**轮次大纲投影**：

- `feat(session-turn-outline): whole-log turn outline projection` 实现整日志的轮次大纲投影；
- 将会话日志按 turn 边界组织成大纲结构，提供高层次的会话导航视图；
- UI 层可以基于此投影实现**轮次导航栏**（`feat(ui-chat): scrollable fixed-pitch turn rail`）；
- 支持**深度历史分页**（`feat(session-controller): loadThrough deep history paging`），长对话可以按需加载历史片段。

**性能优化**：

- `perf(session-projection): memoize raw views by state identity` 通过状态身份记忆化原始视图；
- `feat(session-projection): identity-gated change feed` 实现身份门控的变更流；
- 这些优化使得大规模会话的 UI 响应更加流畅。

## 10.11 持久化格式迁移：v0→v1→v2→v3

`0.1.3-alpha.1` 引入 Session 格式 v2（`SESSION_FORMAT_VERSION = 2`），这是首个结构性格式升级。**`0.1.5-alpha.1` 引入 Session 格式 v3**（`SESSION_FORMAT_VERSION = 3`），将系统提示词迁入 surface。

**格式版本演进**：

- **v0**（`session.jsonl[.zstd]`）：原始格式，`assistant/chunk` 作为独立事件，`assistant/message` 通过 `sourceEventSeqs` 引用 chunk；
- **v1**（`session.v1.jsonl[.zstd]`）：恒等迁移，保留 v0 结构但为 v2 铺垫；
- **v2**（`session.v2.jsonl[.zstd]`）：移除 `assistant/chunk`，`assistant/message` 直接嵌入 `stream: AssistantStreamRecord[]`（紧凑带时间表示），新增 `assistant/attempt` 保留失败 attempt 的 stream；
- **v3**（`session.v3.jsonl[.zstd]`，`0.1.5-alpha.1`）：**系统提示词迁入 surface**——新增 `system/message` surface 事件，`request/header` 不再包含 `system` 字段；`surfaceOp` 从可选改为必填；`sourceEventSeqs` 从 `number[]` 改为 `SessionSeq[]`（品牌类型）；替换端点从 `start`/`end` 改为 `startSeq`/`endSeq`；PTC 子派发事件从 `tool/code-dispatch` 改名为 `tool/ptc-dispatch`。

**相邻迁移边（Adjacent Pure Edges）**：

- 迁移由静态 `@deepseek-ai/dsh-session-format-catalog` 编排，不依赖已挂载插件；
- 每条边 `vN → vN+1` 是独立纯包：`dsh-session-format-v0-to-v1`（恒等）、`dsh-session-format-v1-to-v2`（Assistant stream 嵌入 + 密集引用重映射）和 **`dsh-session-format-v2-to-v3`**（系统提示词迁入 + 规范信封）；
- `open` 存储 Session 时在返回句柄前组合完整迁移链，校验最终结果，排他发布最终具名版本后继（不覆盖源文件）；
- `stat` 和 `list` 仅处理 header，选择数值最高规范 generation 并在内存中转换历史 header，不加载事件正文。

**不可变发布与 generation 保留**：

- 规范文件名编码物理格式代际：v0 无版本后缀，v1+ 使用小写 `session.vN.jsonl[.zstd]`；
- 已提交 generation 路径绝不重命名、替换或删除；
- 运行时选择最高规范文件名，保留的低代际供 operator 检查或显式复制，但不作为自动 fallback；
- 只读文件系统报告可操作的迁移失败，不返回与磁盘不一致的内存视图。

**历史格式拒绝策略**：

- v0→v1 迁移边拒绝每个未知历史事件类型（包括标记 `ignorable: true` 的事件），因为不透明 payload 可能包含无法校验的引用；
- 当前 v2 恢复保留已安装扩展和携带 `ignorable: true` 的未知事件；
- 拒绝不会发布后继，源 generation 保持权威且不变。

这些变更在保持"模型可见即已记录"不变式的同时，将每次模型 attempt 的完整 stream 嵌入单个 settlement，消除冗余 chunk 事件并保留失败 attempt 的诊断信息。

## 10.12 turn 结束原因

`TurnEndReasonMap`（可扩展联合）：

```ts
type TurnEndReasonMap = {
  completed: { kind: 'completed' }
  aborted: { kind: 'aborted'; reason: TurnEndCancelCause }
  blocked: { kind: 'blocked' }
  error: { kind: 'error'; error: LlmFailure }
  'max-tokens': { kind: 'max-tokens' }
  interrupted: { kind: 'interrupted' }   // 仅崩溃恢复合成
}
```

`max-tokens` 是**粘滞**的：turn 内任何 step 触顶，整个 turn 记 `max-tokens` 而非 `completed`——消费者能区分"干净停止"与"被截断"。取消与错误保持独立结局。

## 10.13 小结

- 会话 = 追加型事件日志；模型历史从日志派生（surface），"模型可见即已记录"；
- `SessionEventMap` 可声明合并扩展；事件写入时深冻结 + 无损 JSON 校验；
- **v2 格式**：`assistant/message` 嵌入精确 stream，`assistant/attempt` 保留失败 attempt，移除 `assistant/chunk`；
- **v3 格式**（`0.1.5-alpha.1`）：系统提示词迁入 surface（`system/message` 事件），`request/header` 不再包含 `system` 字段，`surfaceOp` 必填，替换端点改为 `startSeq`/`endSeq`；
- surface 的 `replace` 是压缩机制；`replaceGeneration` 供增量消费者区分增长与重写；
- **格式迁移**：相邻纯边（v0→v1→v2→v3）在 `open` 时组合，排他发布最终版本；
- 持久化是插件接缝（`session/event` + `session/flush`）；
- `SessionStore` 的 prepare/enter/announce 分阶段生命周期支持有序拆卸与可否决发布。

下一章：Agent 循环——turn/step 状态机的实现。