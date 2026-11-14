# 路由概念

> 本文描述 magpie 的概念模型，基于 magpie v0.1.4130 单机观测整理，**非官方文档**。以你本机实测为准。

## magpie 是什么

本机 macOS 桌面 AI 路由网关：把你的编码 agent（Claude Code、Codex 等）的请求，按你定义的策略路由到不同供应商的不同模型。价值在于**按任务类型选模型**——难题用强模型，琐事用便宜模型。

## 路由层级

```text
agent（编码助手）
  └─ 指向一个 group（路由组）
       ├─ classifier：意图分类器（一个便宜模型），判断当前请求的意图
       ├─ rules：有序规则，第一条命中的规则决定目标模型
       │    └─ use → 具体模型（provider/model）
       │         └─ more → 失败时的故障转移链
       └─ members：组内可用模型清单
```

## 核心概念

| 概念 | 含义 | 本仓库是否涉及 |
|---|---|---|
| provider | 供应商连接（endpoint、key、模型清单） | 只探测引用，**不生成不修改** |
| group | 路由组：members + rules + classifier | ✅ 核心交付物 |
| rule | 一条路由规则，见下 | ✅ 核心交付物 |
| classifier | 意图分类模型，返回某条意图或「都不是」 | ✅ 组级字段 |
| affinity | 会话粘性：同会话后续请求倾向沿用同一模型（利用 prompt cache） | ⚠️ 配置入口未定位，见 schema.md 待验证清单 |

## 规则字段（配置 schema）

| 字段 | 作用 |
|---|---|
| `use` | 目标模型（`provider/model`） |
| `more` | 故障转移数组，按序尝试 |
| `intent` | 意图字符串；分类器判定为该意图时命中 |
| `effort:"on"` | 推理触发：请求需要推理时命中 |
| `compact:true` | 兜底/压缩规则：无其他规则命中时生效 |

规则按数组顺序求值，**第一条命中生效**；分类器返回「都不是」且无需推理时，落到兜底规则。因此**凡配置 rules 的组，必须含一条 `compact:true` 兜底规则**，否则行为不可控（校验器强制）。

## 配置与运行时日志的区别（重要）

运行时日志里规则会展开成 `{n, use, when, turn, ...}` 的形式：`intent:"X"` 显示为 `when:["intent \"X\""]`，`effort:"on"` 显示为 `when:["reasoning"]`。**`when`/`n` 是日志表示法，写配置时用 `intent`/`effort`，不要照抄日志。**
