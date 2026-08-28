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

**keyed slot 的典型用例**：设置页「插件」分区的 `configurable` 标签页声明 `settings.plugin.item`（`{ kind: 'keyed', scope: 'root' }`），**键 = 卡片所编辑的 settings 命名空间**（声明 `key` 而非 `id`/`order`）。`0.1.0-rc.7` 起 api-proxy **服务每一个已注册命名空间**（不再有 `WEB_SETTINGS_NAMESPACES`/`PRODUCT_SETTINGS_NAMESPACES` 白名单），标签页以 `settings.describe` 返回的命名空间驱动派发——渲染结果是"存活 Host 插件注册的命名空间 × 注册在这些键上的卡片"两份账本的交集，缺席即无卡片。插件作者在 Host 注册命名空间 + 在浏览器把卡片注册在该键上，仓库外分发的插件也能出现在设置页（第 19 章 19.4 有注册示例）。

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

## 17.16 设计亮点小结

1. 两阶段引导（模块面 → 插件面）与 shell 自足；
2. 双向异质连接（HTTP 上行 + 只读 WS 下行）与 DNS-rebinding fence 信任模型；
3. 客户端插件"注册 factory、materialize 才执行副作用"；
4. Slot 的声明即认领、shadowing 选举、abdicate 失败隔离；
5. 主题 token 覆盖成对校验与首屏防闪烁；
6. @Remote 生成式契约，两侧共享 InvocationDescriptor；
7. 会话快照折叠：UI 只见日志派生快照；
8. 浏览器 Worker 运行时（实验性）与 Cordis Inspector（CDP 集成）；
9. 词法 Composer 与 Streaming Fence 增量高亮；
10. 签名浏览器 Cookie 认证与统一安全模型。

> **文档提醒**：`docs/subsystems/web.md` 讲的是 `ctx.web`（Web 搜索/抓取工具），不是 Web 客户端——读官方文档时注意区分；`ctx.clientModules`（Host 侧）与 `ctx.modules`（浏览器侧）也易混淆。

下一部分进入全书的应用篇：插件开发技巧。
