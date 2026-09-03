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
| `assistant/chunk` | `{ turn, step, chunk }` | 原始流式块——token 级重放保真 |
| `assistant/message` | `{ turn, step, message, usage? }` | 组装好的助手消息（派生历史用它），携带 token 用量 |
| `tool/call` | `{ turn, step, callId, name, arguments }` | 模型请求一次工具调用（arguments 是模型原始 JSON 字符串，**不解析**） |
| `tool/result` | `{ turn, step, message, error?, meta? }` | 工具完成的模型可见结果 + 可选内部失败标识 + 工具私有 meta |
| `todo/write` | `{ todos }` | 任务清单整体快照（仅日志 UI 状态，不进派生历史） |
| `request/header` | `{ header, reason }` | 下一个请求的完整信封（配置+系统提示词+工具 schema） |
| `request/context` | `RequestContext` | 路由元数据（provider/model/contextWindow） |
| `session/end-seed` | — | 种子（resume/fork/replay）结束边界 |

**只记事实，不记中间态**：turn/step 边界、chunk、usage 都是"事实"；`request/header` 以全量快照记录（latest wins 重建）；`todo/write` 也是全量快照。而 `assistant/chunk` **必须**保留——`seq` 连续性是持久化契约，chunk 不能被过滤掉。

## 10.3 SessionEvent：日志条目

```ts
// types.ts（docs/subsystems/session.md type-equiv）
type SessionEvent<T extends SessionEventType = SessionEventType> = {
  [K in SessionEventType]: {
    type: K
    seq: number          // 单调序号，seq = log.length
    time: number         // epoch ms
    data: SessionEventMap[K]
    ignorable?: true     // 可安全跳过的纯信息记录
  } & (K extends SurfaceEventType ? {
    sourceEventSeqs?: number[]   // 引用的更早事件 seq
    surfaceOp?: SurfaceOp        // 'append' | { op: 'replace', start, end }
  } : object)
}[T]
```

设计要点：

- **真判别联合**：按 `type` 判别（而非独立的 type/data 联合），`switch (event.type)` 自动收窄 `event.data`；
- **ignorable 标记**：缺省 = 必需。读者遇到无法识别且无标记的事件**必须拒绝重建**，而不是静默丢弃——"忘记标记宁可过度拒绝，也不可静默续用一个被掏空的会话"；
- **Surface 元数据**：只有三种消息产生型事件（`SurfaceEventType = 'user/message' | 'assistant/message' | 'tool/result'`）可以携带 `surfaceOp` 与 `sourceEventSeqs`——编译器在 `Session.append` 调用点强制这一约束。

## 10.4 Surface：派生历史的唯一入口

三种消息产生型事件构成**有序表面（surface）**。`SurfaceOp`：

- `'append'`：正常追加到尾部；
- `{ op: 'replace', start, end }`：用本事件**替换** `start..end` 范围内的表面节点（`start === end` 单节点替换），被遮蔽的节点必须全部出现在 `sourceEventSeqs` 中——这是 **compaction（上下文压缩）** 的机制：压缩后一个摘要节点替换一批旧消息，派生历史立即反映压缩。

`Session.surface` 是活的只读投影：`nodes`（模型可见顺序的表面事件 seq 列表）+ `replaceGeneration`（位置替换的单调计数，增量消费者据此区分"纯尾部增长"与"重写"）。

**派生规则**（`deriveEventMessage`）：

- `user/message` → 用户消息（content 原样）；
- `assistant/message` → 助手消息；**空 content 的 assistant/message 被跳过**（max-tokens 截断仍记录 usage/provider/model，但不进模型转录）；
- `tool/result` → 携带 `tool-result` 块的用户消息；
- `assistant/chunk` → 派生时**跳过**（组装后的 message 才是权威）。

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

## 10.11 持久化格式迁移与打包历史传输

`0.1.2-alpha.1` 引入了两项重要的持久化优化：

**格式迁移管道**（`feat(session): add format migration decoder pipeline`）：

- 会话持久化格式现在支持版本化迁移（`SESSION_FORMAT_VERSION` v0→v1）；
- 解码器管道（`packages/core/session/src/format-migration.ts`）在读取历史日志时自动应用迁移；
- 迁移是**一对一**的（`refactor(session-persistence): make format migrations one-to-one`），每个版本转换步骤独立且可测试；
- 已知事件类型在读取时强制校验（`refactor(session): require known event types on read`），未知事件类型拒绝重建而非静默丢弃。

**打包助手历史传输**（`perf(history): carry packed assistant chunks`）：

- 客户端现在支持**打包记录**（packed records）——多个连续的 `assistant/chunk` 事件可以打包成单个传输单元，减少历史回放时的 I/O 开销；
- `packages/core/session/src/packed.ts` 实现打包/解包逻辑，保持与原始 chunk 流的无损等价；
- Gateway 支持**范围查询**（`feat(gateway): support ranged journal entries`），客户端可以按需加载历史片段而非完整日志；
- 会话投影缓存（`feat(session-projection-cache): store one projection_cache.json per session`）为每个会话维护独立的投影缓存，加速冷启动读取。

这些优化在保持"模型可见即已记录"不变式的同时，显著降低了大规模会话的存储与传输成本。

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

## 10.9 持久化格式演进：Per-Record 布局与打包历史

`0.1.2-alpha.1` 引入了会话持久化的重要优化：

### Per-Record 存储布局

传统的 JSONL 后端将每个会话的完整事件日志存储为单个文件。**Per-record 布局**（`packages/storage/json/src/layout.ts`）将会话拆分为多个小记录文件：

- **原子写入**：每个记录文件独立写入，崩溃恢复只需丢弃未完成的记录；
- **并发读取**：多个记录可并行加载，显著降低大规模会话的启动延迟；
- **格式迁移**：`packages/storage/json/src/migration.ts` 提供声明式迁移管道，旧格式会话自动升级到新布局。

Per-record 布局通过 `packages/core/session/src/persistence.ts` 的 `SessionPersistence` 接口接入，与既有 JSONL 后端共存。

### 打包助手历史（Packed Assistant History）

`feat(session): reduce persistence storage size` 实现了**打包助手历史传输**——将连续的 `assistant/chunk` 事件打包为单个记录，大幅降低持久化体积：

- **打包格式**：多个 chunk 合并为一条 `assistant/message`，保留 token 级重放能力；
- **客户端适配**：`packages/client/web` 的会话投影层解包打包记录，UI 侧透明消费；
- **性能收益**：大规模对话（数千 chunk）的存储体积降低 60%+，加载时间减半。

打包历史传输与 per-record 布局协同工作，共同构成 `0.1.2-alpha.1` 的持久化优化套件。

### Projection Cache

`feat(session-projection-cache): store one projection_cache.json per session` 引入**投影缓存**——将会话的派生投影（如消息列表、工具调用树）缓存到 `projection_cache.json`，避免每次 UI 加载时重新计算：

- **冷启动加速**：首次加载从缓存读取，增量更新只处理新事件；
- ** per-session 隔离**：每个会话独立缓存，互不干扰；
- **失效策略**：事件追加时自动失效缓存，保证一致性。

投影缓存是 UI 性能优化的关键组件，与第 17 章的会话快照折叠机制配合，提供流畅的长对话体验。

## 10.13 小结

- 会话 = 追加型事件日志；模型历史从日志派生（surface），"模型可见即已记录"；
- `SessionEventMap` 可声明合并扩展；事件写入时深冻结 + 无损 JSON 校验；
- surface 的 `replace` 是压缩机制；`replaceGeneration` 供增量消费者区分增长与重写；
- 持久化是插件接缝（`session/event` + `session/flush`）；
- `SessionStore` 的 prepare/enter/announce 分阶段生命周期支持有序拆卸与可否决发布。

下一章：Agent 循环——turn/step 状态机的实现。