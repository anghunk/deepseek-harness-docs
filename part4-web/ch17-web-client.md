# 第 17 章 Web 客户端与 UI 架构

本章解析浏览器端：从页面加载、客户端 Cordis 运行时启动，到连接 Host、Slot 系统、主题 token 与类型化 RPC。核心包：`apps/web`、`packages/client/*`、`packages/host/*`、`packages/api/remotes`。

## 17.1 页面加载：apps/web 只是薄壳

`apps/web` 不是独立应用：

- `index.html` 只有 `<div id="root">` 与 `<script src="/src/main.ts">`；`main.ts` 只调用 `new AppWebEntry(el).run()`（注释：Everything lives in `@deepseek-ai/dsh-client-web`; this file only finds the mount point）；
- `vite.config.ts` 的 `rejectStandaloneServe` 插件在 `vite dev/preview` 直接抛错——**bare Vite 无法注入 `window.__DSH_BOOT__`**，只有 `dsh web`（web profile）会在 HTML 里注入 boot 清单。这正是本书环境说明里"不要另起炉灶跑替代服务器"的原因：页面必须由 dsh web 宿主注入。

Vite 构建把 shell 源码**别名打进 bundle**（`@deepseek-ai/dsh-client-web` → `packages/client/web/src/boot.tsx`），但**插件包从不在此打包**——插件 bundle 运行时经客户端模块系统（fetch）到达。`define` 把 vendored Loader 里的 Node-only 探测替换掉（`process.versions.node: '0.0.0'`、`node:module` → stub）——客户端 loader 浏览器化的关键。

## 17.2 启动协议：window.__DSH_BOOT__

宿主把"客户端插件入口图"注入页面首屏 `<head>`（`packages/client/modules/src/index.ts` 的 `injectBootManifest`）：`window.__DSH_BOOT__ = JSON` 作为第一个 script；**`<` 转义为 `\u003c`**——插件可控字符串不能逃出 script 元素。

```ts
interface WebBootEntry {
  id: string          // 入口名 == 包名
  url: string         // '/plugins/<id>/client.js?rev=<rev>'
  rev: string         // bundle 内容 hash（缓存一致性锚）
  inject?: string[]   // 依赖边（信息性）
  immediately?: boolean // 阶段一预取标记
}
```

清单缺失/畸形直接 loud throw——没有合法清单就什么都引导不起来。

## 17.3 运行时启动：两阶段引导

`boot.tsx` 的 `AppWebEntry.run()`：

1. **模块面（module face）**：解析 `__DSH_BOOT__` 建 `ClientModuleSystem`（lazy-CJS 模块表，Node ESM loader 的浏览器对应物），注册 shell 自有模块（`app-shell` 等），预取所有 `immediately` 行；
2. **插件面（plugin face）**：`new Context()` → `ctx.plugin(Loader)`，**先注入 `loader.internal = modules`**（模块系统挂到 Loader 上，否则 bundle import 在浏览器必炸）→ 并行 `loader.create({name})` 装载全部插件行 + `app-shell` → `await loader.await()`；
3. **启动审计**：sweep 每个 entry——无 fiber = import 失败；pending = 等某个服务没等到（cordis inject 等待无超时，这个 sweep 是 fail-loud 补偿）；
4. 全部 active → AppRoot 一次性从 loading 页切到真实 UI。

设计亮点：**shell 自足**——loading 页在插件全部失败时也必须能工作（fail-loud 呈现不依赖它报告失败的那个系统）。

## 17.4 客户端插件形态

`package.json` 的 `dsh.client` 字段声明客户端插件：

```jsonc
"dsh": { "client": { "inject": ["@deepseek-ai/dsh-client-runtime", ...], "platform": "web" } }
```

- `platform` 必须 `'web'`；`inject` 是依赖边；`immediately` 标记阶段一预取（`runtime` 就声明了 `immediately: true`）；
- Host 半 `parseDshClient` 要求 `exports["./client"]` 指向构建出的 bundle；
- **增量扫描**：`ClientModuleRegistry` 订阅 `internal/plugin`，fiber 构造/销毁标记 entry dirty，微任务批量处理——稳态一个坏包只 warning 不拖垮别人；
- **bundle 路由**：`GET /plugins/<id>/client.js?rev=<rev>`，`no-cache`（缓存一致性靠 rev query 而非 HTTP 缓存）。

### 客户端模块系统

执行插件 bundle 只**注册 factory**（`window.__ModuleLoader__.load({ id, factory })`），bundle body 副作用（含 CSS 注入）在 factory 闭包内、materialization 时才跑。`require` 走注册表查找，**无 load 分支**（跨插件 value import 是构建错误）；`seed.ts` 用 `satisfies` 把 `PLATFORM_MODULES`（react/cordis/ui-slots/ui-primitives/ui-renderer/ui-attachment/schema-form）钉死——漏一个静态 import 编译即失败。

## 17.5 连接 Host：双向异质通道

连接**不是**单 WebSocket 流，而是双向异质：

- **上行（浏览器→Host）= HTTP POST RPC**：`fetch POST /api/<endpoint>`，body `{ type: 'client-request', rpcId, method, payload }`；
- **下行（Host→浏览器）= 两个只读 WebSocket**：`/api/events.mux`（多路复用流）与 `/api/events.host`（host 流）。**客户端在 WS 上发消息是协议违规**——服务端直接 `close(1008, 'downlink only')`；
- **连接循环**：`ConnectionController` 每代实例私有，并行 pump 两条流，严格握手（unary describe 证明单发可达 + onOpen 证明物理流建立），失败指数退避（500ms 起 ×2，上限 10s）；
- **信任模型**：`isTrustedApiRequest` + `trustedHosts` 是 **DNS-rebinding fence 而非认证**；`PRIVILEGED_METHODS` 把 settings/credentials/pickDirectory/llm.discoverModels 等钉死为 loopback-only。

## 17.6 类型化 RPC：@Remote 与 Gateway

三层包：`typert/protocol`（声明+修饰器，零运行时反射副作用）、`typert/generator`（TS 项目分析 → `InvocationDescriptor` 生成物）、`api/remotes`（装配）。

- `@Remote` 标记 Host 公开实例方法；`@RemoteScope(key)` 按 merge 声明的 scoped Context kind 选接收者；`TypertRemoteService` 把 `super(ctx, serviceKey)` 绑成默认 namespace；
- 例证（`packages/host/plugin-inventory`）：`class PluginInventoryGateway extends TypertRemoteService`，`@Remote('list') list()` 返回插件清单快照——Host 侧零缓存 Remote-only 服务，每次直接读 Loader；
- `InvocationDescriptor` 是两侧共享的运行时形式：service/namespace/method/invocation（direct|context）/有序 parameters（codec：strict Zod schema 或 src-json）；参数可以是 `lookup`（Host 对象 ↔ wire id，需注册 resolver）或 `json`；`cancellation` 把 `AbortSignal` 参数标记为保留注入点（不进 wire args）；
- Host Gateway `ctx.typertGateway` 在 `/api` 分派到 `<namespace>/<method>`；Client 侧 `ctx.remote.<namespace>.<method>` 调用、`ctx.remote.$on` 订阅转发事件（事件 allowlist 在 `api/remotes/src/remote-events.ts`）。

## 17.7 Slot 系统

三层解耦：纯核心 `ui-slots`（零运行时依赖）→ Service 层 `ctx.slots`（`runtime/src/client/slots.ts`）→ 渲染器 `ui-renderer`（`packages/client/ui-renderer`）。

### 注册协议

- `ctx.slots.register(options, component)`：options 声明 `children`（否则报 "slot not declared"）、kind（`single | list | keyed | chain`）、scope（`root | session-maybe | session`）；
- **声明即认领**：一个 slot 只允许一个父入口 declare；重复 declare loud throw；
- **shadowing**：single 整槽一格、keyed 按 key 一格、list 按 id 一格；每格取最低 priority 的存活 entry（tie 保持注册序）；同格同 priority 二次注册 throws；chain 不 shadow（election 消费所有 entry）；
- **失败隔离**：single/keyed/list 的 entry 崩溃经 "abdicate" 退位让位下一个存活者（one-shot）；chain 崩溃不退位（select 时再找替代）；
- **生命周期**：disposer 移除贡献并递归 collapse 声明的子 slot；`slots.inject` 等待 slot 声明生命周期（声明已存在 → 同步跑回调，否则声明提交后跑，collapse 时 dispose）；
- **inject 面**：`inject: (...args) => Record<string, unknown>` 为注册者业务面；业务数据走 apply 闭包 ctx，不存在 binding 对象参数。

**keyed slot 的典型用例**：设置页「插件」分区的 `configurable` 标签页声明 `settings.plugin.item`（`{ kind: 'keyed', scope: 'root' }`），**键 = 卡片所编辑的 settings 命名空间**（声明 `key` 而非 `id`/`order`）。`0.1.0-rc.7` 起 api-proxy **服务每一个已注册命名空间**（不再有 `WEB_SETTINGS_NAMESPACES`/`PRODUCT_SETTINGS_NAMESPACES` 白名单），标签页以 `settings.describe` 返回的命名空间驱动派发——渲染结果是"存活 Host 插件注册的命名空间 × 注册在这些键上的卡片"两份账本的交集，缺席即无卡片。插件作者在 Host 注册命名空间 + 在浏览器把卡片注册在该键上，仓库外分发的插件也能出现在设置页（第 19 章 19.4 有注册示例）。右侧 Sidebar 的 tab 体坑位 `sidebar.right.pane.tab` 是 keyed slot 的另一个典型用例——键 = tab 类型 `id`，每类 tab（引导页、文本预览、文件树）把自己的体注册进坑位，由注册表按地址/档位认领——详见 17.20 节。

### 作用域标准 props

框架注入的标准 props 由多个包声明合并合成：

- `SessionStandardProps`（strict session scope）：`useSession`、`sessionId`、`useProjection`；
- `SessionMaybeStandardProps`（session-maybe）：可空变体；
- `GlobalStandardProps`（所有 slot）：`useSessions`、`useWorkspaces`。

每个 `use<Name>` 钩子由 `bindSnapshotSelector`（`use-sync-external-store/with-selector`）构造——**这是客户端栈里唯一的 hook 构造点**：引擎与 host 只流动 bare observable 源，绑定发生在 React 侧。会话子树在 `SessionProvider` 里按 `key={sessionId}` remount。

### 主题 token 系统

- `--dsw-*` token；override 层要求 **`{light, dark}` 成对**（单值在另一个色板下不可读）；
- `ThemeRuntime`：`getTheme()` 返回不可变快照；`setTheme()` 是唯一偏好写入口；`register()` 注册第三主题；`overrideTokens(source, tokens)` 是 token 级 shadowing（后层胜出，同一 source 再调替换整层并置顶，返回精确层 disposer）；
- **首屏防闪烁**：`injectBootTheme` 在 `<body>` 后插内联脚本（只解析 `system` 与 matchMedia，写 `colorScheme` 与 `data-ds-dark-theme`）——插件装载前的空隙期也有正确主题；
- 呈现层职责分离：ui-theme **从不碰 DOM**，ui-layout 的 ThemePresenter 消费快照落到 DOM；
- `exportInspectTokens()` 导出 inspect 目录——这是动态 Cordis `Theme.listTokens` inspect provider 的数据源。

## 17.8 会话快照：事件流折叠

`SessionRuntime` 用 mintScope 模式为每会话建作用域（agent id == session id）；`list` / `currentProvideInfo` 两条 HostObservable 经 `bindSnapshotSelector` 绑成 `use<Name>` 钩子；事件流（`session/event` 下行）经 **`ConversationNodeAssembler`** 折叠成 `ConversationSnapshot` 提供给 UI——UI 永远渲染"从日志折叠出的快照"，而不是直接操作活对象（数据最小化原则）。

## 17.9 Host 侧服务

- `packages/host/webserver`：`ctx.webServer`——HTTP 服务、`tapIndex`（注入 boot manifest 与首屏主题脚本的 transform 钩子）；
- `frontend-static`：托管构建出的 web 资源；
- `plugin-inventory`：`@Remote('list')` 插件清单服务（上面例证）。

## 17.10 web profile 组成

`packages/bundle/web-app` 把 base bundle + webserver + client modules + UI 组件包等行组合成 web profile。第 8 章的启动链路在 Host 侧完成装载后，Host 启动 webServer，浏览器访问 3080 → 页面加载 → boot 清单 → 客户端运行时 → 连接 Host——一条完整的链路。

## 17.11 浏览器 Worker 运行时（webworker）

`packages/experimental/webworker-runtime` 与 `packages/experimental/webworker-packer` 引入了**浏览器 worker 运行时**——在浏览器 worker 线程中运行完整的 dsh 宿主环境，配合 VFS（虚拟文件系统）镜像打包器，实现零安装的浏览器端 Agent 体验。

Webworker 运行时的核心架构：

- **VFS 镜像**：`webworker-packer` 把 Host 端的文件系统状态打包成镜像，通过 `postMessage` 传输到 worker；
- **Node 兼容性层**：worker 内部提供 `createRequire`、`process` 身份、`node:module` 等 Node API 的浏览器实现；
- **模块系统**：复用客户端的 `ClientModuleSystem`，在 worker 中装载插件 bundle；
- **预览系统**：支持可选择的预览 fixture，`packages/experimental/webworker-packer/src/fixture-manifest.ts` 管理示例种子。

Webworker 运行时目前仍处于实验阶段（`packages/experimental/`），主要用于开发与演示场景，生产部署仍以 Node Host 为主。

## 17.12 Cordis Inspector（CDP 集成）

`packages/inspector/` 提供 **Cordis Inspector**——通过 Chrome DevTools Protocol (CDP) 暴露 Cordis 插件树，允许开发者在浏览器 DevTools 中检查和调试运行时的插件状态。

Inspector 的关键特性：

- **CDP DOM 投影**：`feat(inspector): expose Cordis trees through CDP DOM` 把 Cordis 插件树映射为 DOM 节点，DevTools Elements 面板可直接浏览；
- **CDP Network 代理**：`feat(inspector): project Host fetches through CDP Network` 把 Host 的 fetch 请求投影到 DevTools Network 面板；
- **CDP Worker 服务**：`feat(inspector): serve Runtime through a CDP Worker` 通过 CDP Worker 提供运行时检查接口；
- **开发挂载覆盖层**：`feat(inspector): add the development mount overlay and demo script` 支持开发环境的动态挂载与演示脚本。

Inspector 是开发工具，不参与生产部署，但为理解 Cordis 运行时状态提供了强大的可视化能力。

## 17.13 词法 Composer（lexical composer）

`packages/client/ui-conversation` 的输入框从 textarea 栈迁移到**词法编辑器（lexical editor）**，这是 `0.1.2-alpha.1` 的重要 UI 重构：

- **词法节点**：输入框内容建模为词法节点树（`lexical chip node, projections, span map`），支持结构化引用（文件、会话、@mention）的内联渲染与编辑；
- **编辑范围携带**：每次编辑自带作用范围（`Composer edits carry the range they applied to`），避免引用降级为字面文本；
- **滚动共享**：两层文本（输入层与预览层）共用同一个滚动容器（`The composer's two text layers share one scrollport`）；
- **Safari 兼容**：修复 Safari textarea 软换行收缩恢复问题（`Safari textarea soft-wrap shrink recovery`）。

词法 Composer 为后续的结构化输入（如多模态引用、内联工具调用）奠定了基础。

## 17.14 Streaming Fence 高亮

`feat(client): highlight streaming fences incrementally` 实现了**流式栅栏增量高亮**——当模型响应被多个工具调用分隔时，每个栅栏（fence）在流式输出过程中逐步高亮，而非等待完整响应后一次性渲染。

Streaming fence 高亮与 Turn rail（`feat(web): navigate loaded Chat Turns from a compact rail`）配合，提供长对话的导航与可视化能力。

## 17.15 浏览器认证与 WebSocket 安全

`0.1.2-alpha.1` 强化了浏览器端的认证机制：

- **签名浏览器 Cookie**：WebSocket upgrade 前先执行 `/api` Host/Origin 校验，再执行与一元 HTTP 相同的签名浏览器 cookie 认证（`signed browser-cookie authentication`）；
- **认证状态码**：未受信任的 authority 或跨来源 Origin 得到 403；Host 可信但未认证的请求得到 401；两者都不会启动 Remote stream；
- **Fetch 认证栅栏**：`refactor(web): remove fetch approval policy` 移除了旧的 fetch 审批策略，统一通过认证契约控制。

这些变更确保浏览器端的 Host 访问与 WebSocket 连接遵循一致的安全模型。


## 17.16 UI 性能优化套件（0.1.2-alpha.2 ~ 0.1.2-alpha.5）

`0.1.2-alpha.2` 到 `0.1.2-alpha.5` 期间，Web 客户端经历了大规模的性能优化：

### 流式传输优化

- `perf(conversation): publish streaming updates every two frames` → `perf(conversation): publish streaming updates every three frames`：流式更新节流从每 2 帧调整为每 3 帧发布一次，平衡实时性与渲染开销；
- `perf(chat): throttle scroll geometry sampling`：限制滚动几何采样的频率，避免频繁重排触发；
- `perf(chat): skip stable node list mapping`：跳过稳定节点列表的映射，减少不必要的 DOM 操作；
- `perf(web): defer tool body formatting until expansion`：工具体的格式化延迟到展开时——折叠态不付出格式化代价。

### 客户端投影优化

- `perf(client): materialize conversation targets on demand`：会话目标按需物化（非预计算）；
- `perf(client): linearize inbox projection state`：收件箱投影状态线性化，避免嵌套 observable 的连锁更新；
- `refactor(client): bind keyed chat sources in renderer`：在渲染器中绑定键控聊天源；
- `refactor(client): share conversation context initialization`：共享会话上下文初始化逻辑。

### UI 渲染优化

- `perf(ui-chat): contain collapsed reasoning layout`：约束折叠推理的布局范围；
- `perf(ui-chat): retain the stats resize observer`：保留统计尺寸观察器避免重复创建；
- `perf(ui-chat): derive user action reveal in CSS`：将用户操作揭示逻辑移到纯 CSS 实现；
- `perf(ui-chat): scope turn process updates`：限定 turn 进程更新的作用域；
- `perf(ui-chat): move reasoning tail alignment to CSS`：推理尾部对齐移到 CSS；
- `perf(ui-deliverables): move overflow sizing to CSS`：溢出尺寸计算移到 CSS；
- `perf(trajectory): page resident history before rendering`：在渲染前对常驻历史进行分页。

### 其它 UI 改进

- `feat(web): superellipse corners and hairline elevation strokes`：超椭圆圆角与发丝线海拔描边；
- `feat(web): deepen composer stroke to l2, widen menu radii to 20px`：加深 composer 描边到 L2，菜单圆角加宽到 20px；
- `fix(web): per-element elevation tokens and review sync`：按元素的海拔 token 同步审查。

这些优化将长对话、大量工具调用的场景下的 UI 延迟降低了显著幅度。

## 17.17 网络代理路由（0.1.2-alpha.4 ~ 0.1.2-rc.1）

`0.1.2-alpha.4` 起引入了统一的**出站网络代理路由**：

**代理工具库**：

- `refactor(net): make the proxy a util library with six functions` → `refactor(http-proxy): converge the proxy API on four functions`：网络代理从插件重构为工具库（`packages/util/http-proxy`），API 收敛到四个核心函数；
- `feat(net): route every outbound request through the configured proxy`：所有出站请求（LLM、搜索、抓取）统一经过配置的代理；
- 代理策略支持分层（`fix(http-proxy): give children the user's environment under a layered direct policy`）——子进程在分层直接策略下继承用户的环境。

**环境代理合约**：

- `fix(app-boot): accept the proxy names from the Harness-home .env alone`：`app-boot` 只接受 Harness 主目录 `.env` 中的代理名称；
- `fix(http-proxy): withhold NODE_USE_ENV_PROXY when the child receives a refused proxy value`：当子进程收到被拒绝的代理值时，不设置 `NODE_USE_ENV_PROXY`；
- `fix(http-proxy): match the workspace version to the 0.1.2-rc.1 release`：工作区版本与 0.1.2-rc.1 发布版对齐。

**Worker 代理支持**：

- `fix(webworker): register a node:https placeholder for the proxy agent factory`：为代理工厂注册 `node:https` 占位符，确保 WebWorker 中的出站请求也能走代理；
- `test(net): assert the child and worker proxy seam by Node version`：按 Node 版本测试子进程与 Worker 的代理接缝。

代理路由是零配置的：用户在 `~/.dsh/settings.yaml` 或 `.env` 中设置 `HTTPS_PROXY`/ `HTTP_PROXY` 即可，所有出站请求自动走代理。

## 17.18 客户端资源模型（Client resources）

`packages/client/resources` 给"客户端读某个有名东西"建立了统一抽象。每个资源有一个**地址**（`dsh-resource://<protocol>/<path>`）与一个**当前值**；`useResource<T>(address)` 是从提供者读取该值的标准 hook——多个观察者共享同一份订阅，最末一个观察者退订时 provider 才释放。地址是身份，订阅是状态，体（组件）与订阅解耦。

**文件资源地址**（`dsh-resource://file/...`，由 `packages/util/workspace-path` 定义）：

- **`session` 作用域**：`dsh-resource://file/session/<sessionId>/<相对该会话工作区根的百分号编码路径>`——同一个相对路径在不同会话下是两个不同文件；
- **`absolute` 作用域**：`dsh-resource://file/absolute/<绝对路径>`——只在地址本身不命名会话时使用。

`fileAddressFor(sessionId, root, absolutePath)` / `parseFileAddress(address)` 是两侧共享的构造与解析助手。`file` 资源的值（`{ absolutePath, version, bytes, changed }`）只携带**元数据**与 `changed` 通知——载荷（文件内容）另有专门的按页读取通道（见 17.20），因为内容可能任意大，不能进订阅流。

资源注册表（`ctx.resources`）按地址分桶管理订阅；`useResource` 在 React 侧消费，与 17.7 中 `bindSnapshotSelector` 的"bare observable → React hook"模式一致。

## 17.19 工作区文件服务（Workspace Files）

`packages/api/workspace-files` 把 Host 侧的文件操作拆成两个 Remote 面暴露给客户端：

- **元数据面**：`stat`（文件元信息）、`list`（目录条目，带 `entries` 与 `truncated` 标记）、`changes`（Host 推送的文件变更流）；
- **内容面**：`read(sessionId, path, { offset }, signal)`——一次读一页行，不传 `limit`，因此页长 = Host 配置的上限（`maxLines`，默认 5000 行；单页还受 `maxBytes`，默认 2 MB 封顶）。

Host 在解析 `session` 地址时以**该会话**的工作区根解析相对路径，`absolute` 地址按字面读。`list` 拒绝会话工作区根之外的路径，因此客户端能列的目录就是它显示的目录；越界请求得到 `workspace-file/outside-workspace`。

**有界字节窗口**（`f7b6a1332` / `bc2174e3a` / `442976344`）：底层 FS 层提供按字节范围的读取，本地实现（`fs-local`）与沙箱实现（`fs-e2b`，支持取消）共享同一合约——单次请求永远有上界，客户端的页读取消费这一层。这是"内容不进资源流"决策的实现基础：`changed` 是通知，`read` 才拉载荷。

**失败码到用户句的映射**（消费方在 `ui-sidebar-textpreview` 的 `failure-line.ts` 与 `ui-sidebar-files` 内）：`workspace-file/not-found`、`workspace-file/outside-workspace`、`workspace-file/too-large`、`workspace-file/not-text`、`workspace-file/not-regular-file`、`workspace-file/not-directory`——未识别码落到通用句 `读取失败：{message}`。

## 17.20 右侧 Sidebar 与停靠系统

右侧 Sidebar 是 Web 客户端的**第三列**（左：会话列表，中：对话，右：Sidebar，参见 17.18 设计亮点）。它承载可停靠的 tab pane，提供"会话进行中随时看得见的文件与产物视图"。

### 停靠基础设施（dockkit）

`packages/client/ui-dockkit` 是可逆的停靠引擎，提供：pane 的 drag/split/fullscreen、pointer 交互、布局持久化（按 session 记）、根 pane 为空时重新播种默认内容。`packages/client/ui-layout` 把 dockkit 装进应用的 grid 框架——右列作为第三列响应视口宽度：

- **normal**：右列按用户偏好宽度展开在对话旁；
- **fullscreen**：小视口（`≤ 767px`）自动进入，右列覆盖整个视口；
- **capacity-close**：当左列偏好宽度把右列挤到零，右列自动关闭，保留左列宽度偏好。

每会话保存"打开/关闭 + 模式 + pane 布局"，页面加载恢复。会话 Header 右上角新增 corner slot（`490955078`），随包交付的 Sidebar 切换按钮住在里面——切换按钮随会话拥有，用户在任何会话状态下都能打开 Sidebar。

### Tab 类型注册表

Sidebar 显示内容由 **tab 类型注册表**（`ctx.sidebarRightTabs`）决定。每个类型是一个静态定义：`{ id, kind, patterns?, priority, title, guide? }`。注册表按地址 `patterns` 做档位认领——

- **`extension`**：扩展声明的窄 pattern（如 `*.png`）；
- **`builtin`**：随包类型（引导页、文件树）；
- **`fallback`**：最低档，随包 `text` 类型以 `dsh-resource://file/**` 兜底所有文件。

体通过 keyed slot `sidebar.right.pane.tab`（键 = 定义的 `id`）注册——这正是 17.7 keyed slot 的典型用例的另一个实例：键命名类型也命名画它的组件，注册返回 disposer 并经 `ctx.effect` 绑定到插件寿命。

### 三个随包交付的 tab 类型

**引导页**（`ui-sidebar-right`，kind=`guide`，priority=`builtin`，无 `patterns`）：pane 在承载内容之前显示的门。按 kind 打开、记在内部页地址 `sidebar://guide`。体是一组入口框栅格，按 `order` 来自每个已注册类型的 `guide[]` 投影，因此后注册的类型不用引导页知道就能出现；点击入口以 `tabActions.openTab(kind, { replaceTab: true })` 打开被选类型并让引导页自己消失——引导页是门，不是留在被打开者旁边的一页。体同时是替换接缝，渲染 `sidebar.right.tab.guide` 链并**以随包引导页作 fallback**，于是产品接管整个体而没有入口时仍能画。

**文本预览**（`ui-sidebar-textpreview`，kind=`text`，patterns=`['dsh-resource://file/**']`，priority=`fallback`）：每个文件的兜底查看器。地址的最后一段作 tab 标题（不同目录同名文件仍是两个 tab）；体经 `useResource<'file'>` 读元数据，经 `remote.workspaceFiles.read` **按页**读内容——首次挂载读第 1 页，**加载更多**按钮按顺序补页到 `eof`。store 是 Slot 独占标准件、按 tab 分桶（同一文件的两个 tab 各自滚动），跨 tab 切换与重新挂载存活。文件被 agent 改过（资源报 `changed`）只提示不刷新，点击重新载入才丢页重读第 1 页，**滚动位置保留**；导航 `line` 参数在页不够时按顺序补到覆盖为止，没有 seek。体的头部显示完整路径（悬停 tooltip）、换行开关（默认开，按 tab 记）与重读按钮。

**文件树**（`ui-sidebar-files`，kind=`files`，priority=`builtin`，无 `patterns`）：页类型，不认领地址。根是会话工作目录，标签由 `workspaceTitleOf` 给出。树**不**建模为资源——逐层懒加载的目录列表是类型自有的视图状态，住在独占 store、按 tab 分桶；`useResource` 留给只有一个地址的内容。行序是读者的序（目录在前、文件在后，按 `Intl.Collator` numeric），Host 列什么画什么，截断以 `truncated` 标记收尾。点文件即 `openResource(fileAddressFor(...))`——树从不指名查看器，由注册表的认领决定谁画这个地址；扩展在 `dsh-resource://file/**` 上认领更窄 pattern 即可接走点击而树无需改动。

### 产品行为变化：Details 列的移除

`7e017046c` / `108a7478c` / `a7c7e9965` 把文件打开路由改道 Sidebar：

- 工具行的文件链接、产物 chip、`read` 工具行——现在都在 Sidebar 打开为文本预览 tab；
- 旧的"Details 列"（`ToolDetails`、`details-session-lifecycle` 测试中那根列）被移除，文件链接点击不再打开内联详情；
- 产物行不再提供 `Show in folder` 按钮——目录没有可查看的文本，文本预览以 `not-regular-file` 拒绝它，与其给一个注定失败的按钮，行什么都不提供。

## 17.21 设计亮点小结

1. 两阶段引导（模块面 → 插件面）与 shell 自足；
2. 双向异质连接（HTTP 上行 + 只读 WS 下行）与 DNS-rebinding fence 信任模型；
3. 客户端插件"注册 factory、materialize 才执行副作用"；
4. Slot 的声明即认领、shadowing 选举、abdicate 失败隔离；
5. 主题 token 覆盖成对校验与首屏防闪烁；
6. @Remote 生成式契约，两侧共享 InvocationDescriptor；
7. 会话快照折叠：UI 只见日志派生快照；
8. 浏览器 Worker 运行时（实验性）与 Cordis Inspector（CDP 集成）；
9. 词法 Composer 与 Streaming Fence 增量高亮；
10. 签名浏览器 Cookie 认证与统一安全模型；
11. 客户端资源模型（`useResource`）与保留订阅——地址是身份，订阅是状态；
12. 工作区文件服务的有界字节范围读取——本地与沙箱共享同一底层合约；
13. 右侧 Sidebar 的停靠与 tab 类型注册——keyed slot + chain fallback +档位认领的完整演示；
14. 会话 Header corner slot 与响应式右列几何。

> **文档提醒**：`docs/subsystems/web.md` 讲的是 `ctx.web`（Web 搜索/抓取工具），不是 Web 客户端——读官方文档时注意区分；`ctx.clientModules`（Host 侧）与 `ctx.modules`（浏览器侧）也易混淆。

下一部分进入全书的应用篇：插件开发技巧。