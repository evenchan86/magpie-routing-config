# 配置 schema 参考

> **权威声明**：本文以 [magpie 官方文档](https://usemagpie.ai/docs/zh)（含 [意图页](https://usemagpie.ai/docs/zh/intent)，2026-11-15 访问）与 magpie CLI（`group help` / `group rule add --help`）为权威，并经本机实测校验（magpie v0.1.4130，建临时组读真实 JSON 后删除的探针）。不再是「单机观测、非官方规范」。官方文档与 CLI/实测冲突时，**以 CLI/实测为准**（如意图页「classifier 不能是组」的说法滞后，见 classifier 节）。agent 工作流第一步仍须实测你本机配置验证字段存在性——文档只是先验。

**来源标注**：官方文档 / CLI / 实测（可组合）。

**校验标注**（对应 `scripts/validate.py`）：

- **语义校验**：工具做语义检查（枚举、范围、引用、集合、成员资格、分离守卫等）。
- **类型/结构校验**：工具检查类型与结构（bool/数组/对象/`{field,op,value}` 等），不深校验语义。
- **仅白名单放行**：工具接受该字段，但不做进一步校验。
- **仅文档**：仅文档记录，不在工具白名单内（写入会被按未知字段拒绝），不要放进模板。

## group 字段

| 字段 | 类型 | 语义 | 来源 | 校验 |
|---|---|---|---|---|
| `id` | string | 组标识；agent 以 `group/<id>` 引用 | 实测 | 语义校验（必填、唯一） |
| `name` | string | 显示名 | 实测 | 类型/结构校验（string） |
| `note` | string | 备注 | 实测 | 类型/结构校验（string） |
| `members` | string[] | 成员清单，写法见下节；可为模型引用、`group/<id>`、glob/re: 模式 | 实测+CLI | 语义校验（组引用解析、模型引用已知；**所有组** members 必须非空） |
| `rules` | rule[] | 有序规则，首条命中生效 | 实测 | 语义校验（见 rule 字段） |
| `classifier` | string | 意图判断模型 `provider/model` 或 `group/<id>`，见下文 classifier 节 | 实测+CLI | 语义校验（分离守卫） |
| `routing` | string | 池路由模式，**12 值（含 `manual`）**，默认 `smart`，见下表 | 实测+CLI | 语义校验（枚举） |
| `affinity` | string | 会话粘性，5 值，默认 `auto`；CLI 别名 `stays`，见下表 | 实测 | 语义校验（枚举） |
| `intentSure` | number 0..1 | 意图置信阈值，默认 0.4 | 实测 | 语义校验（0..1 范围） |
| `context` | number | 告知 agent 的上下文 token 数 | 实测 | 语义校验（非负 number） |
| `compact` | number | 组级压缩阈值（token 数）；与规则级 `compact:bool` 同名不同型，见「compact 三义」 | 实测 | 语义校验（非负 number） |
| `levels` | string[] | 提供给 agent 的推理档位 | 实测 | 语义校验（档位集合） |
| `effort` | string | `agent`（默认）= 每个请求按 agent 要求的强度推理，但以成员自身 `:<effort>` 为限；`auto` = classifier 每回合选强度（需 classifier） | CLI | 语义校验（auto\|agent 枚举；auto 需 classifier） |
| `disabled` | bool | 停用该组 | 实测 | 类型/结构校验（bool） |
| `hidden` | bool | 隐藏 | 实测 | 仅白名单放行 |
| `unlists` | bool | 不列出 | 实测 | 仅白名单放行 |
| `weight` / `fast` / `ultra` / `pick` / `listed` / `family` | —（值形态待核） | JSON 字段名经二进制确证全部存在。CLI 语义：`weight=<model>=<n>` 为 routing=weight 的权重份额（1–1000，未指定默认 1）；`fast`/`ultra` 为按厂商 fast/Ultrafast 模式发送的模型清单；`pick=<model>` 为手动路由目标（routing=manual）；`listed=no` 让模型不进 agent 可见清单、只经组提供；`family` 为家族标签 | CLI+实测（二进制） | 仅白名单放行（`family` 做 string 类型检查） |

顶层 `noAutoGroups`：语义待核，仅文档（不在工具白名单），不进模板。供应商的 `key`/`keys`/endpoint：**永不涉及**（红线，供应商段只探测引用、不生成不修改）。

## rule 字段

| 字段 | 类型 | 语义 | 来源 | 校验 |
|---|---|---|---|---|
| `use` | string | 目标 `provider/model[:effort]` 或 `group/<id>`，**必须是本组成员**；每条规则必有 `use`（pause 规则把模型写在 use 里）；CLI `use=a,b` 展开为 `use=a` + `more=[b]` | 实测+CLI | 语义校验（引用已知 + 成员资格） |
| `more` | string[] | 故障转移链，按序尝试；可指向模型或组，**必须是本组成员** | 实测+CLI | 语义校验（引用已知 + 成员资格） |
| `intent` | string | 意图匹配条件（需组有 classifier） | 实测 | 语义校验（string；intent 规则要求组有 classifier） |
| `effort` | string | 推理条件：`"on"`（任意推理）或档位（至少该档） | 实测+CLI | 语义校验（on 或档位） |
| `compact` | bool | `true` = 压缩触发条件（Agent 压缩上下文时命中），**不是默认兜底** | 实测+文档 | 语义校验（仅 true） |
| `useEffort` | string | 规则目标强度 `low/medium/high/xhigh/max`（CLI `use-effort`）；命中后整轮生效、覆盖 Agent 要求，取模型最接近的档位；未知档位的模型按 Agent 要求发送 | 官方文档 | 语义校验（档位集合） |
| `tokens` | number | 请求长度至少该值（按请求大小估算，或供应商对会话上次请求的计数，取较大者）；CLI 支持 `200k`/`1m` 简写 | CLI | 类型/结构校验（非负 number） |
| `images` | bool | 请求带图像（当前或会话早先） | CLI | 类型/结构校验（bool） |
| `agents` | string[] | 请求来自这些 agent 之一（按 magpie usage 的命名，如 claude/codex/opencode） | CLI | 类型/结构校验（数组） |
| `time` | object | 时间窗 `{from:"HH:MM", to:"HH:MM", days:["mon",…], zone:"IANA"}`：轮开始时刻落在窗内；可跨午夜；zone 缺省用本机时区；只给 days 则全天有效。**不是字符串** | 实测+CLI | 类型/结构校验（对象） |
| `folders` | string[] | agent 工作目录是这些目录之一或其子目录；未告知目录的请求不匹配任何 folder | CLI | 类型/结构校验（数组） |
| `exceptFolders` | string[] | 工作目录不在这些目录及其子目录内（**驼峰**，CLI `except-folders`）；未告知目录的请求视为满足 | 实测+CLI | 类型/结构校验（数组） |
| `where` | object[] | 条件数组 `[{field,op,value}]`，可多条且须全满足，见下节「where 条件」 | 实测+CLI | 类型/结构校验（`{field,op,value}` 数组） |
| `pause` | bool | `true` = 暂停规则：条件持有期间 `use` 里的模型被排除出组——不发任何请求，即使其他成员失败或会话原本在它上面也不接管；条件仅限 time/days/agents/folders/exceptFolders 与 agent 条件（CLI） | 实测+CLI | 类型/结构校验（仅 true） |

### CLI 旗标 ≠ JSON 字段（写进 JSON 会被静默忽略）

以下只是 CLI 旗标名或便利写法，**不是 rule JSON 字段**；写进 JSON 会被 magpie 静默忽略（本仓库校验器直接按未知字段拒绝）：

| CLI 旗标 | JSON 实际去处 |
|---|---|
| `when="<field> <op> <value>"` | `where`：`[{field,op,value}]` 对象数组（见下节） |
| `time=HH:MM-HH:MM` / `days=mon-fri` / `tz=<zone>` | 都嵌进 `time` 对象 `{from,to,days,zone}`；`time` 不是字符串 |
| `except-folders=<folder>,…` | 驼峰 `exceptFolders` |
| `at=<n>` | 规则插入位置（1-indexed），不是存储字段 |
| 规则级 `classifier=<model>` | 设置的是**组级** `classifier`（CLI 便利写法），不是 rule 字段 |

**旧结论反转**：旧文档说「`when` 是配置里合法的字符串条件字段」——错误。JSON 配置里写 `where`（对象数组）；`when` 只是 CLI 旗标名与运行时日志表示法，不是 JSON 字段，见 [concepts.md](concepts.md)。

### where 条件

`where`：`[{field,op,value}]`，多条须全满足。`field` ∈ `tokens`/`effort`/`agent`/`subagent`/`message`/`system`/`last`；`op` 为比较操作符（如 `lt`/`gt`/`contains`/`is` 等）；`value` 为字符串。实测示例（CLI → JSON）：

```json
[
  { "field": "tokens", "op": "lt", "value": "20000" },
  { "field": "message", "op": "contains", "value": "run the tests" }
]
```

分别对应 CLI `when="tokens < 20k"` 与 `when="message contains run the tests"`（注意 `20k` 展开为 `"20000"`，value 一律字符串）。各 field 的比较方式（CLI 口径）：tokens 长度比较（`>= > < <=`）；effort `is`/`is not`（off/on/档位）或档位比较；agent `is`/`is not`（可逗号分隔多个）；subagent 是否子代理请求（Claude Code/Codex 可识别，其他 agent 的子代理按非子代理计）；message 轮开始时用户的话（`contains`/`does not contain`/`starts with`/`matches` 正则，不区分大小写）；system 对系统提示的任一块、last 对最后一条用户消息，比较方式同 message。op 全集与 CLI `>=`/`is not` 等对应的 JSON op 名未逐一实测，以本机实测为准。

### magpie 原生强制（实测）

- 规则 `use`/`more` 必须是本组成员（成员可以是模型或组），否则 magpie 拒绝保存（`X is not in <group>`）。工具做同样的成员资格校验（组含 glob/re: 模式成员时，模型成员资格检查豁免）。
- 一个组的成员要么全是 decision model（分类器），要么全是会话模型，**不能混**，否则 magpie 拒绝。这是 magpie 在组级对 classifier 分离的原生强制；工具的分离守卫另做跨组校验（见 classifier 节）。

运行时日志里的 `n`/`held`/`classified` 与数组形式的 `when` 是日志表示法，不是配置写法，见 [concepts.md](concepts.md)。

## member 写法

来源：实测+CLI（嵌套部分另见官方文档「路由组里放路由组」）。

- `provider/model`：标准引用。裸名仅当唯一供应商提供该模型时可用。
- `:effort`：固定成员强度，集合 **`none/minimal/low/medium/high/xhigh/max`**。（旧文档的 `ultra` 是错的，且缺 `minimal`，已修正。）
- `:low+high`：多级写法。`:fast`：厂商快速模式。`#account`：钉绑账号/key。
- 同一模型两个强度 = 两个成员（如 `acme/code-standard:low` 与 `acme/code-standard:high`）。
- `group/<id>`：嵌套子组，规则见下节。
- glob / `re:` 模式：按模式匹配模型；**pattern 不匹配组**。模式匹配工具暂不校验。

工具校验模型引用时剥 `:effort`/`:fast`/`#account` 后缀比对已知模型清单，组引用单独解析。边界：若某模型真实名字恰以档位词结尾，剥后缀可能误判——罕见，遇到时以本机实测为准。

### 组嵌套（组中组，已证实）

- `members` 与规则 `use`/`more` 可为 `group/<id>`（工具做组引用解析与成员资格校验）。
- 最多 **8 层**；禁直接/间接自包含（组不能包含自己）。工具校验组引用解析、自包含与深度。
- 每层按**自己的** `routing`/`rules` 路由；外层路由不伸进子组，只把子组当一个成员。
- 子组**全部失败**才轮到外层下一成员。

## routing：12 种池路由模式

组级字段，默认 `smart`。池路由 = 在成员之间分摊请求（区别于故障转移，见 [concepts.md](concepts.md)）。语义来源：官方文档（9 值）+ CLI（另含 `free`/`expiring`/`manual`）。工具校验枚举。

| 值 | 语义 | 来源 |
|---|---|---|
| `smart` | 默认。额度最先重置的排第一；失败休息中的排最后 | 官方文档 |
| `order` | 严格按成员顺序，第一个答不了再换下一个 | 官方文档 |
| `drain` | 一个账号/key 用到额度用完再换下一个，并一直用它；前面的恢复了也不切回 | 官方文档 |
| `rotate` | 每发一条消息交给下一个成员的账号/key；工具调用留在同一个上 | 官方文档 |
| `usage` | 剩余额度最多的账号/key 排第一 | 官方文档 |
| `pace` | 每周剩余额度 ÷ 距重置小时数，最高者优先；到期前用完，减少重置浪费 | 官方文档 |
| `weight` | 按权重比例分配、均匀穿插（权重 3 每拿 3 个，权重 1 拿 1 个）；休息中的成员退出本轮、下一成员兜底；权重经 group `weight` 设置（值形态待核） | 官方文档+CLI |
| `fast` | 最近回答最快（首字时间/输出速度）的成员优先；相差不到一成保持原序 | 官方文档 |
| `cheap` | 此刻最便宜的成员优先（每百万 token 价格 × 倍率，含高峰计价）；仅限路由组 | 官方文档 |
| `free` | CLI/二进制有该值，语义待核 | CLI+实测（二进制） |
| `expiring` | 免费额度优先、最先到期的先用；免费额度用尽才用付费 | CLI |
| `manual` | 只路由到你选定的模型（`pick=<model>`，或在组卡片上点选）；其他成员与规则等待，直到另选或改路由，**不做故障转移** | CLI |

`manual` 在 routing 枚举内（旧文档「11 模式、manual 不在枚举内」是错的）；手动选择经组级 `pick` 字段（JSON 名二进制确证，值形态待核）。

## affinity：5 种会话粘性

组级字段，默认 `auto`；CLI 别名 `stays`。语义来源：官方文档「会话保持」+ 实测字段存在。工具校验枚举。

| 值 | 语义 |
|---|---|
| `auto` | 默认。一轮之内总是保持；跨轮在厂商缓存还值得保留时保持 |
| `session` | 整个会话保持，只要它还能回答；新会话按当前最少并发分配 |
| `turn` | Agent 回传工具结果时不换；你再次发言时重新路由 |
| `off` | 每个请求都重新路由 |
| `strict` | 绝不换账号/key，即使超过用量上限——限流/额度用完直接报错给 Agent |

## compact 三义（同名不同物，务必区分）

| 写法 | 层级/类型 | 语义 |
|---|---|---|
| 规则 `compact: true` | rule / bool | **压缩触发条件**：Agent 压缩上下文时命中（如 Claude Code `/compact` 与自动压缩、Codex、OpenCode 等）。让便宜快的模型写总结，对话本身仍留原模型 |
| 组级 `compact: <number>` | group / number | 压缩阈值（token 数） |
| 默认兜底 | 无字段 | 未命中任何规则 → 按组的 **routing 模式**路由（`order` 才是首成员优先；`usage` 按额度分摊等）。不是 compact |

**不强制 `compact:true`**——工具要求**所有组** `members` 非空（不只含 rules 的组）；兜底按组 routing 模式走。旧文档「必须含 compact:true 兜底规则」的说法已作废。

## 默认兜底与规则命中

来源：实测+CLI。旧文档把「默认兜底 = 成员顺序/首成员」当普适规律并归于官方文档，是失真，已纠正。

- 一条规则都不命中（含 classifier 答「都不是」、超时、出错）→ 组**按自己的 routing 模式**路由这一轮：`order` 首成员优先，`usage` 按剩余额度分摊，`weight` 按权重等。写作建议「把默认模型放 members 首位」**仅对 order 类模式成立**；对 `usage` 子组（如 g-test/g-light）不成立。
- 规则命中 → 目标模型置首，其余成员随后做故障转移（仍按组 routing 模式）；目标无可用 key/账号时回退其余成员。

## classifier（意图判断，独立角色）

- 字段值为 `provider/model` 或 `group/<id>`（实测+CLI，CLI help 与二进制均支持组）。**分歧标注**：官方意图页说「不能是组」是滞后的——功能以 CLI/实测为准，不要声称官方文档支持组 classifier。
- 调用参数：自动取最低推理档（支持 `none` 用 `none`，否则最低档）、temperature 0、max_tokens 2048、不流式（实测+文档）。
- 每回合问一次（仅新轮首个请求触发，工具往返沿用决定）；只发当前这条消息，不含整段对话；超时默认 8 秒；出错/超时/无答案 → 意图条件不命中，按其他规则走（官方文档）。
- `intentSure`（0..1，默认 0.4）为意图置信阈值（实测）。
- **分离硬约束**：classifier 只做意图判断，**绝不**进该组 `members` / 规则 `use` / `more` / 兜底。工具设分离守卫：classifier 是模型时不得出现在该组路由成员/目标；是组时只校验引用。
- **magpie 原生强制（实测）**：一个组的成员要么全是 decision model（分类器），要么全是会话模型，不能混，否则 magpie 拒绝保存。这是组级的原生分离强制，与工具的跨组分离守卫互补。
- 选模型建议：小而快、不带推理（官方文档）。它与 fast/cheap 路由角色是两回事——后者是正常路由成员，承担轻量任务与兜底。

## 待验证清单

**已解决**（原清单移除）：

1. ~~规则 use 能否指向组~~ → 组中组已证实（members/use 可为 `group/<id>`，≤8 层禁自包含）；`more` 同理，且 use/more 必须是本组成员（magpie 原生强制，实测）。
2. ~~affinity 配置入口~~ → 已定位：组级 JSON 字段 `affinity`（CLI 别名 `stays`）。
3. ~~图像生成路由~~ → 生图独立于路由层：走设置 Image generation + MCP 工具，不进 groups 路由。
4. ~~classifier 可选范围~~ → 任意 `provider/model` 或 `group/<id>`（官方意图页滞后，见 classifier 节）。
5. ~~规则 `when` 字符串字段~~ → **反转**：JSON 字段是 `where`（`[{field,op,value}]` 对象数组）；`when` 只是 CLI 旗标与日志表示法（实测）。
6. ~~`time`/`days`/`tz`/`except-folders`/`pause` 写法~~ → `time` 是对象 `{from,to,days,zone}`；`exceptFolders` 驼峰；`pause` 为 `{use:<model>, pause:true}`（实测）。
7. ~~`at`/规则级 `classifier`~~ → CLI 便利写法（插入位置 1-indexed / 设组级 classifier），不是 rule JSON 字段。
8. ~~`weight`/`fast`/`ultra`/`pick`/`listed`/`family` 的 JSON 字段名~~ → 二进制确证全部存在（值形态仍待核，见下）。
9. ~~routing `free`/`expiring` 存在性、`expiring` 语义~~ → 二进制确证存在；`expiring` = 免费额度优先、最先到期先用（CLI 示例）。`free` 语义仍待核。
10. ~~组级 `effort:"agent"` 语义~~ → CLI 已定义：每个请求按 agent 要求的强度推理，但以成员自身 `:<effort>` 为限（默认 `agent`）。
11. ~~`manual` 模式~~ → routing 12 值含 `manual`，经 `pick=<model>` 使用。
12. ~~默认兜底~~ → 纠正：按组 routing 模式路由，不是普适的成员顺序/首成员。

**仍待核**（agent 不要当作已支持特性写进配置）：

1. 组级 `weight`/`fast`/`ultra`/`pick`/`listed`/`family` 的 JSON **值形态**（字段名已二进制确证；CLI 语义见 group 字段表）。
2. routing `free` 的语义（存在已确证）。
3. 顶层 `noAutoGroups` 的准确语义。
4. glob/re: 模式的语法细节（工具暂不校验）。

若你的实测回答了其中任何一项，欢迎补充本文档（标注你的 magpie 版本与证据）。