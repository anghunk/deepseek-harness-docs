# 第 2 章 仓库全景

## 2.1 Monorepo 概览

deepseek-harness 是一个 pnpm workspace monorepo（`packageManager: pnpm@11.7.0`）。仓库顶层布局：

```
deepseek-harness/
├── apps/            # 应用：cli（命令行）、web（前端外壳）
├── packages/        # 全部业务包（约 60+ 个），按领域分组
├── vendor/          # 内嵌的第三方框架源码（cordis、cosmokit、loader、schemastery 等）
├── docs/            # 官方文档（架构、子系统、cookbook、用户指南，多语言）
├── examples/        # 可运行示例（web-cordis、headless-agent、mcp-memory、acp-agent、web-schedule）
├── scripts/         # 构建/校验/生成脚本（tsx 编写，150+ 个）
├── website/         # 官方文档站点（VitePress）
├── native/          # 原生模块
├── python/          # Python SDK 相关
├── assets/          # 静态资源
└── config/          # 部署配置与随附 agent-presets（位于 apps/cli/config）
```

根 `package.json`（`@deepseek-ai/dsh-root`）定义了两大类脚本：

- **构建**：`build:lib:host`（`tsc -b tsconfig.host.json && tsdown --env.DSH_BUILD_FACE host`）、`build:lib:client`、`build:web`；
- **校验**：`typecheck`、`lint`、`test`、`test:e2e`、`hygiene`（knip/publint/constraints 等）、`doc-sync` 等，统由 `scripts/run-gates.ts` 编排成 CI 门禁。

## 2.2 Host / Client 双聚合构建

仓库采用**隔离的 Host 与 Client 两个 TypeScript 聚合**（`docs/development.md`）：

| 文件 | 作用 |
| --- | --- |
| `tsconfig.host.json` | Host 聚合：Host 包、examples、tests、scripts、website |
| `tsconfig.client.json` | Client 聚合：`packages/client/*`、`apps/web`、`api/remotes` 的 Client 半边 |
| `tsconfig.base.json` | 共享编译选项与 `paths` 源码映射（**不**含 `include`，作为解析门面） |
| `tsconfig.base.client.json` | 浏览器编译设置（jsx、DOM libs） |

为什么必须分成两个程序？因为 Host 与 Client **在同一 `Context` 接口上声明合并了不同的服务**——两边在同一个 key 下合并出不同服务会让单个 `ts.Program` 报冲突。`docs/development.md` 明确写道：

> Host and Client stay two aggregate programs because both sides declaration-merge the cordis `Context` interface under the same keys with different services; one program seeing both merges reports a collision.

这条约束派生出一系列纪律：新包必须且只能注册进一个聚合；脚本构建全仓库 `ts.Program` 时必须显式指定某个聚合；`api/remotes` 是唯一拆分的包（Host 入口参与 Typert 图，Client 入口消费生成的 `/remote` 声明）。

完整构建顺序（`docs/development.md`）：

```sh
tsc -b tsconfig.host.json
tsdown --env.DSH_BUILD_FACE host      # Host 侧打包；Typert 只在这一步运行
tsc -b tsconfig.client.json
tsdown --env.DSH_BUILD_FACE client    # Client 侧打包（浏览器 bundle + Node loader）
pnpm run build:web
```

**Typert**（`packages/typert`）是仓库自研的类型反射工具：在 Host tsdown 阶段分析 Host 类型，生成两种产物——Host 自身反射目录（供 `ctx.remote` 运行时使用）与 **Host-for-Client Remote 投影**（供浏览器端类型化调用 Host）。这部分对应 `docs/api-gateway.md`，我们会在第 17 章详述。

## 2.3 包矩阵

`packages/` 下按领域分组的包（写作时快照）：

| 分组 | 包 | 职责 |
| --- | --- | --- |
| `core/` | session、tools、agent、agent-loop、agent-default-model、agent-tool-presentation、system-prompt、scope | 事件溯源会话日志、工具注册表、Agent 接口、默认驱动、提示词组装、作用域原语 |
| `llm/` | llm、llm-deepseek、llm-pi-ai、llm-retry、token-meter | 消息/流式词汇、适配器接缝、具体适配器、重试策略 |
| `boot/` | app-boot、cmdline、profile | 启动组装、命令行服务 |
| `bundle/` | base、web-app、headless | 三种内置组合（Bundle） |
| `host/` | webserver、frontend-static、plugin-inventory、apiproxy、directory-picker-* | 宿主进程侧的 Web 服务与浏览器资源托管 |
| `client/` | runtime、connection、modules、web、web-react、locale、schema-form、ui-*（30+ 个 UI 包） | 浏览器运行时与全部 UI |
| `fs/` | fs、fs-local、fs-observation-policy、fs-sandbox、tool-fs、tool-fs-search、tool-str-replace-editor | 文件系统接缝三件套与工具 |
| `sandbox/`、`subprocess/`、`terminal/`、`shell/`、`jobs/` | 沙箱、子进程、终端、shell、后台作业接缝 |
| `skill/` | skill、skill-badge、skill-filesystem、tool-skill | 技能系统 |
| `goal/` | goal、command-goal、tool-goal、goal-round-driver | 目标系统 |
| `subagent/` | subagent、subagent-acp、subagent-claude-code 等 | 子代理接缝与多后端 |
| `preset/` | agent-presets | 代理预设（per-agent 能力组合） |
| `session/` | session-query、session-projection、session-reference、session-title、session-telemetry | 会话查询/投影/标题/遥测 |
| `api/` | remotes | Host↔Client 类型化 RPC |
| `experimental/` | webworker-runtime、webworker-packer | 浏览器 worker 运行时与 VFS 镜像打包器 |
| `inspector/` | inspector | Cordis 检查器（通过 CDP 暴露 Cordis 树） |
| `team/` | team | Agent Teams（实验性 CLI 和 Web profile） |
| `webhook/` | webhook、webhook-github | Webhook 集成（GitHub 事件处理） |
| 其他 | acp、attachment、code-runtime、compaction、context、credentials、deepseek（session log upload）、feedback、guard、hooks、identity、interaction、lsp、mcp、plan、runtime-diagnostics、sdk、schedule、settings、spill、storage、todo、typert、util/*、web、workflow、workspace、extensions/*、test-support | 各自领域能力 |

包之间以 `peerDependencies` 表达运行时依赖；`docs/module-graph.md` 用 mermaid 生成了完整的包级依赖图（由 `scripts/gen-module-graph.ts` 维护，构建期有 `verify-module-graph` 门禁）。

## 2.4 文档体系

`docs/` 是仓库中极其重要的资产，它本身构成一份高质量的架构文档集：

- `architecture.md`（+ `.zh.md`）：总架构，阅读任何 `packages/` 代码前的必读；
- `cordis-primer.md` / `cordis-tutorial/`：Cordis 入门与教程；
- `subsystems/*.md`：每个子系统的深度文档，内含 **type-equiv** 代码块（从源码逐字抽取的类型声明 + JSDoc，由 `verify-type-equiv` 门禁保证与源码同步）；
- `cookbook/`：扩展 cookbook（加包、加工具、加 LLM 适配器、加对话节点）；
- `config-catalog.md`：生成的配置目录（composition 行字段大全）；
- `event-producer-consumer.md`、`tool-catalog.md`、`persistence-catalog.md`：生成的事件/工具/持久化目录；
- `agent-lifecycle.md`、`tool-execution-pipeline.md`：时序图与管道说明；
- `api-gateway.md`、`capability-seams.md`、`glossary.md`、`defensive-patterns.md` 等。

这些文档大多有官方中文版（`.zh.md`），与源码通过 `doc-sync` 门禁保持同步，是本书写作的重要一手依据。本书尽量**独立**从源码出发做解析，官方文档用于交叉验证。

## 2.5 代码规约与工程实践

几个值得注意的工程纪律（源码中处处体现）：

1. **三个 TODO 标记的急迫性分级**：`FIXME`（应阻塞发布）> `TODO`（应尽快修复）> `XXX`（可能某天修复）；
2. **品牌化 ID（Branded ID）**：跨包传递的 ID（`SessionId`、`CallId`、`JobId`）在类型层面不可互换，见 `packages/util/brand`；
3. **`Map → 派生联合`模式**：几乎每个可扩展联合类型都写成 `interface XxxMap` + `keyof` 派生，插件通过 **declaration merging** 扩展，无需改动源码包；
4. **不可变与冻结**：会话事件在写入时深冻结（deep-freeze），保证日志不可被篡改；
5. **i18n 配对**：中英文档通过 `.i18n.yaml` 配对 + Git merge driver 自动同步；
6. **Agent Notes**：`.agents/notes/` 存放按分类归档的设计决策笔记（implemented/architecture、bug-fix、simplification 等），是理解"为什么"的一手资料。

## 2.6 测试与 CI

- 单元/集成：`vitest`（`vitest.config.ts`），覆盖到几乎所有包；
- Web 测试：`vitest.web.config.ts`（基于构建产物）；
- 快照测试：`DSH_SNAPSHOT=record|refresh|replay` 三种模式；
- e2e：真实 API 测试（未设置 `DEEPSEEK_API_KEY` 时自跳过）；
- CI：`.github/workflows/ci.yml` 将门禁分组到宽车道，由 `scripts/run-gates.ts` 驱动；Node 兼容矩阵覆盖 22.19 / 24 / 26；
- Windows：`check:windows-*` 系列门禁（含 Wine 方案）。

下一章进入总架构：理解"一切皆插件"如何在 Cordis 上成立。
