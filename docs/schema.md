# 配置 schema 参考

> **来源声明**：以下字段知识来自 magpie v0.1.4130 单机观测（配置文件 + 运行日志），**非官方规范**。agent 工作流第一步必须实测你本机配置验证字段存在性；语义存疑的字段在下文逐个标注。

## group 字段

| 字段 | 类型 | 语义 | 置信度 |
|---|---|---|---|
| `id` | string | 组标识；agent 以 `group/<id>` 引用 | 实测 |
| `name` | string | 显示名 | 实测 |
| `members` | string[] | 组内模型清单（`provider/model`，可带 `:effort` 后缀如 `:low`） | 实测 |
| `rules` | rule[] | 有序规则，首条命中生效 | 实测 |
| `classifier` | string | 意图分类模型引用 | 实测 |
| `disabled` | bool | 停用该组 | 实测 |
| `note` | string | 备注 | 实测（语义推测为纯备注） |
| `hidden` | bool | 存疑：推测为 UI 隐藏 | 未验证，不进模板 |
| `unlists` | bool | 存疑：语义不明 | 未验证，不进模板 |

顶层 `noAutoGroups`：语义推测为「关闭自动建组」，未验证，不进模板。

## rule 字段

| 字段 | 类型 | 语义 | 置信度 |
|---|---|---|---|
| `use` | string | 目标模型 `provider/model` | 实测 |
| `more` | string[] | 故障转移链，按序尝试 | 实测（日志可见多次尝试） |
| `intent` | string | 意图匹配条件 | 实测 |
| `effort` | `"on"` | 推理触发条件；运行时展开为 reasoning 匹配 | 实测 |
| `compact` | `true` | 兜底/压缩规则 | 实测 |

**在 v0.1.4130 观测样本的配置中未出现 `when`/`n`/`held`/`classified`**——它们是运行时日志字段，见 concepts.md。

**关于 `:effort` 后缀**：校验器识别的档位集合 `none/low/medium/high/xhigh/max/ultra` 来自模型目录 `supported_reasoning_levels` 的观测汇总（非配置文档定义）。校验按「最后一个冒号后的词是否为档位」剥后缀比对已知模型；若某模型真实名字恰以档位词结尾（如整名就是 `acme/foo:low`），会被误剥——属罕见边界，遇到时以本机实测为准。

## 明确不在本仓库模板中的字段

- `routing`（路由模式：order/rotate/usage 等）：观测为 **provider 级**字段，组级未观测到。供应商层不属于本仓库交付范围。
- `affinity`：会话粘性在运行日志中明确存在，但**配置入口未定位**。待验证后再纳入。
- 供应商的 `key`/`keys`/endpoint：永不涉及。

## 待验证清单（agent 不要当作已支持特性）

1. 规则的 `use` 能否指向另一个组（`group/<id>`，即两层路由）——当前观测到的配置全部指向模型。
2. `affinity` 的配置字段与层级。
3. `noAutoGroups` / `unlists` / `hidden` 的准确语义。
4. 图像生成等非聊天模型的路由方式（观测到的模型目录仅聊天模型）。
5. 分类器可选的模型范围（观测到独立分类模型被引用）。

若你的实测回答了其中任何一项，欢迎补充本文档（标注你的 magpie 版本与证据）。
