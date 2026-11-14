# magpie-routing-config

[English](README.md) | **中文**

**开源的 [magpie](https://usemagpie.ai) 路由策略架构方案**：把「如何设计 magpie 路由」沉淀为文档 + 模板 + agent 工作流。不含任何真实密钥或具体机器配置。

> 独立社区项目，与 [magpie](https://github.com/yetone/magpie) 官方团队无隶属或背书关系。

## 适合谁

已安装 [magpie](https://usemagpie.ai)（macOS 菜单栏 AI 路由网关桌面应用；[GitHub](https://github.com/yetone/magpie)）、已配好模型供应商，想优化路由策略的人。你不需要研究配置格式——把本仓库交给你的 agent 即可。

## 30 秒上手

```bash
git clone https://github.com/evenchan86/magpie-routing-config.git && cd magpie-routing-config
```

然后对你的 agent（Claude Code / Codex 等）说：

> 读这个仓库的 AGENTS.md，按工作流帮我配置本机 magpie 路由。

agent 会依次：实测你本机的配置 schema → 探测你已有的供应商和模型 → 给出「角色 → 有序模型列表」映射建议（**你确认**）→ 渲染两层路由草案 → 校验 → 备份后合并写入（**你确认**）。

你的供应商和密钥**保持原样**，仓库只涉及路由层（groups/rules/classifier）。

## 核心概念：两层意图分发

路由分成两层，让「意图判断」与「模型选择」各司其职：

- **主路由（`auto`）**——一个小而快的 **classifier** 判断每回合的意图，再用 `use=group/<id>` 分发到任务子组。它自己不做模型选择。没有意图命中时，按成员顺序兜底到第一位（日常编码子组）。
- **任务子组**——8 个组（`g-compact` / `g-test` / `g-light` / `g-code` / `g-heavy` / `g-arch` / `g-ui` / `g-review`），各自管理**多个模型成员**与路由模式（`order` 有序故障转移、`usage` 额度分摊）。每模型推理强度用成员后缀 `:effort` 设定。角色映射到有序模型列表，因此每个子组可容纳多个模型（如主力编码 → 备用编码 → 廉价兜底）。

classifier 是**独立角色**：只做意图判断，**绝不**作为路由成员、规则目标或兜底。

## 模型角色

策略不绑定具体模型，而是定义 6 个能力角色，由你映射到**自己模型的有序列表**（主模型在前，多个模型构成故障转移或额度池）。`scripts/render.py` 把模板成员 `<role:X>:强度` 展开为该角色列表里的每个模型。强度默认用槽位的，单个模型可在 mapping 里写 `model@effort` 覆写（组合写法 `provider/model#account@effort`）——因此同一子组可混强度（`:medium` 槽位下 mapping 写 `acme/vision@high`，渲染出 `acme/vision:high` 与 `acme/code:medium` 并列）：

| 角色 | 用途 |
|---|---|
| `intent/judge` | **仅**意图分类（classifier）；绝不进路由成员/规则目标/兜底 |
| `reasoning/strong` | 架构设计、疑难排查、大改动 |
| `code/general` | 实现、修 bug、写测试、review |
| `design/ui` | 界面、样式、视觉还原（含截图） |
| `fast/cheap` | 简单问答、轻量兜底（不是分类器） |
| `context/long` | 长上下文摘要 |

内置 7 条互斥意图（测试/问答/实现/重构/架构/UI/审查）+ 推理触发 + 压缩规则，覆盖编码全流程。详见 [路由模式库](docs/patterns.md)。

## 仓库结构

```text
AGENTS.md                  # agent 工作流与红线（入口）
docs/
  concepts.md              # 路由概念（两层、池路由 vs 故障转移）
  schema.md                # 配置字段参考（含来源与存疑标注）
  patterns.md              # 路由模式库
templates/
  roles.json               # 角色定义与映射
  groups.template.json     # 两层路由模板（角色占位）
examples/demo/             # 虚构供应商的完整走通示例
scripts/
  render.py                # 把角色→模型列表映射展开进模板（多模型子组）
  validate.py              # 路由层草案校验器（组引用、classifier 分离）
  apply.py                 # 草案按 id upsert 合并进本机配置（默认 dry-run；--write 先备份、写后读回校验、失败自动恢复）
  doctor.py                # 只读诊断现有配置（+ 手动冒烟步骤）
  e2e.sh                   # 隔离验收
```

## 示例

[examples/demo/](examples/demo/README.md) 用虚构供应商 `acme/*` 演示从本机配置到两层路由产物的全过程。

## 诚实声明

schema 文档以[官方文档](https://usemagpie.ai/docs/zh)、magpie CLI 帮助与实测为依据，但**不能替代你本机的实际情况**：agent 工作流以实测你本机配置为准。语义存疑的字段在 [schema.md](docs/schema.md) 中逐个标注。

## License

[MIT](LICENSE)