# 路由概念

> 本文以 [magpie 官方文档](https://usemagpie.ai/docs/zh)与 magpie CLI 为权威，经本机实测校验（字段级来源与校验标注见 [schema.md](schema.md)）。

## magpie 是什么

本机 macOS 桌面 AI 路由网关：把你的编码 agent（Claude Code、Codex 等）的请求，按你定义的策略路由到不同供应商的不同模型。价值在于**按任务类型选模型**——难题用强模型，琐事用便宜模型。

## 两层路由（本仓库的主架构）

主路由只做**意图判断 → 分发子组**；子组做**模型选择、故障转移、额度分摊**。

```text
agent（编码助手）
  └─ 主路由组（如 auto）
       ├─ classifier：意图判断（独立角色，只判意图，不答请求）
       ├─ rules：compact 规则第 1 条 + 各 intent 规则
       │    └─ use → group/g-xxx（任务子组）
       └─ members：各任务子组（主路由用 order，首成员 g-code = 默认兜底）
            └─ 任务子组（g-code/g-test/g-light/g-heavy/g-arch/g-ui/g-review/g-compact）
                 ├─ members：模型[:effort]、同模型多通道、可再嵌套组
                 ├─ routing：池路由模式（usage/order/…，成员间分摊）
                 └─ rules：故障转移（use + more，有序降级）
```

- 组可嵌套（members 与规则 use/more 可为 `group/<id>`）：≤8 层、禁直接/间接自包含；每层按自己的 routing/rules 路由，外层不伸进子组；子组全失败才轮外层下一成员。
- 单层（组内直接放模型 + intent 规则）仍可用，但表达不了「每类任务一个模型池」；模式见 [patterns.md](patterns.md)。

## 核心概念

| 概念 | 含义 | 本仓库是否涉及 |
|---|---|---|
| provider | 供应商连接（endpoint、key、模型清单） | 只探测引用，**不生成不修改** |
| group | 路由组：members + rules + classifier + routing/affinity 等 | 核心交付物 |
| rule | 一条路由规则（use/more/intent/effort/compact/useEffort/where 等） | 核心交付物 |
| classifier | 意图判断模型，独立角色，见下节 | 组级字段 |
| routing | 池路由模式：成员间如何分摊请求（12 值，含 manual） | 组级字段 |
| affinity | 会话粘性：同会话后续请求沿用同一模型/账号（利用 prompt cache），5 值，默认 auto | 组级字段（已定位，CLI 别名 stays） |

## 池路由 vs 故障转移

两套机制，目的不同，可叠加：

| | 池路由（routing） | 故障转移（use=a,b / more） |
|---|---|---|
| 目的 | 成员间**分摊**请求（额度、成本、速度） | 失败时**有序降级** |
| 写法 | 组级 `routing:"usage"` 等 12 模式 | 规则 `use` + `more` 数组（CLI `use=a,b` 展开为 use=a + more=[b]） |
| 顺序含义 | 按模式语义排序/轮转（如 usage 按剩余额度） | 严格按数组顺序尝试 |

规则命中时目标置首、其余成员随后做故障转移（官方文档+CLI）。子组作为成员时同理：子组全失败才轮外层下一成员。**能力相近的成员用 usage 分摊；有高低档的用 order 降级；强弱不同的勿放 usage/rotate**（弱模型会平摊流量，质量不稳）。

## compact vs 默认兜底

三个东西同名不同物（详见 [schema.md](schema.md)「compact 三义」）：

- 规则 `compact:true` = **压缩触发条件**：Agent 压缩上下文时命中，把总结流量导给便宜/长上下文模型。
- 组级 `compact:<number>` = 压缩阈值（token 数）。
- **默认兜底** = 未命中任何规则时按组的 **routing 模式**路由（`order` 才是首成员优先；`usage` 按剩余额度分摊、`weight` 按权重等），不需要任何字段。

因此**不强制** `compact:true`；工具要求每组 **`members` 或 `match` 至少一个非空**（`hidden:true` 墓碑豁免）。「把默认模型放成员首位」仅对 order 类模式成立，对 usage 子组（如 g-test/g-light）不成立。

## classifier：独立角色（硬约束）

classifier 只做意图判断，**绝不**进 members / 规则 use / more / 兜底（工具设分离守卫）。它与 fast/cheap 路由角色必须分开：后者是正常路由成员，承担轻量任务与兜底。magpie 也在组级原生强制：一个组的成员要么全是 decision model（分类器），要么全是会话模型，不能混，否则拒绝保存（实测）。

- 可为 `provider/model` 或 `group/<id>`（CLI/实测支持组；官方意图页「不能是组」的说法滞后，功能以 CLI/实测为准）。
- 调用自动取最低推理档、temperature 0、max_tokens 2048、不流式；每回合问一次，只发当前这条消息；超时默认 8 秒，出错/超时 → 意图不命中，按其他规则走。
- `intentSure`（0..1，默认 0.4）：意图置信阈值。
- 组级 `effort:"auto"`：由 classifier 每回合选推理强度（需 classifier）——与 classifier 自身调用自动最低档是两回事。
- 选小而快、不带推理的模型；意图别写太细，保持互斥。
- **classifier 需要「消费者」才会落盘**（实测）：组里至少一条 `intent` 规则，或 `effort:"auto"`。没有消费者时，CLI 的 `classifier=` 被**静默丢弃**（exit 0，无报错）；反过来有消费者却缺 classifier 是**硬报错**。删掉最后一个消费者，classifier 键也会被一并删除。细节与命令见 [schema.md](schema.md) classifier 节。
- **宽模式会破坏分离**：`match: ["acme/*"]` 会把同供应商的 classifier 模型一起匹配进路由组。校验器不展开模式、查不出这种冲突——用窄模式，或把 classifier 放在独立供应商。

## affinity：会话粘性

同会话沿用同一模型/账号以利用 prompt cache，省钱省延迟。组级字段 `affinity`（CLI 别名 `stays`），默认 `auto`（一轮内总保持，跨轮在缓存值得保留时保持）；另有 `session`/`turn`/`off`/`strict`，语义表见 [schema.md](schema.md)。`strict` 宁报错也不换账号，慎用。

## 配置与运行时日志的区别（重要）

**配置写**：`intent` / `effort` / `compact` / `useEffort` / `where`（对象数组）等。

运行时日志里规则会展开成 `{n, use, when, turn, ...}`：`intent:"X"` 显示为 `when:["intent \"X\""]`，`effort:"on"` 显示为 `when:["reasoning"]`。**日志里的 `n`/`held`/`classified` 以及数组形式的 `when` 是运行时表示法，不要照抄进配置。**

`when` 同名三义，注意区分（**旧结论反转**：旧文档说「配置里的 `when` 是合法字符串条件字段」——错误，JSON 配置字段是 `where`）：

- **CLI 旗标** `when="<field> <op> <value>"`：便利写法，可给多条且须全满足。
- **JSON 配置字段是 `where`**：对象数组 `[{field,op,value}]`，magpie 把 CLI `when=` 写成这个形态（实测）。如 `when="tokens < 20k"` → `{"field":"tokens","op":"lt","value":"20000"}`；`when="message contains run the tests"` → `{"field":"message","op":"contains","value":"run the tests"}`。field ∈ tokens/effort/agent/subagent/message/system/last，详见 [schema.md](schema.md)。
- **运行时日志 `when`**：数组（意图/推理的展开）。

把字符串 `when` 写进 JSON 不是合法字段：magpie 静默忽略，本仓库校验器直接拒绝（`when` 不在白名单）；校验器对 `where` 做结构校验（`{field,op,value}` 数组）。模板默认不使用 `where`。

**同一类陷阱在组级也有**（实测）：CLI `weight=<model>=<n>` / `listed=no` 的 JSON 真键名是 **`weights`** / **`unlists`**；glob/`re:` 模式要写进独立的 **`match`** 数组而不是 `members`。写错键名 magpie **静默忽略**，写错类型则**整份配置解析失败**（且 CLI 退出码仍是 0）。详见 [schema.md](schema.md)。

## agent 入口：组配好了不等于生效（重要）

上面两层结构都在**网关侧**。还有一层在**客户端侧**：agent 这一轮交给网关的是「组」还是「一个具体模型」。交具体模型时**组级的一切都不参与**——`classifier`、意图规则、组内 `members` 与故障转移链都不查；路由日志里那一轮的 `group` 与 `rule` 都是 `null`（实测直连记录里 `rule` 无一非空）。交组时才有 `group.id`。

**但旁路的只有组级设置，不是 magpie 的全部动作**（实测，magpie 0.1.4178）：直连记录里 `swapped=true` 占多数（换账号 / 换替身照样发生），`affinity` 记账照旧、`cacheRead` 照样非零（**粘性在直连会话上一样省缓存**），`order` 里也会出现跨供应商候选；不变的是**单次请求内不重试**（`tries` 恒为 1）。别把「直连」理解成「什么都不会发生」，也不要拿「走组才有缓存收益」去算成本。

**所以验收顺序是反的**：先确认入口，再评价组配得好不好。三个读数（都只读）：

- `magpie ls` 列出各 agent 的接线与落点文件；`magpie <agent>` 显示单个 agent——实测只有一行（主 model、`effort`、落点文件），**不会把各档列出来**。
- 直接读 agent 自己的配置文件（例如 `~/.claude/settings.json` 里的 `ANTHROPIC_DEFAULT_*_MODEL`）。**`~/.config/magpie/applied.json` 是陈旧账本**：里面常留着早已失效的引用（比如指向一个已经不存在的组），不能当现状。
- `~/.config/magpie/routing/<日期>.jsonl`（历史按天压成 `.jsonl.gz`，只有当天是明文）：时间字段是 **`time`**；走组时组名在 `group.id`。**但单行 `group=null` 不足以断定入口是具体模型**：实测有一批 `kind:"vision"` 的记录，`for.model` 明明是 `group/<id>` 却被记成 `group:null` 且 `for.unknown:true`。判覆盖面看接线，别只看某一轮。

四条实测陷阱：

1. **两参数形式 `magpie <agent> X` 的含义取决于 `X` 是不是该 agent 的字段名**：是 → 显示该字段；不是 → **把主 model 设成 `X`**（magpie 不校验 `X` 是否存在）。两处都是这么踩的：`magpie claude opus` 会写出 `"model": "opus"`（`opus` 又是 agent 自己的别名，设了就等于让 magpie 退出该 agent，**断线**）；`magpie codex run` 会写出 `model = "run"`——只有 `claude` 有 `run` 这个启动器子命令。拿不准就用单参数形式 `magpie <agent>`。
2. `magpie <agent> <field> default` 把该字段恢复默认。对 claude 的 `opus`/`sonnet`/`haiku`/`fable`，默认＝回到主 model；对其它字段（如 `effort`）＝该字段自己的默认值，跟主 model 无关。
3. 改接线**只影响新会话**：已运行的进程不重读 env。claude 可以用 `magpie claude run [args…]` 起一个真走接线的会话做验收；其它 agent 没有这个子命令，直接重启那个 agent。
4. 组级 `affinity` / 意图规则 / 锚定成员只作用在**走组**的那几轮上。评测缓存收益前先按上面三个读数划清覆盖面——直连那部分有自己的粘性收益，只是拿不到意图分发与故障转移。

## 实测本机配置时的隔离（重要）

本机若正跑着 magpie app，**只换 `HOME` 不能隔离**——CLI 按默认端口探测活实例，会连上真实 gateway。安全探针要加 `MAGPIE_ADDR=127.0.0.1:1`（死端口）并**先断言 `magpie status --json` 的 `running` 为 `false`** 才继续。完整方法见 [schema.md](schema.md) 末节。本仓库 e2e 不调用真实二进制，只用假 HOME 夹具跑自家脚本。