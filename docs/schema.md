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
| `members` | string[] \| null | **命名**成员清单，写法见下节；可为模型引用或 `group/<id>`。**glob/re: 模式不放这里**，放 `match` | 实测 | 语义校验（组引用解析、模型引用已知；`members` 与 `match` 不能同时为空；模式写进 members 报错） |
| `match` | string[] | **模式**成员（glob / `re:`），与 `members` 并列的独立数组；pattern-only 组的 `members` 落盘为 `null` | 实测 | 类型校验（非空字符串数组）；模式展开不做校验 |
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
| `hidden` | bool | 隐藏。**`true` + `members:null` + `name:""` 是 magpie 的「墓碑」**：`magpie group rm <auto-组>` 移除一个自动发现的组时落盘这个形态，用来「保持已移除」（CLI 回显 `magpie found it, so it's hidden`，`magpie group restore <auto-组 id>`（如 `auto-shared`）可恢复——参数是**具体组 id**，写 `restore auto` 会报 `no group "auto"`（实测））。**不是坏配置**，工具豁免其成员非空要求 | 实测 | 白名单放行；墓碑豁免空成员检查 |
| `unlists` | bool | `true` = 该组模型不进 agent 可见清单、只经组提供（CLI `listed=no`）。`listed=yes` 是**删除该键**，不是写 `false` | 实测 | 类型校验（bool） |
| `weights` | object | routing=weight 的权重份额：**键 = 完整成员引用（含 `:effort`）**，值 = 整数 1–1000，未列出的成员默认 1。CLI 旗标是 `weight=<model>=<n>`；非成员键 CLI 硬报错、JSON 路径静默忽略。**范围是 CLI 写入约束**：手写 2000 或 0，magpie 读路径照常生效（实测显示 `weight 2000`），但此后对该组的任何 `group set` 都会被拒（`a member's weight is 1 to 1000`）——所以工具仍按 1..1000 判失败 | 实测 | 语义校验（键须为本组成员、值为 1..1000 整数、排除 bool；含 `match` 的组豁免成员资格） |
| `fast` / `ultra` | string[] | 按厂商 fast / Ultrafast 模式发送的模型清单。**元素 = 完整成员引用（含 `:effort`）**，与 `weights` 同规矩；裸 `provider/model` 在 JSON 路径被**静默忽略**，CLI 路径则硬报错 `... is not in the group`。设 `ultra` 会自动把该模型补进 `fast` | 实测 | 语义校验（元素须为本组成员） |
| `pick` | string | 手动路由目标（**单个完整成员引用，含 `:effort`**）。CLI 设 `pick=` 会**自动把 routing 改成 `manual`**；之后改走 routing，`pick` 键仍残留。非成员/裸引用同上：CLI 硬报错、JSON 静默忽略 | 实测 | 语义校验（须为本组成员） |
| `family` | string | 家族标签（自由文本） | 实测 | 类型校验（string） |

**CLI 旗标 ≠ JSON 字段名**（写错会被 magpie **静默忽略**，不报错）：

| CLI 旗标 | JSON 真键名 | 值形态 |
|---|---|---|
| `weight=<model>=<n>` | **`weights`** | 对象映射，键含 `:effort` |
| `listed=no` | **`unlists`** | 布尔 `true` |

把单数 `weight` 或 `listed` 写进 JSON 一律无效（实测：权重全为 1、清单行为不变）。校验器会明确拒绝这两个名字并指出真键名。

**键名错 vs 类型错，后果完全不同**（实测 magpie 0.1.4130）：
- **键名写错** → 静默忽略该字段，其余照常。
- **类型写错**（如 `fast` 给字符串而非数组） → **整份 providers.json 解析失败**：magpie 报 `providers.json ... can't be read (it doesn't parse)`，有 `.bak` 时回退到备份内容、没有则当空配置。**CLI 退出码仍是 0**——必须读消息，不能只看退出码。所以校验器对类型从严。

顶层 `noAutoGroups`：**布尔 `true` = 关闭 magpie 自动发现的组**（形如 `auto-<model>`），自建/改过的组不受影响（实测：`magpie group auto off` 落盘 `{"noAutoGroups": true}` 且 `auto-` 组从清单消失；`auto on` **删除该键**）。不在工具白名单（工具只校验 groups），不进模板。供应商的 `key`/`keys`/endpoint：**永不涉及**（红线，供应商段只探测引用、不生成不修改）。

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
| `where` | object[] | 条件数组 `[{field,op,value}]`，可多条且须全满足；**`subagent` 条件无 `value` 键**，见下节「where 条件」 | 实测+CLI | 类型/结构校验（`{field,op}` 必需，`value` 除 subagent 外必需） |
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
  { "field": "message", "op": "contains", "value": "run the tests" },
  { "field": "subagent", "op": "is" }
]
```

分别对应 CLI `when="tokens < 20k"`、`when="message contains run the tests"`、`when="subagent is reviewer"`（注意 `20k` 展开为 `"20000"`，value 一律字符串）。

**`subagent` 条件没有 `value` 键**（实测：magpie 落盘就是 `{"field":"subagent","op":"is"}`，magpie 自己正常解析回显）。校验器对 `field=="subagent"` 允许缺 `value`，其余 field 仍要求三键齐全——把三键一律当必需会误拒 magpie 自己写出的配置。各 field 的比较方式（CLI 口径）：tokens 长度比较（`>= > < <=`）；effort `is`/`is not`（off/on/档位）或档位比较；agent `is`/`is not`（可逗号分隔多个）；subagent 是否子代理请求（Claude Code/Codex 可识别，其他 agent 的子代理按非子代理计）；message 轮开始时用户的话（`contains`/`does not contain`/`starts with`/`matches` 正则，不区分大小写）；system 对系统提示的任一块、last 对最后一条用户消息，比较方式同 message。op 全集与 CLI `>=`/`is not` 等对应的 JSON op 名未逐一实测，以本机实测为准。

### magpie 原生强制（实测）

- 规则 `use`/`more` 必须是本组成员（成员可以是模型或组），否则 magpie 拒绝保存（`X is not in <group>`）。工具做同样的成员资格校验（组含 glob/re: 模式成员时，模型成员资格检查豁免）。
- 一个组的成员要么全是 decision model（分类器），要么全是会话模型，**不能混**，否则 magpie 拒绝。这是 magpie 在组级对 classifier 分离的原生强制；工具的分离守卫另做跨组校验（见 classifier 节）。

运行时日志里的 `n`/`held`/`classified` 与数组形式的 `when` 是日志表示法，不是配置写法，见 [concepts.md](concepts.md)。

## member 写法

来源：实测+CLI（嵌套部分另见官方文档「路由组里放路由组」）。

- `provider/model`：标准引用。裸名仅当唯一供应商提供该模型时可用。
- `:effort`：固定成员强度，集合 **`none/minimal/low/medium/high/xhigh/max`**。（旧文档的 `ultra` 是错的，且缺 `minimal`，已修正。）**可省略**——省略即按**组的 `effort`** 推理（`agent` 默认＝按 agent 要求的强度；`auto`＝classifier 每回合选的强度），CLI 帮助原文 `without one it reasons as the group's effort says`。同组内可混「带后缀」与「不带后缀」的成员（真实配置实测）。
- `:fast`：**CLI 输入糖**，不是持久化形态——`models=<m>:high:fast` 落盘为 `members:["<m>:high"]` + `fast:["<m>:high"]`（实测）。手写 `members:["<m>:fast"]` 会被当字面 id 跳过，要表达 fast 模式请用 `fast` 数组。
- `:low+high`：多级写法。`:fast`：厂商快速模式。`#account`：钉绑账号/key。
- 同一模型两个强度 = 两个成员（如 `acme/code-standard:low` 与 `acme/code-standard:high`）。
- `group/<id>`：嵌套子组，规则见下节。
- glob / `re:` 模式：**写在独立的 `match` 数组里，不是 `members`**（见下节）。

工具校验模型引用时剥 `:effort`/`:fast`/`#account` 后缀比对已知模型清单，组引用单独解析。边界：若某模型真实名字恰以档位词结尾，剥后缀可能误判——罕见，遇到时以本机实测为准。

**真实配置里的空值**（实测 magpie 0.1.4130）：magpie 自建/被移除的组（形如 `auto-<model>`）落盘时 `members` 是 **`null`**；`rules` 则通常**整个键省略**（实测一台机器 12 组：`members:null` 2 个、`rules:null` **0** 个、`rules` 键缺失 11 个；删掉最后一条规则也是删键而非置 null）。pattern-only 组的 `members` 同样是 `null`。

读配置的工具必须把这几种都按「空」处理而不是直接取长度，否则会崩。本仓库：`validate.py` 对 `members:null` 按空处理，`members` 与 `match` 皆空时报 `needs members or match`——但 **`hidden:true` 的墓碑豁免**（那是 magpie 有意保留的「保持已移除」状态，见 group 字段表）；`rules:null` 报 `rules: must be list`；`doctor.py` 按 0 计数照常诊断。

真正需要清理的是**既不 hidden 又空**的组（留着当兜底会路由不到任何模型）；`auto-` 墓碑不要删，删了 magpie 会把自动组重新发现出来。

### 模式成员（`match`，已实测确证）

模式**不在 `members` 里**，而是与它并列的独立数组 `match`。magpie 自己写出来的形态：

```jsonc
{"id": "pat", "members": null, "match": ["acme/*"]}                    // 纯模式组
{"id": "mix", "members": ["acme/judge"], "match": ["acme/*"]}          // 命名 + 模式
```

**手写模式进 `members` 不生效**：`{"members": ["acme/*"]}` 会被当成字面模型 id，`magpie group <id>` 显示 `not served now, skipped`。校验器会直接报错拦住这种写法。

语法与匹配语义（magpie 0.1.4130 实测，CLI 展开计数 + 落盘 JSON 双证）：

| 写法 | 行为 |
|---|---|
| `acme/*` | glob 通配符就是 `*` |
| `*-chat` | **跨供应商**匹配（不限于某个 provider） |
| `ACME/*` | glob **大小写不敏感** |
| `acme*chat` | `*` **跨 `/`**（不局限于单段） |
| `re:acme/.*` | `re:` 后是完整正则 |
| `re:lite-chat` | **匹配 0 个**——匹配对象是 `provider/model` **全 id**，不是裸名 |
| `re:acme` | **匹配 0 个**——全 id **锚定**，不是部分匹配 |
| `re:ACME/.*` | `re:` 默认**大小写不敏感** |
| `re:(?-i)ACME/.*` | `(?-i)` 开启大小写敏感 → 匹配 0 个 |
| `group/*` | **匹配 0 个**——模式不匹配组 |

顺序与去重：命名成员在前（保序），模式命中的模型按 `magpie models` 顺序追加；同一模型不重复。`models+=<pattern>` / `models-=<pattern>` 增删的是 `match` 元素，不动 `members`。

**局限（工具与本文档都不覆盖）**：
- 校验器**不展开模式**，所以「模式是否把 classifier 模型拉进了路由组」查不出来。`acme/*` 这类宽模式会连 classifier 模型一起匹配进来，与 classifier 分离原则冲突——用窄模式，或把 classifier 放在**独立供应商**（真实配置就是这么做的）。
- 同理，组含 `match` 时，`weights`/`fast`/`ultra`/`pick` 的元素**可以引用模式展开出来的模型**（magpie 接受，实测），校验器此时只查「模型已知」，不做成员资格判定；无模式的组才严格查成员资格。
- 模式展开后的成员如何参与实际路由**未实测**（需起 gateway 发请求）。

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
| `drain` | 一个账号/key 用到额度用完再换下一个，并一直用它；前面的恢复了也不切回。**成员顺序 = 使用顺序**（第一个先用完），因此与 `order` 同属「order 类」；这条是从官方文档那行的顺序语义**推出来的**，本仓库未实测（见待验证清单） | 官方文档 + 推论 |
| `rotate` | 每发一条消息交给下一个成员的账号/key；工具调用留在同一个上 | 官方文档 |
| `usage` | 剩余额度最多的账号/key 排第一 | 官方文档 |
| `pace` | 每周剩余额度 ÷ 距重置小时数，最高者优先；到期前用完，减少重置浪费 | 官方文档 |
| `weight` | 按权重比例分配、均匀穿插（权重 3 每拿 3 个，权重 1 拿 1 个）；休息中的成员退出本轮、下一成员兜底；权重经 group **`weights`** 设置（值形态见上方字段表，已实测） | 官方文档+CLI+实测 |
| `fast` | 最近回答最快（首字时间/输出速度）的成员优先；相差不到一成保持原序 | 官方文档 |
| `cheap` | 此刻最便宜的成员优先（每百万 token 价格 × 倍率，含高峰计价）；仅限路由组 | 官方文档 |
| `free` | **Free first**：先把「算作免费」的供应商/模型花掉，再动付费的。哪些算免费由**供应商级** `countFree`（CLI `magpie provider set <id> free=yes`）标记；价格与 Usage 成本仍按原值显示。`free` 也是供应商级 routing 值之一 | 实测（落盘 `countFree:true` + 厂商自述帮助文本）；运行时选路未实测 |
| `expiring` | 免费额度优先、最先到期的先用；免费额度用尽才用付费 | CLI |
| `manual` | 只路由到你选定的模型（`pick=<model>`，或在组卡片上点选）；其他成员与规则等待，直到另选或改路由，**不做故障转移** | CLI |

`manual` 在 routing 枚举内（旧文档「11 模式、manual 不在枚举内」是错的）；手动选择经组级 `pick` 字段（单个完整成员引用，含 `:effort`；值形态见上方字段表，已实测）。

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
| 默认兜底 | 无字段 | 未命中任何规则 → 按组的 **routing 模式**路由（`order`/`drain` 按成员顺序、首成员先用；`usage` 按额度分摊、`weight` 按权重、`rotate` 逐条轮转）。不是 compact |

**不强制 `compact:true`**——工具要求每组 **`members` 或 `match` 至少一个非空**（不只含 rules 的组；`hidden:true` 墓碑豁免）；兜底按组 routing 模式走。旧文档「必须含 compact:true 兜底规则」的说法已作废。

## 默认兜底与规则命中

来源：实测+CLI。旧文档把「默认兜底 = 成员顺序/首成员」当普适规律并归于官方文档，是失真，已纠正。

- 一条规则都不命中（含 classifier 答「都不是」、超时、出错）→ 组**按自己的 routing 模式**路由这一轮：`order` 首成员优先，`usage` 按剩余额度分摊，`weight` 按权重等。写作建议「把默认模型放 members 首位」**仅对 order 类模式成立**；对 `usage` 子组（如 g-test/g-light）不成立。
- 规则命中 → 目标模型置首，其余成员随后做故障转移（仍按组 routing 模式）；目标无可用 key/账号时回退其余成员。

## classifier（意图判断，独立角色）

- 字段值为 `provider/model` 或 `group/<id>`（实测+CLI，CLI help 与二进制均支持组）。**分歧标注**：官方意图页说「不能是组」是滞后的——功能以 CLI/实测为准，不要声称官方文档支持组 classifier。
- 调用参数：自动取最低推理档（支持 `none` 用 `none`，否则最低档）、temperature 0、max_tokens 2048、不流式（实测+文档）。
- 每回合问一次（仅新轮首个请求触发，工具往返沿用决定）；只发当前这条消息，不含整段对话；超时默认 8 秒；出错/超时/无答案 → 意图条件不命中，按其他规则走（官方文档）。
- `intentSure`（0..1，默认 0.4）为意图置信阈值（实测）。
- **分离硬约束**：classifier 只做意图判断，**绝不**进任何路由组的 `members` / 规则 `use` / `more` / 兜底。工具设**跨组**分离守卫：先收集所有组的 classifier 模型（classifier 是模型时取其 base 名；是 `group/<id>` 时递归解析该组的成员模型），再检查每个**非 classifier 池**的路由组——其成员/规则目标命中任一 classifier 模型即拒。classifier 池自身的成员豁免（它们就是分类器）。这与 AGENTS.md 的「跨组分离守卫」一致。
- **magpie 原生强制（实测）**：一个组的成员要么全是 decision model（分类器），要么全是会话模型，不能混，否则 magpie 拒绝保存。这是组级的原生分离强制，与工具的跨组分离守卫互补。
- 选模型建议：小而快、不带推理（官方文档）。它与 fast/cheap 路由角色是两回事——后者是正常路由成员，承担轻量任务与兜底。

### classifier 只在有「消费者」时才落盘（实测，CLI 写入路径）

组里必须有**消费者**——至少一条 `intent` 规则，**或** `effort:"auto"`——classifier 才会被写进配置：

| 操作 | 结果 |
|---|---|
| `group add g models=… classifier=<m>`（无消费者） | exit 0、无任何报错，**classifier 被静默丢弃** |
| `group set g classifier=<m>`（无消费者） | 同上，静默丢弃 |
| `group add/set g effort=auto classifier=<m>` | **落盘**（参数顺序无关） |
| `group rule add g use=… intent=… classifier=<m>` | **落盘** |
| 组已有 intent 规则时 `group set g classifier=<m>` | **落盘** |

反向缺 classifier 是**硬报错**（exit 1），不是静默：
- `effort=auto` 单给 → `effort picked per turn needs the group's classifier: …`
- intent 规则不带 classifier → `a rule with an intent needs the group's classifier, …: add classifier=<model>, best a small fast one`
- `group rule classifier <g> <m>` 而组无 intent 规则 → `<g> has no rule with an intent to classify for`

**消费者消失时 classifier 被一并删除**：删掉唯一的 intent 规则、或把 `effort` 从 `auto` 改回 `agent`，`classifier` 键随之消失（实测）。

CLI 命令名注意：是 **`magpie group rule add …`**，没有顶层 `magpie rule add`（后者报 `unknown agent "rule"`）。`classifier=group/<id>` 可用，但写入时校验目标组存在。

> 以上是 **CLI 写入路径**的行为。手写 JSON 里「有 classifier 但无消费者」会怎样**未实测**，故校验器不对此报错——但按上表，这种配置在 magpie 侧没有意义，别这么写。

## provider 级：与角色映射相关的字段（实测）

路由层之外，探测供应商时会看到几个与**选型**有关的字段。形态来自本机配置解析（只取字段名与类型，不读密钥）+ CLI 写入探针；**`countFree` 仅见于后者**（本机无供应商填它）：

| 字段 | 形态 | 对选型的意义 |
|---|---|---|
| `models` | **裸名字符串数组**（可含冒号，如虚构示例 `cn:coder-a`） | 只有名字，**没有**多模态/推理档等能力元数据；引用时按供应商 id 拼成 `provider/model` |
| `contexts` | 对象：**模型名 → 上下文长度整数**（可用 `"*"` 通配全部模型） | `context/long` 角色对**被覆盖到的模型**可直接据此判断窗口（含 `*` 通配）；**未列出的模型仍须问使用者或查文档**。并非每家都填，也可能只覆盖该供应商的一部分模型（实测有一家 5 个模型只列了 1 条） |
| `pickedFrom` | 字符串数组 | 目录候选来源，不是能力元数据 |
| `catalog` | 字符串 | 目录标识，不是能力元数据 |
| `countFree` | bool | 标记「算作免费」的额度，供 routing `free`（Free first）先花 |

**因此**：`templates/roles.json` 的 `signals.needs` 里，上下文窗口优先查 `contexts`；多模态与推理档仍需向使用者确认，**禁止从模型名臆断**。

## 待验证清单

**未解决（2026-11-18 登记）**：**`drain` 是否真的按成员顺序取首个可用**。本仓库把 `drain` 计入「order 类」——`doctor.py` 的 `ORDER_LIKE`、组行的 `first=` 读数、首位类形状判据都建立在它上面——依据是上面 `drain` 行那套「用到额度用完再换下一个」的顺序语义**推论**，没有真机实测。要定案需按本文件末节的隔离三件套做真机探针；在此之前，`drain` 组上的首位类提示按「未实测的推论」读。

**已解决**（原清单移除）：

1. ~~规则 use 能否指向组~~ → 组中组已证实（members/use 可为 `group/<id>`，≤8 层禁自包含）；`more` 同理，且 use/more 必须是本组成员（magpie 原生强制，实测）。
2. ~~affinity 配置入口~~ → 已定位：组级 JSON 字段 `affinity`（CLI 别名 `stays`）。
3. ~~图像生成路由~~ → 生图独立于路由层：走设置 Image generation + MCP 工具，不进 groups 路由。
4. ~~classifier 可选范围~~ → 任意 `provider/model` 或 `group/<id>`（官方意图页滞后，见 classifier 节）。
5. ~~规则 `when` 字符串字段~~ → **反转**：JSON 字段是 `where`（`[{field,op,value}]` 对象数组）；`when` 只是 CLI 旗标与日志表示法（实测）。
6. ~~`time`/`days`/`tz`/`except-folders`/`pause` 写法~~ → `time` 是对象 `{from,to,days,zone}`；`exceptFolders` 驼峰；`pause` 为 `{use:<model>, pause:true}`（实测）。
7. ~~`at`/规则级 `classifier`~~ → CLI 便利写法（插入位置 1-indexed / 设组级 classifier），不是 rule JSON 字段。
8. ~~`weight`/`fast`/`ultra`/`pick`/`listed`/`family` 的 JSON 字段名~~ → 已结清：真键名是 `weights`/`unlists`（见第 13 条反转），值形态见字段表。
9. ~~routing `free`/`expiring` 存在性、`expiring` 语义~~ → 二进制确证存在；`expiring` = 免费额度优先、最先到期先用（CLI 示例）。`free` 语义已结清（见第 14 条与 routing 表）。
10. ~~组级 `effort:"agent"` 语义~~ → CLI 已定义：每个请求按 agent 要求的强度推理，但以成员自身 `:<effort>` 为限（默认 `agent`）。
11. ~~`manual` 模式~~ → routing 12 值含 `manual`，经 `pick=<model>` 使用。
12. ~~默认兜底~~ → 纠正：按组 routing 模式路由，不是普适的成员顺序/首成员。
13. ~~组级 `weight`/`fast`/`ultra`/`pick`/`listed`/`family` 的值形态~~ → **反转**：`weight`/`listed` 不是 JSON 字段名，真键名是 `weights`（成员引用→1..1000 整数映射，键含 `:effort`）与 `unlists`（bool）；`fast`/`ultra` 是字符串数组、`pick`/`family` 是字符串。写路径落盘 + 读路径回显双向实测。
14. ~~routing `free` 语义~~ → Free first（先花 `countFree` 标记的免费额度），见 routing 表。
15. ~~顶层 `noAutoGroups`~~ → 布尔 `true` 关闭自动发现的组，自建组不受影响；`group auto on` 删除该键。
16. ~~glob/re: 语法~~ → 全部确证，且**模式在独立的 `match` 数组**而非 `members`，见「模式成员」节。
17. ~~classifier 的 CLI 写入条件~~ → 需消费者（intent 规则或 `effort:"auto"`），否则静默丢弃；反向缺失硬报错，见 classifier 节。
18. ~~成员 `:fast` 后缀 vs `fast` 数组~~ → `:fast` 是 **CLI 输入糖**，写入时规范化进 `fast` 数组；手写进 members 不生效（实测）。运行时等价性仍未测。
19. ~~`fast`/`ultra`/`pick` 是否要求元素为本组成员~~ → **要求**，且与 `weights` 同规矩：完整成员引用（含 `:effort`），CLI 非成员硬报错、JSON 路径静默忽略（实测）。

**仍待核**（agent 不要当作已支持特性写进配置）：

1. **模式展开后的运行时路由行为**：`match` 命中的模型如何参与实际选路未实测（需起 gateway 发请求）。语法与展开计数已确证。
2. **`free` / `expiring` 的运行时选路**：语义已确证（厂商自述 + `countFree` 落盘），实际发请求时的选择顺序未实测。
3. **`:fast` 与 `fast` 数组的运行时等价性**：写入路径的规范化已确证，发请求时是否完全等价未测。
4. **手写 JSON 里「classifier 无消费者」**：CLI 写入路径会丢弃；手写的会被 magpie **读路径保留并显示**，但是否真被采纳未实测——校验器因此不对此报错。
5. **`routing: usage` 与 `affinity: session` 叠加时的分配行为**：上表 `session` 行说新会话「按当前最少并发分配」，那它与 `usage` 的额度分摊同时生效时谁优先、没有额度读数的成员如何参与，都未实测。两者共存合法（工具只校验枚举），`templates/groups.template.json` 的便宜层两组就是这么配的——写它的 note 时只声明了「会话内不换通道」这一条已确证的部分。

若你的实测回答了其中任何一项，欢迎补充本文档（标注你的 magpie 版本与证据）。

## 实测方法：假 HOME 不足以隔离（重要）

本机若正跑着 magpie app，**只设 `HOME=<临时目录>` 不能隔离**：CLI 按默认端口探测活实例，会连上**真实** gateway 并可能改到真实配置。实测：假 HOME 下 `magpie status --json` 仍返回真实进程的 `running:true` 与 pid。

安全探针三件套：

```bash
FAKE=$(mktemp -d); mkdir -p "$FAKE/.config/magpie"   # 放虚构 providers.json（模型用裸名）
export HOME="$FAKE" MAGPIE_ADDR=127.0.0.1:1          # 死端口 → 强制纯文件模式
magpie status --json                                 # 必须断言 running:false 才继续
```

（也可用 `sandbox-exec -n no-network` 从网络层切断。）本仓库 `scripts/e2e.sh` 只用假 HOME 夹具跑自家 python 脚本、**不调用真实二进制**，因此不受此影响；若将来加真实二进制用例，必须补上 `MAGPIE_ADDR` 与 `running:false` 断言。