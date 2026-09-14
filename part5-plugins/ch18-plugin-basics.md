# 第 18 章 插件开发基础

从本章起进入应用篇：如何为 dsh 开发插件。我们先把"一枚插件"的所有形态与约定讲清楚，再给实战模式与工作流。

## 18.1 插件的三种形态

Cordis 插件有三种可装载形态（第 7 章）：

```ts
// 函数插件
export function apply(ctx: Context) { ... }

// 对象插件（DSH 动态插件的标准形态）
export default { name: 'my-plugin', inject: ['tools'], apply(ctx) { ... } }

// 类插件
export class MyPlugin extends Service { ... }
```

元数据字段（`Plugin.Base`）：

```ts
{
  name?: string,                 // 显示名（fiber 诊断、日志名）
  Config?: StandardSchemaV1,     // 配置校验器
  inject?: Inject,               // 依赖声明
  provide?: string | string[],   // 提供的服务名
  intercept?: Dict<boolean>,     // 消费哪些服务的 intercept 配置
}
```

## 18.2 依赖声明：inject 与 ctx.get

**声明依赖（inject）** 与 **可选读取（ctx.get）** 是两回事，选错会得到不同行为：

```ts
// 硬依赖：服务不存在时插件停在 PENDING，出现后自动装载
export const inject = ['tools']
export function apply(ctx: Context) {
  ctx.tools.register(...)   // 只有 tools 就绪才会执行到这里
}

// 可选读取：服务不存在返回 undefined，自行决定行为
export function apply(ctx: Context) {
  const tools = ctx.get('tools')
  if (tools === undefined) return   // 没有 tools 就什么都不做
}
```

规则（官方技能文档）：

- 默认用 `ctx.get(name)` + undefined 检查；
- 只有当该服务是**硬依赖**、且插件必须等待它出现时才声明 `inject`；
- **绝不能**不声明 inject 就读取 `ctx.foo`——代理会抛 `cannot get property "foo" without inject`（第 4 章讲过这条报错的来源）。

## 18.3 配置：Config 与 intercept

插件的配置经 Standard Schema 校验（`fiber.ts` 的 `resolveConfig`）。声明方式：

```ts
import { Schema } from '@deepseek-ai/schemastery'   // vendored 的 schema 库

export const Config = Schema.object({
  enabled: Schema.boolean().default(true),
  maxItems: Schema.number().min(1).default(10),
})

export function apply(ctx: Context, config: typeof Config) { ... }
```

配置来源（按优先级）：

1. 组合行里的 `config` 字段（loader 装载时经 `internal/config` waterfall 解析）；
2. `ctx.intercept(name, config)` 拦截配置——子 context 的插件会看到合并后的配置（`Service[symbols.resolveConfig]`，第 5 章）；
3. 服务若声明 `Config.merge`，可自定义合并语义。

配置校验失败在装载时抛出 `ValidationError`，列出每个 issue 与路径（`fiber.ts:19-36`）——**配置错误永远 fail loud，绝不静默跳过**。

## 18.4 副作用管理：一切皆 effect

dsh 插件开发的第一纪律：**每一个注册都必须可逆**。Cordis 提供的生命周期 API：

```ts
export function apply(ctx: Context) {
  // 事件监听：fiber 卸载自动移除
  ctx.on('session/event', (session, event) => { ... })

  // 外部订阅：返回 disposer，卸载时自动调用
  ctx.effect(() => {
    const disposer = service.subscribe((value) => { ... })
    return disposer
  })

  // 生成器 effect：逐个 yield disposer，卸载时逆序清理
  ctx.effect(function* () {
    yield ctx.tools.register(...)
    yield ctx.provide('myService', ...)
  })

  // 定时器是服务（timer），不是全局 API
  ctx.inject(['timer'], (ctx) => {
    ctx.timeout(() => { ... }, 1000)
    ctx.interval(() => { ... }, 5000)
  })
}
```

**绝不能**在模块顶层或 `apply` 之外创建进程级/页面级副作用；定时器必须用 `timer` 服务（全局 `setTimeout` 在插件环境不存在）。

## 18.5 提供服务：ctx.provide 与 Service 子类

```ts
// 简单方式
export const provide = 'myService'
export function apply(ctx: Context) {
  ctx.provide('myService', {
    async doSomething() { ... },
  })
}

// 服务类方式（构造即注册、卸载即消失）
export class MyService extends Service {
  static provide = 'myService'
  constructor(ctx: Context) {
    super(ctx, MyService.provide)
    // 构造器里注册事件/工具等
  }
}
```

注意同名服务在同一隔离作用域**只能注册一次**（第 4 章），跨 fiber 重复提供会在装载时抛错。

## 18.6 监听事件：五种模式的选择

| 想做什么 | 用 |
| --- | --- |
| 观察事实、记录日志 | `ctx.on` / `ctx.emit`（emit） |
| 等待所有监听者完成 | `ctx.parallel` |
| 第一个决策生效 | `ctx.serial` / `ctx.bail` |
| 包裹/改写/否决 | `ctx.waterfall`（必须调 `next()` 委派） |

waterfall 监听者示例（工具执行前的策略）：

```ts
ctx.on('tools/pre-execute', async (payload, next) => {
  if (isDenied(payload.name, payload.arguments)) {
    return { denied: true, reason: 'denied by policy' }   // 不调 next() = 否决
  }
  return next()                                            // 委派
})
```

## 18.7 一个最小插件的完整代码

把上述约定拼起来，一个最小但完整的工具插件（官方 cookbook 的最小形态）：

```ts
import { readFile } from 'node:fs/promises'
import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'my-tool'
export const inject = ['tools']

export function apply(ctx: Context) {
  ctx.tools.register(defineTool({
    name: 'read_file',
    description: 'Read a file from disk.',
    parameters: {
      path: { type: 'string', required: true, description: 'Absolute path' },
      limit: { type: 'number' },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args, exec) {
      return readFile(args.path, { encoding: 'utf8', signal: exec.signal })
    },
  }))
}
```

注册即 effect：fiber 卸载工具自动消失；schema 自动进入提示词组装。

## 18.8 公共 package manifest 类型（Public package manifest）

`0.1.5-rc.2` 引入了公共的 `DshPackageManifest` 类型（`packages/util/package-manifest/src/types.ts`），用于描述 DSH 使用的 `package.json` 字段。该类型为插件作者提供了统一的公共导入路径，用于声明 npm 身份、运行时要求和 DSH 元数据。

**必填字段**：
- `name`：包名
- `version`：版本号

**可选字段**：
- `dsh`：使用 `DshManifest` 类型描述公共组合与作者元数据。包含 `manifestVersion`（声明格式版本，当前为 `1`）、`bundle`（bundle 声明）、`client`（客户端插件声明）等。
- `engines`：运行时要求，位于顶层。`dsh`、`node` 和 `npm` 均为可选版本字符串，也允许其他 engine 名称。例如：
  ```json
  {
    "engines": {
      "node": ">=24",
      "dsh": "0.1.5-alpha.1"
    }
  }
  ```

**重要说明**：
- `DshPackageManifest` 只选取所需 npm 字段，不是完整的 `package.json` schema
- 当前安装器和加载器不强制检查格式与 DSH 兼容性声明
- 内部工具（镜像打包器的 `configTrees`、工作区目录生成器的 Session 迁移声明、app-boot 的生成模块后备元数据）仍可读取既有磁盘字段，但公共 manifest 类型不暴露这些内部字段
- 本地 profile 读者使用 `Partial<DshPackageManifest>`，因为 profile 无需发布版本

该类型细化了共享声明归属决策，包位置与依赖规则继续有效。外部作者获得完整的包级声明和更小的 DSH 作者 API。

## 18.9 小结

- 三种插件形态，`apply(ctx, config)` 是共同入口；
- 依赖声明二选一：inject（硬依赖等待）vs ctx.get（可选读取）；
- 配置经 Standard Schema 校验，fail loud；
- 一切注册都是 effect，卸载自动回卷；
- 事件按需求选模式，waterfall 记得 `next()`。

下一章给出一组可复用的实战模式。
