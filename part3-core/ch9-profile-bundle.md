# 第 9 章 Profile 与 Bundle 组合机制

上一章我们看到了 boot 如何使用 patch 栈。本章把 **Profile / Bundle / patch** 这套组合语言讲透——它是 dsh"不改代码重组产品"能力的核心，也是 `dsh --dump-config`、插件商店、agent preset 等一切配置层功能的地基。

## 9.1 三个概念

| 概念 | 是什么 | 在哪声明 |
| --- | --- | --- |
| **Profile（配置档）** | 一个命名的组合：要堆叠的 bundles 列表、安装的外部插件、用户自己的 patch 文件 | 存放在 Harness 主目录（`~/.dsh`）下的 profile 目录，清单写在 `package.json` 的 `dsh.profile` 字段 |
| **Bundle（捆绑包）** | Cordis 配置行 + 它们装载的代码的分发格式；上层任何 patch 都可覆盖它插入的行 | 自己的 `package.json` 的 `dsh.bundle` 字段指向 bundle 的 patch 文件 |
| **Patch（补丁）** | 对配置树的修改：按 id 整行替换配置，或 `insert` 新行 | `cordis.patch.yml` / bundle patch 文件 / `--patch` 覆盖层 |

`packages/boot/app-boot/src/profile.ts`（420 行）实现 profile 的发现、读取、清单写入与 bundle 解析（`loadProfile`、`readProfileManifest`、`resolveBundleDir` 等）。

## 9.2 分层与应用顺序

`docs/architecture.md` 原文：

> Layers apply to an empty entry list in this order: each bundle in the profile's listed order, then the profile's `cordis.patch.yml`, then the home-level one, then any `--patch` overlay.

即：**bundle 层（profile 清单顺序）→ profile 自身 patch → `$DSH_HOME/cordis.patch.yml`（用户级）→ `--patch` 覆盖层**。`profile-boot.ts` 的 `allPatches`（`profile-boot.ts:122-129`）精确对应：

```ts
function allPatches(composed) {
  return [
    ...composed.bundlePatches,
    ...composed.profile.patches,
    ...composed.homePatches,
    ...composed.overlays,
  ]
}
```

**后层覆盖前层**：用户级 patch 可以覆盖 bundle 插入的任何行；`--patch` 又可以覆盖用户级。

### 默认 Profile 模板使用的 Bundle

默认 Profile 模板使用的组合包：

| Bundle | 作用 |
| --- | --- |
| `dsh-base`（`packages/bundle/base`） | 每个 profile 的第一层：模型适配器、工具、持久化、沙箱与审批策略、设置、凭据、遥测 |
| `dsh-web-app`（`packages/bundle/web-app`） | 增加浏览器应用（web profile 使用） |
| `dsh-headless`（`packages/bundle/headless`） | 一次性运行器，无服务器（headless profile 使用） |
| `dsh-sdk-app`（`packages/bundle/sdk-app`） | SDK profile：stdio JSON-RPC 服务与进程生命周期（Python SDK 使用） |
| `dsh-sdk-minimal`（`packages/bundle/sdk-minimal`） | 独立最小化 profile（用于快照测试与最小配置场景） |
| `dsh-acp-app`（`packages/bundle/acp-app`） | ACP profile：自动化控制平面（Agent Control Protocol） |

内置 profile 模板（`web`、`headless`、`sdk`、`sdk-minimal`、`acp`）就是"哪个 bundle 列表 + 什么入口行"的预置组合。`0.1.2-alpha.1` 起，profile 系统成为 dsh 作为唯一 Node 应用启动器的统一入口：Python SDK 通过 `dsh sdk` profile 启动，ACP 自动化通过 `dsh acp` profile 启动，每个 profile 拥有独立的 bundle 组合与 patch 重载策略。

## 9.3 patch 语法

patch 文件是**顶层 YAML 数组**，每个元素是 `PatchOptions`：

```yaml
# 按 id 整行替换配置
- id: session-telemetry-otel
  config: { enabled: false }

# 插入新行
- insert:
    - id: my-plugin
      name: my-plugin
      config: { key: value }
```

字段语义（`@deepseek-ai/cordis-plugin-include`）：

- `{ id, config }`：找到同 id 行，整体替换其 config（`disabled: true` 也通过 config 表达——`resolveTelemetryPatch` 就生成 `{ id, disabled: true }`）；
- `{ insert: [...] }`：把新行插入树中；
- 支持 `!!js` 表达式节点（如 `!!js process.env.FOO`），Loader 在条目激活时对 `config` 求值（`docs/cordis-primer.md` 的 Loader Configuration 一节）。

patch 文件解析（`parsePatchList`，`app-boot/index.ts:320-338`）：顶层必须是数组，非法字段直接抛错（fail loud），但"patch 目标行不存在"只是 Loader 警告——**一个跨多个 surface 共享的覆盖层不必匹配每棵树**。

## 9.4 dump-config：组合的可视化

`dsh --profile web --dump-config` 是理解"机器实际启动的树"的最佳工具。它的实现是 `renderConfigDump`（`app-boot/index.ts:379-442`），算法很巧妙：

1. 解析基础配置文件（空根 `[]`）；
2. 对每个前缀 `1..k` 层，**用与 boot 完全相同的 `applyEntryPatches` 单次调用**重放 patch（`snapshot(count)`），得到逐层快照；
3. 逐层 diff：新增的行标来源，被改写的行记录"被哪些层 patch 过"；
4. 输出按来源分组的 YAML，每个连续片段前有 `# == <来源, patched by <层>>` 注释。

因为每一层都使用与 boot 相同的单次扁平应用，连"patch 可见性"的边角情况（后层 patch 到前层 insert 引入的行）都与真实装载一致。`!!js` 表达式原样打印、不求值。

> 注意：dump 的语义是"组成快照"，不是"将要装载的行"——同一行可能被后续层继续改写。

## 9.5 空根配置文件

每个 profile 目录里有一份 `cordis.yml`，内容永远只有：

```yaml
# dsh profile root — an empty entry list. The tree is composed as patches: ...
[]
```

`prepareProfile`（`profile-boot.ts:98-103`）在每次启动前**重写**它。为什么？注释解释了原因：整棵组合都是 patch 层，而 vendored Loader 的树写回（插件自卸时持久化当前树）可能把组合后的行烘焙进这个文件——那会在下次启动时重复插入每个 bundle。这份文件存在只是因为 **Loader 需要一个真实的 include 根来锚定 `baseUrl`**（dump 也锚定同一文件，保证两者基于同一基座组合）。

## 9.6 HMR：组合的热更新

第 8 章已述：`watchUserPatches` 监视 profile 级与用户级两个 patch 文件，HMR 回调重新读取并 `entry.update()` 根 Include。**bundle 层与覆盖层不参与热更新**——只有两个"用户层"文件热更新，且重读后经 `composeLive`（bundle 层垫底、覆盖层置顶）重组，保证"用户编辑永远无法顶掉 app 拥有的层"。

## 9.7 组合的校验门禁

仓库有 `verify-cordis-config` 脚本与大量配置校验测试，确保：

- 每个 profile/bundle 的清单字段合法；
- patch 文件可解析、条目可装载；
- 组合后的树满足包的 peerDependencies 约束。

## 9.8 与 agent preset 的关系

Profile/Bundle 组合的是**整个进程**的树；**agent preset** 组合的是**单个会话**的树（第 16 章）。两者共享同一套 Cordis 组合原语（patch 行、`isolate` realm、`cordis:group`），但作用域不同：

- Profile：进程级，`dsh --profile web`；
- Preset：会话级，`$DSH_HOME/.agent-presets/<id>/cordis.yml`，通过 agent 的 scope context 装载，其服务行通常需要 `isolate` realm 隔离。

## 9.9 小结

- 组合 = 空根 + 五层 patch（bundles → profile → home → overlays → 遥测开关），后层覆盖前层；
- patch 两种形态：id 定向替换与 insert；`!!js` 表达式在激活时求值；
- `--dump-config` 用 boot 同款算法重放并标注来源，是理解组合的第一工具；
- 空根配置文件的存在是为了锚定 baseUrl；树写回会被重写清除；
- 用户层 patch 文件热更新，app 拥有的层不可被用户编辑顶掉。

下一章进入核心子系统：会话日志。
