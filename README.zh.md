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

agent 会依次：实测你本机的配置 schema → 探测你已有的供应商和模型 → 给出「角色 → 模型」映射建议（**你确认**）→ 渲染路由层草案 → 校验 → 备份后合并写入（**你确认**）。

你的供应商和密钥**保持原样**，仓库只涉及路由层（groups/rules/classifier）。

## 核心概念：模型角色

策略不绑定具体模型，而是定义 5 个能力角色，由你映射到自己的模型：

| 角色 | 用途 |
|---|---|
| `reasoning/strong` | 架构设计、疑难排查、大改动 |
| `code/general` | 实现、修 bug、写测试、review |
| `design/ui` | 界面、样式、视觉还原（含截图） |
| `fast/cheap` | 简单问答、意图分类器、兜底 |
| `context/long` | 长上下文摘要 |

内置 7 条互斥意图（测试/问答/实现/重构/架构/UI/审查）+ 推理触发 + 兜底 + 摘要组，覆盖编码全流程。详见 [路由模式库](docs/patterns.md)。

## 仓库结构

```text
AGENTS.md                  # agent 工作流与红线（入口）
docs/
  concepts.md              # 路由概念
  schema.md                # 配置字段参考（含存疑标注）
  patterns.md              # 路由模式库
templates/
  roles.json               # 角色定义与映射
  groups.template.json     # 路由层模板（角色占位）
examples/demo/             # 虚构供应商的完整走通示例
scripts/
  validate.py              # 路由层草案校验器
  e2e.sh                   # 隔离验收
```

## 示例

[examples/demo/](examples/demo/README.md) 用虚构供应商 `acme/*` 演示从本机配置到路由层产物的全过程。

## 诚实声明

schema 文档基于 magpie v0.1.4130 单机观测，**非官方规范**；agent 工作流以实测你本机配置为准。语义存疑的字段在 [schema.md](docs/schema.md) 中逐个标注。

## License

[MIT](LICENSE)
