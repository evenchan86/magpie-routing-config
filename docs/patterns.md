# 路由模式库

主模式是**两层意图分发**（模式 1），子组模式（2–5）决定每个任务池内部怎么路由；通用模式（6–13）里 6–12 是旧 7 模式按官方口径的校正版、13 是新增的成本/缓存模式，单层/两层都可用。字段语义与来源见 [schema.md](schema.md)，概念见 [concepts.md](concepts.md)。

示例一律用虚构供应商 `acme/*`（含 `acme-cn`/`acme-global`，判断模型 `acme/judge`），模型名仅为示意；实际按 `templates/roles.json` 映射到你本机模型。`templates/groups.template.json` 是两层骨架的角色占位版。

## 主模式

### 1. 两层意图分发

**意图**：主路由只做意图判断，分发到按任务类型划分的子组；子组内部负责模型选择、故障转移、额度分摊。每类任务一个模型池，池与池的故障转移链、额度分摊互不牵连。

**但「池隔离」不等于「模型隔离」**：若按模式 13 给主链锚定（本仓库模板就是这么配的），会话稳态下主链各组服务的是**同一个**锚模型，隔离只剩「故障转移尾巴的差别」。要每个意图真正用上不同模型/不同强度，就别给那个组锚定——两种取法各自成立，别混着一句写。

**前置条件**：agent 那一轮交给网关的必须是 `group/<id>`。入口若是一个具体模型，**组级的一切都不参与**——classifier、意图规则、子组、组内故障转移链全部跳过，路由日志里那一轮的 `group` 与 `rule` 都是 `null`（组级 `affinity` 设置也用不上，但 magpie 对直连轮仍保持自己的粘性，别按「直连没有缓存收益」去算成本）。先按 [concepts.md](concepts.md) 的「agent 入口」一节确认覆盖面，再来调组。

**结构**：主路由组（classifier + compact 规则第 1 条 + intent 规则 use=group/g-xxx + 子组成员）+ 8 个任务子组。

下表是 `templates/groups.template.json` 现在的形状：**粘性列是模板现值**，「建议 routing」列给的是**可选范围**（模板只取其中一种，如 `g-compact` 模板里固定 `order`）。「建议角色」里的**锚** 与粘性列的取舍见模式 13：

| 子组 | 任务 | 建议角色 | 建议 routing | 粘性 |
|---|---|---|---|---|
| `g-compact` | 压缩/摘要（compact 条件，不是意图） | context/long + fast/cheap | order 或 usage | 不设 |
| `g-test` | 写测试或修失败的测试 | 锚 code/general（唯一成员的**角色**是锚；渲染后该角色展开成主力+备用） | usage | `session` |
| `g-light` | 简单问答、查文档或命令 | fast/cheap + context/long（刻意不锚） | usage | `session` |
| `g-code` | 实现新功能或修局部 bug（**默认**） | 锚 code/general + fast/cheap 备用（同档） | order | `session` |
| `g-heavy` | 重构、迁移或跨文件大改动 | 锚 code/general + reasoning/strong（同档） | order | `session` |
| `g-arch` | 架构设计、方案选型或疑难排查 | 锚 code/general + reasoning/strong + context/long（同档） | order | `session` |
| `g-ui` | 前端界面、样式或视觉还原（含截图） | design/ui + code/general 备用 | order | 不设（见模式 13） |
| `g-review` | 审查代码或 review 改动 | 锚 code/general + context/long（同档） | order | `session` |

主路由示例（子组内部写法见模式 2–4）：

```json
{
  "id": "auto",
  "name": "主路由 · 意图分发",
  "routing": "order",
  "classifier": "acme/judge",
  "members": [
    "group/g-code",
    "group/g-test",
    "group/g-light",
    "group/g-heavy",
    "group/g-arch",
    "group/g-ui",
    "group/g-review",
    "group/g-compact"
  ],
  "rules": [
    { "use": "group/g-compact", "compact": true },
    { "use": "group/g-test", "intent": "写测试或修失败的测试" },
    { "use": "group/g-light", "intent": "简单问答、查文档或命令" },
    { "use": "group/g-code", "intent": "实现新功能或修局部 bug" },
    { "use": "group/g-heavy", "intent": "重构、迁移或跨文件大改动" },
    { "use": "group/g-arch", "intent": "架构设计、方案选型或疑难排查" },
    { "use": "group/g-ui", "intent": "前端界面设计或还原截图" },
    { "use": "group/g-review", "intent": "审查代码或 review 改动" },
    { "use": "group/g-heavy", "effort": "on" }
  ]
}
```

**要点**：

- **compact 规则第 1 条**：压缩流量最先被分流到 g-compact，不占任务池。
- **默认靠组的 routing 模式**：未命中任何规则（含 classifier 判「都不是」/超时/出错）→ 按主路由的 routing 模式路由；示例用 `order`，按成员顺序尝试，`g-code` 排第一即默认。**不需要 compact:true 兜底规则**。若改用 `usage`/`weight` 等，兜底按额度/权重分摊，「首成员 = 默认」不再成立（g-test/g-light 这类 usage 子组没有首成员默认）。
- **classifier 独立**：`intent/judge` 角色只做意图判断，绝不进 members/规则/兜底（模式 5）。
- **推理升级（可选）**：主路由末尾可加一条 `{"use": "group/g-heavy", "effort": "on"}`（模板如此），把需要深思的请求升级；也可用子组成员 `:effort` 表达。
- **互斥划界**：「实现新功能」强调功能逻辑，「前端界面」强调视觉/样式；修失败测试归测试，修产品代码归实现。
- **取舍**：classifier 有延迟（官方超时默认 8 秒，可调），失败时意图不命中、落默认——意图别写太细，保持互斥；判断模型要小而快、不带推理。
- 嵌套约束：≤8 层、禁直接/间接自包含；子组全失败才轮主路由下一成员。

## 子组模式

### 2. 子组池模式（order vs usage）

**意图**：子组内部在成员间分摊请求或有序降级。

| 成员构成 | 选 | 理由 |
|---|---|---|
| 能力相近（同档模型/同模型多通道） | `usage` | 按剩余额度分摊，防单通道耗尽 |
| 有高低档（强模型 + 弱备用） | `order` | 强的先用，答不了再降级 |
| 想用完一个再换 | `drain` | 额度耗尽才切，不切回 |
| 同档按比例分配 | `weight` | 权重经组级 **`weights`** 设置（成员引用 → 1..1000 整数，键含 `:effort`）。**`weight=` 只是 CLI 旗标**，写进 JSON 会被静默忽略，见 schema.md |

**强弱不同的成员勿放 `usage`/`rotate`**——弱模型会平摊/轮转到流量，质量不稳。另注意：`usage` 子组（如 g-test/g-light）兜底按剩余额度分摊，**没有「首成员 = 默认」**；首成员兜底只对 order 类模式成立。

```json
{
  "id": "g-code",
  "name": "实现 · 编码",
  "routing": "usage",
  "members": ["acme/code-standard:medium", "acme-cn/code-standard:medium"]
}
```

### 3. 每模型强度（成员 :effort）

**意图**：同一模型在不同任务池用不同推理强度，按任务定强度而不是全局一刀切。

**写法**：成员后缀 `:effort`，集合 `none/minimal/low/medium/high/xhigh/max`（旧文档的 `ultra` 是错的）。同模型两强度 = 两成员；`:low+high` 多级。**`:fast` 只是 CLI 输入糖**——手写进 JSON 的 members 会被当字面模型 id 跳过，JSON 里要用独立的 `fast` 数组（见 schema.md）。

```json
{
  "id": "g-arch",
  "name": "架构 · 高强度",
  "routing": "order",
  "members": ["acme/strong-reasoner:xhigh", "acme/strong-reasoner:high"]
}
```

规则级 `useEffort`（`low/medium/high/xhigh/max`）可在命中后整轮覆盖 Agent 要求的强度；成员已固定的强度保留自身设置。

**代价**：同组内混强度意味着「顶班的那一次」整段前缀重付（强度参数在 prompt cache 键里，实测见模式 13 与「落盘与观测的坑」第 1 条）。会话会跨意图互切的那几组因此一律同档；独立池要混就混，那是另一本账（上面那段示例是字面量写法，与模板里的 `g-arch` 无关——模板里它同档）。

### 4. 多通道额度分摊

**意图**：同一模型经多个供应商通道（地域通道、订阅直连、中转）接入，把额度用满、互为备用。

**写法**：同模型多个 `provider/model` 成员；通道顺序表达优先级（`order`/`drain`），同档通道用 `usage` 分摊；`#account` 钉绑账号/key。

```json
{
  "id": "g-code-cn",
  "name": "编码 · 多通道",
  "routing": "drain",
  "members": [
    "acme-cn/code-standard:medium",
    "acme-global/code-standard:medium",
    "acme/code-standard:medium"
  ]
}
```

**取舍**：地域通道按 cn → global → 备用供应商同档模型的顺序降级；**有订阅直连通道时排最前**（额度独立、通常更稳）。备用通道与原模型能力同档或相邻，避免质量骤降。

### 5. classifier 独立

**意图**：意图判断与路由成员彻底分离。

**写法**：`intent/judge` 角色（小而快、不带推理的模型）只填 `group.classifier`；**绝不**进该组 members / 规则 use / more / 兜底（工具分离守卫强制）。classifier 也可为 `group/<id>`（CLI/实测支持；官方意图页「不能是组」的说法滞后）；组级 `effort:"auto"` 可让 classifier 每回合选强度。magpie 原生强制：一个组的成员要么全是 decision model（分类器），要么全是会话模型，不能混，否则拒绝保存（实测）。

**取舍**：classifier 与 fast/cheap 是两个角色——fast/cheap 是正常路由成员（轻量任务 + 兜底），classifier 不答请求。把判断模型塞进路由成员会浪费额度并污染兜底。

## 复现配方：手写配置 → 模板（角色槽 + 字面量 + @effort 混合）

已有一份合意的手写配置，想让它能被模板复现/再生成？三种手段混合，不必全靠角色抽象：

| 手段 | 适用 | 写法 |
|---|---|---|
| 角色槽 | 通用部分、多模型展开 | 模板成员 `<role:X>:effort`，mapping 填有序列表 |
| `@effort` 覆写 | 同组内某模型要不同强度 | mapping 元素 `model@effort`（覆写槽位强度）；带通道写 `provider/model#account@effort`（强度渲染在 `#account` 前）。模型/账号名含 `@` 不会被误当覆写——仅最后一个 `@` 后恰为合法强度才算 |
| 字面量成员 | 逐组差异化选型（如审查组刻意换模型家族） | 模板 members 里直接写 `provider/model:effort`——render.py 对非 `<role:>` 成员**原样透传** |

**要点**：角色→列表是全局映射（同一角色在所有组展开相同），表达不了「审查组用 A 家族、编码组用 B 家族」这类逐组选型——那部分用字面量写死。逐模型强度用 `@effort`，不必渲染后手改。

```jsonc
// 模板片段（虚构 acme）：通用部分用角色槽，审查组差异化选型用字面量
{
  "id": "g-ui",
  "routing": "order",
  "members": ["<role:design/ui>:medium", "<role:code/general>:medium"]
  // design/ui = ["acme/vision-designer@high"] → vision-designer 覆写为 :high
  // 结果：[vision-designer:high, code-standard:medium, code-backup:medium]（同组混强度）
}
```

## 真实案例（脱敏）：一台机器上的两层配置长什么样

下面的结构取自一台真实机器的 magpie 配置（magpie 0.1.4130），**供应商与模型名已全部替换为虚构 `acme/*`**，只保留结构与强度。它比模板多一个子组，正好说明模板是起点不是上限。

**快照边界**：这张表与下面 6 条经验是**同一台机器某一个时刻的读数**（当时强度按任务分档、粘性未设），不是推荐值。强度与 `affinity` 是两个独立旋钮，本仓库现在的取值与这张表并不相同。下面「落盘与观测的坑」写清了每条经验的适用范围，以及真正去改这类配置时会撞上的实测行为。

| 组 | routing | 成员（强度） | 说明 |
|---|---|---|---|
| `auto` | `order` | 9 个 `group/*` | 网关；classifier 为 `acme/judge`（独立供应商） |
| `g-compact` | `order` | `lite-chat:low` | 压缩只需便宜模型 |
| `g-test` | `usage` | 4 个模型，全 `:high` | 模型可互换 → 摊额度 |
| `g-light` | `usage` | `lite-chat:low` + 2 个**无后缀**成员 | 强度可省略 |
| `g-code` | `order` | `code-standard:high`, `code-backup:high` | 有明确主力 → 故障转移 |
| `g-heavy` | `order` | `code-standard:high`, `strong-reasoner:high` | |
| `g-arch` | `order` | `strong-reasoner:max`, `code-standard:xhigh` | 同一模型在此升到 `xhigh` |
| `g-ui` | `order` | `vision-designer:high`, `code-standard:medium` | 同组混强度 |
| `g-review` | `order` | 3 个模型，全 `:high` | 刻意换家族做交叉审查 |
| `g-docs` | `order` | `code-standard:medium` + 2 个 `:high` | **模板外新增**：写文档/教材意图 |

网关 10 条规则：`compact:true` 第 1 条 → 8 条意图（含新增的「撰写文档、教材或知识库文章」）→ `effort:"on"` 末条升 `g-heavy`。**这是当时快照**：同一台机器的后续观测（未记时点）里末条从 `on` 收窄到 `xhigh`（规则里 `effort` 写档位 = 至少该档才命中，见模式 7；`xhigh` 之上还有 `max`，所以这不是「只有顶档才升」）。模板仍用 `on`（任意推理即命中，兜底更宽），两种都合法，选哪个取决于你想让多少请求去强模型组。

**从这份真实配置能读出的 6 条经验**：

1. **强度是「任务 × 模型」的函数，不是模型固有属性**。主力编码模型在 `g-code`/`g-review` 是 `:high`、`g-arch` 是 `:xhigh`、`g-ui`/`g-docs` 是 `:medium`；轻量模型在压缩/轻量组是 `:low`、在测试/审查组是 `:high`。这正是 `@effort` 覆写 + 字面量逃生口要表达的东西——把强度写死在角色上就表达不了。
   **但分档有代价（本机实测）**：同前缀同模型同账号，只把 `thinking.budget_tokens` 从关闭改成 2048 或 8192，`cache_read` 立刻归零、`cache_write` 全量重建 —— **强度参数在 prompt cache 键里**。证据面只有本机一个供应商的单个账号，换供应商需重测。所以只在「成员本来就要换模型」的组之间做强度差异（前缀本就独立）；**会话会跨意图互切的那几组（下称主链）应当一律同档**，否则每跨一次意图就整段前缀重付。范围与例外见本节末「落盘与观测的坑」第 1 条——上面那条「按任务分档」并没有被推翻。
2. **`usage` 只给「成员可互换」的组**。真实配置里只有测试与轻量两组用 `usage`（模型多、质量相近、摊额度有意义），其余全 `order`（有明确主力，要的是故障转移）。给有主力的组用 `usage` 会把请求分给次选模型。
3. **classifier 分离做到供应商级更干净**。这台机器的 classifier 来自一个**与所有路由成员都不同**的供应商：判断请求不消耗任何路由池的额度，限流也互不牵连。模型级分离是底线，供应商级是加分。
4. **成员可以不带 `:effort`**。`g-light` 里两个成员无后缀，与 `:low` 成员并列——省略即按**组的 `effort`** 推理（`agent` 默认＝agent 要求的强度，`auto`＝classifier 每回合选），不是必须每个成员都标。
5. **子组数量按需增删**。真实配置有 9 个子组（多了文档写作意图）。加一个子组 = 模板里加一组 + 网关加一条意图规则 + 网关 members 加一个 `group/<id>`，三处都要改（漏改 members 会让规则指向非成员而被 magpie 拒绝保存）。
6. **组 id 别叫 `group`**。这台机器那个文档组的 id 真的就是 `group`（上表为可读性改写成 `g-docs`），成员引用写成 `group/group`——合法但极易读错。统一 `g-` 前缀。

另外：这份快照里**所有组都没设 `affinity`**。粘性是可选优化，不是两层架构的必需件——要不要给主链各组加 `affinity: session` 是另一项取舍（模式 12），加与不加都合法，见下。**本仓库的模板现在选的是「加」**：主链各组与便宜层两组设 `session`，`auto`/`g-compact`/`g-ui` 不设，理由各写在该组 note 里，取舍见模式 13。

### 落盘与观测的坑（实测，magpie 0.1.4178）

上面那张表是某一时刻的快照；下面 4 条是真正动手改这类配置时会撞到的实测行为，都不是从那张表读出来的。

1. **「同组同档」只约束主链，不是 magpie 的限制**。上面第 1 条的代价推论，适用范围是「会话会跨意图互切的那几组」——上面那张快照那台机器后来的配法是主链六个组（含文档组与 UI 组）全 `:high`、便宜层各组各自同档（一档 `:medium`、两处 `:low`）——组数随人，别照抄成「六」。**刻意要不同强度的独立池仍然可以混档**：模式 3 的「同模型两强度 = 两成员」依然成立。`templates/` 现在不混档了——`scripts/e2e.sh` 对**模板与渲染产物两头**都有断言（首位=锚、同组同档、粘性取值）：前者防「策略改了而模板漂回去」，后者防 mapping 里的 `@effort` 覆写把渲染后的主链重新拉混。`examples/demo/` 里只剩 `g-ui` 因 `@effort` 覆写而混，那是刻意保留的示例（代价就是跨到那组的那一次整段前缀重付）。`scripts/validate.py` 对成员强度没有任何一致性校验，同档是成本取舍，不是 schema 要求。
2. **顶班会把主链的档位差异频繁兑现**：`~/.config/magpie/affinity.json` 里 key 首段为 `group/auto` 的会话记录中，本机实测 `stoodIn=true` 约占**三成**（一次计数是 220 条里 69 条）——钉住的成员近三成回合在替班，所以主链若混档，重付就会被频繁触发。**`stoodIn` 只在 `affinity.json` 里**——`routing/*.jsonl`（含 gz）与 `usage.jsonl` 都没有这个字段，去那两个文件里找会得出「没这回事」。记录里也不含档位，所以它支撑的是「顶班频繁 ⇒ 主链若混档就会被频繁触发」，不是「顶班本身改了强度」。
3. **magpie 曾被观测到按自己的语义重排 `members` 顺序**（本机一次观测，触发规则未知）：草案写 `[锚, 原成员]`，落盘变成 `[原成员, 锚]`，没有字段解释；复写一次就守住。断言因此要查 **`members[0]` 是不是目标主力**，不能只比成员集合——但这条**只对 `order` 类组成立**（`order`/`drain`；`usage`/`weight` 子组没有首成员默认，见模式 8 与 schema.md），对它们加首位断言会得到假失败。现成的检出办法有三条（前两条只看落盘，第三条是档位维度）：
    - 隔段时间用**同一份草案**再跑一次 `apply.py`（不带 `--write`）→ 漂移会显式打成 `members: order changed`。
    - `doctor.py` 只看落盘配置就能报：两个 order 类组**共享同一成员（同模型同档）、且它至少在某一组居首**，两组却不同时以它开头 → 两种可能，工具分不出：刻意不锚（模式 13 认可这种取法），或锚被回写挪走了。
    - 两条首位**同基名但档位不同**也会被单独报出来（这一条比较用 `validate.py` 的 `base_model`，剥掉 `:effort`/`#account`）——「同锚不同档」恰恰是缓存上最贵的一种漏判：档位进缓存键（实测在经验 1，模式 13 写法 2 也引了同一条），首位看着一致、前缀照样整段重付。
    两条判据的**粒度不同是有实测依据的**：第一条只认「完全相同的成员串」，按基名配对会在按模式 13 刻意不锚的组上刷噪声（实测：放宽到基名、保留「至少在一组居首」→ demo 报 6 对；连「居首」一起去掉 → 7 对，但只打印 6 对 + `(+1 more pairs not listed)`（配对上限 6）；`g-compact` 与主链共享基名 `lite-chat` 却一档 `:low` 一档 `:high`，那根本不是锚漂移）；第二条必须按基名比，否则正好漏掉最贵的那种。
    还有一条**必须不报**的形状：两组各自有自己的锚、只在第二位共用同一个便宜备胎。不要求「共享成员至少在某一组居首」就会在这种常见配法上误报（两路独立 review 各自复现过），`scripts/e2e.sh` 第 67 条把这几侧都钉住了。
    别指望「写完立刻读回比对顺序」：本机那次观测里，重排发生在 magpie **之后**自己回写时，而 `apply.py --write` 的读回就在自己写入之后——那一刻几乎总是与草案一致（只有 magpie 恰好在写入窗口内插一手才会不同，本机没观测到），所以那种比对查不到漂移，是假安心。所以 `apply.py` 只打一行复跑指引，不做恒真比对。
4. **`applied.json` 是陈旧账本，别当现状**：典型形态是里面还留着早已失效的档位引用——比如指向一个已经不存在的组。接线语义、只读形态与两参数写入的陷阱以 [concepts.md](concepts.md) 的「agent 入口」一节为准，那里是唯一真源；本条只留结论：**判断现状读 agent 自己的配置文件**（如 `~/.claude/settings.json`）。

## 通用模式（6–13：6–12 是旧 7 模式的校正版，13 是成本/缓存模式）

### 6. 意图分层路由（单层变体）

**意图**：不建子组，组内直接按意图选模型。适合模型少、不需要任务池的场景。
**结构**：组配 classifier + 一组 intent 规则（use 指向模型）+ members（兜底按 routing 模式）。7 条互斥意图同模式 1 表格（路由到角色而非子组）。
**校正**：兜底不是 compact:true 规则；未命中任何规则时按组 routing 模式路由，仅 order 类模式有首成员兜底（见模式 8）。单层表达不了「每类任务一个池 + 每模型强度」，需求复杂时升级两层。

### 7. 推理触发升级

**意图**：需要深思的请求自动升级，与意图分类无关。
**写法**：`{"use": "acme/strong-reasoner", "effort": "on"}`（任意推理即命中），或 `effort` 写档位（至少该档才命中）；放在意图规则之后。
**取舍**：简单请求不触发；首条命中生效，注意与意图规则的顺序。两层架构里可放主路由末尾指向强模型子组（见模式 1），也可用子组成员 `:effort` / `useEffort` 表达强度。

### 8. 默认兜底与压缩分流（原「成本分级兜底」，语义已校正）

**校正**：旧版把 `compact:true` 当兜底规则——官方语义里它是**压缩触发条件**，不是兜底。默认兜底 = 未命中任何规则时按组的 **routing 模式**路由：`order` 首成员优先，`usage` 按剩余额度分摊，`weight` 按权重等；旧文档「普适成员顺序/首成员」的说法是失真，已纠正。
**写法**：默认模型放 members 首位（**仅对 order 类模式成立**——本文里 order 类指 `order` 与 `drain` 两种，模式 4 的「通道顺序表达优先级」就是这两档；`drain` 计入 order 类是按 schema.md 那行的顺序语义推的，**未实测**（已登记在 schema.md 待验证清单）；`usage` 按剩余额度分摊、`weight` 按权重分配、`rotate` 逐条轮转到下一个成员，都没有首成员默认）；压缩流量用第 1 条 `{"use": "group/g-compact", "compact": true}` 分流（单层则 use 指向便宜/长上下文模型）。
**取舍**：默认成员承接所有未分类流量，不宜太弱；每组 **`members` 或 `match` 至少一个非空**（工具校验，`hidden:true` 墓碑豁免），不强制 compact:true。

### 9. 故障转移链

**意图**：目标失败（限流/超时）时自动降级。
**写法**：`"more": ["acme/code-standard", "acme/lite-chat"]` 按序尝试；CLI `use=a,b` 展开为 use=a + more=[b]。目标也可为 `group/<id>`（use/more 必须是本组成员，magpie 原生强制，见 schema.md）。
**取舍**：链越长尾延迟越高；转移目标与原模型能力同档或相邻。与池路由的分工见 concepts.md；子组全失败才轮外层下一成员。

### 10. 长上下文摘要组

**意图**：会话压缩/摘要只要长上下文、快、便宜，与编码质量无关。
**结构**：独立子组 `g-compact`（members 为 context/long + fast/cheap），**不经意图分类器**；主路由 compact:true 规则指向它。
**取舍**：摘要走独立组而非任务池规则，避免摘要流量抢占强模型。

### 11. UI 设计专用路由

**意图**：界面、样式、截图还原走多模态模型。
**写法**：两层：`{"use": "group/g-ui", "intent": "前端界面、样式或视觉还原（含截图）"}`，g-ui 内 design/ui 优先、code/general 备用（order）。单层：use 直接指向 design/ui 模型 + more。
**取舍**：多模态能力以实测为准（模型目录的模态标注可能是统一填充的元数据）；纯企业官网类任务 code/general 往往已够。

### 12. 会话粘性（affinity）

**意图**：同会话沿用同一模型/账号以利用 prompt cache，省钱省延迟。
**写法**：组级 `"affinity": "session"`（示例）。配置入口已定位：JSON 字段 `affinity`，CLI 别名 `stays`；5 值语义表见 schema.md。
**取舍**：默认 `auto` 通常够用；长会话重缓存用 `session`；`strict` 额度用完宁报错也不换账号，慎用。粘性只解决「会话内换通道」，解决不了「跨组换主力」——后者见模式 13。

### 13. 主链锚定（同首位 + 同档 + 会话粘性）

**意图**：一个会话会在编码、审查、重构之间来回切。若每个任务组各有主力，每跨一次意图就换一次模型：工具 schema、system prompt、全部历史整段重新 prefill。跨供应商更彻底——同名模型也不共享账号。粘性只钉住组内通道，跨组换主力它管不着，所以要一组三条一起配。

**写法**（主链 = 会话会跨意图互切的那几组）：

1. 主链各组 `members[0]` 写**同一个**模型（下称**锚**），各组原有主力降为次选——顺带把单成员组「无故障转移」的坑补回来。
2. 主链各组**一律同档**。强度在缓存键里：本机实测只把 `thinking.budget_tokens` 从关闭改成 2048 或 8192，`cache_read` 立刻归零（证据面是一个供应商的单个账号，换供应商需重测）。
3. 这些组设 `"affinity": "session"`：会话内不换通道。**`usage` 组要单独想清楚**——`session` 的语义里新会话是「按当前最少并发分配」（schema.md 的 affinity 表），不是「按剩余额度」；两者叠加时谁优先、无额度读数的成员怎么参与，都未实测（已登记进 `docs/schema.md` 待验证清单第 5 条）。模板给便宜层两组设了 `session`，note 里只声明了「会话内不换通道」这条已确证的部分。

`templates/groups.template.json` 已按此配好，形状由 `scripts/e2e.sh` 的断言守着，**模板与渲染产物两头都闸**：模板侧查锚定组首位=锚、同组同档、`session` 取值（`auto`/`g-compact`/`g-ui` 必须不带，写成显式 `"affinity": "auto"` 也算合规，它是默认值）；产物侧查首位=锚与档位两条（`affinity` 由模板原样带过去，模板侧那条断言已覆盖它），因为 mapping 里的 `@effort` 覆写能把渲染后的主链重新拉成混档，只看模板 token 拦不住。

落盘后要**回读**：magpie 曾被观测到重排 `members` 顺序（「落盘与观测的坑」第 3 条）。两个现成的读数口：`scripts/doctor.py` 每组一行会打 `affinity=` 与 order 类组（`order`/`drain`）的 `first=<成员>`；`scripts/apply.py` 的 dry-run 对被替换的组会显式打 `members: order changed`。两者都不写盘。

**三处刻意不设粘性**（`auto`/`g-compact`/`g-ui`，与「不锚」是两件事，别混）：`auto`——组级粘性对「成员本身是子组」的作用范围未实测；`g-compact`——压缩后前缀本来就要重建，钉住省不到缓存；`g-ui`——读图能力不能从模型名臆断（AGENTS.md 的硬约束），视觉模型仍居首，确认主力能读图后再把锚提到首位。
另有**刻意不锚但照设粘性**的组：`g-light`（便宜层刻意不锚，`session` 仍设——会话内不换通道与「选哪个便宜模型」是两条独立的决定，见写法 3）。

**代价（两条，都不该被忽略）**：

1. 「审查组刻意换个模型家族」这种逐组多样性用角色槽表达不了（角色→列表是全局映射）。要保留就走字面量成员逃生口（复现配方一节），代价是切到那组的那一次重付前缀。
2. 主链各组稳态服务同一个模型、同一强度，**「按意图选强模型」这条路径实际失效**：`reasoning/strong` 只在锚不可用时作为故障转移顶上。也就是说模式 1 的「每类任务一个模型池」退化成「共享一个主力 + 各自的备用尾巴」。要保住「难题用强模型」，就别锚架构/重构这类组——省缓存与按意图配强度是**互斥**的取舍，挑一个。

**本机对照（样本小，别当收益数字）**：按真实写入时刻切窗（本地 2026-11-16 21:40）——写入前 12 小时：46 条路由记录 / 29 个会话 / 会话内换模型 10 次；写入后 14.6 小时：95 条 / 80 会话 / **5** 次（每条记录的切换率 0.22 → 0.05）。取数口径：`~/.config/magpie/affinity.json` 的 key 形如 `组|哈希|会话uuid|agent…`，按会话分组、按 `at` 排序后数「相邻记录模型不同」的次数。

两个坑记在这里，省得下一次把对照做假：① **条目的 `at` 会被就地改写**（相邻两份快照的 510 个同名键里 6 个的 `at` 变了）→ 按时间窗取数不随时间稳定，同一份统计隔天未必复现；② 写入后的窗口里还没有记录数 ≥10 的长会话，也没有一次跨组命中——**最贵的那一段尚未被观测**，所以这组数只说明方向，不是省了多少钱。
