# 路由模式库

主模式是**两层意图分发**（模式 1），子组模式（2–5）决定每个任务池内部怎么路由；通用模式（6–12）是旧 7 模式按官方口径的校正版，单层/两层都可用。字段语义与来源见 [schema.md](schema.md)，概念见 [concepts.md](concepts.md)。

示例一律用虚构供应商 `acme/*`（含 `acme-cn`/`acme-global`，判断模型 `acme/judge`），模型名仅为示意；实际按 `templates/roles.json` 映射到你本机模型。`templates/groups.template.json` 是两层骨架的角色占位版。

## 主模式

### 1. 两层意图分发

**意图**：主路由只做意图判断，分发到按任务类型划分的子组；子组内部负责模型选择、故障转移、额度分摊。每类任务一个模型池，互不抢占。

**结构**：主路由组（classifier + compact 规则第 1 条 + intent 规则 use=group/g-xxx + 子组成员）+ 8 个任务子组。

| 子组 | 任务 | 建议角色 | 建议 routing |
|---|---|---|---|
| `g-compact` | 压缩/摘要（compact 条件，不是意图） | context/long + fast/cheap | order 或 usage |
| `g-test` | 写测试或修失败的测试 | code/general | usage |
| `g-light` | 简单问答、查文档或命令 | fast/cheap | usage |
| `g-code` | 实现新功能或修局部 bug（**默认**） | code/general（可加低档备用） | usage（同档）/ order（带备用） |
| `g-heavy` | 重构、迁移或跨文件大改动 | reasoning/strong + code/general 备用 | order |
| `g-arch` | 架构设计、方案选型或疑难排查 | reasoning/strong（高强度） | order |
| `g-ui` | 前端界面、样式或视觉还原（含截图） | design/ui + code/general 备用 | order |
| `g-review` | 审查代码或 review 改动 | code/general（可升 reasoning/strong） | order |

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
    { "use": "group/g-ui", "intent": "前端界面、样式或视觉还原（含截图）" },
    { "use": "group/g-review", "intent": "审查代码或 review 改动" }
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
| 同档按比例分配 | `weight` | 权重经组级 `weight` 设置（JSON 名已确证，值形态待核，见 schema.md） |

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

**写法**：成员后缀 `:effort`，集合 `none/minimal/low/medium/high/xhigh/max`（旧文档的 `ultra` 是错的）。同模型两强度 = 两成员；`:low+high` 多级；`:fast` 厂商快速模式。

```json
{
  "id": "g-arch",
  "name": "架构 · 高强度",
  "routing": "order",
  "members": ["acme/strong-reasoner:xhigh", "acme/strong-reasoner:high"]
}
```

规则级 `useEffort`（`low/medium/high/xhigh/max`）可在命中后整轮覆盖 Agent 要求的强度；成员已固定的强度保留自身设置。

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

网关 10 条规则：`compact:true` 第 1 条 → 8 条意图（含新增的「撰写文档、教材或知识库文章」）→ `effort:"on"` 末条升 `g-heavy`。

**从这份真实配置能读出的 6 条经验**：

1. **强度是「任务 × 模型」的函数，不是模型固有属性**。主力编码模型在 `g-code`/`g-review` 是 `:high`、`g-arch` 是 `:xhigh`、`g-ui`/`g-docs` 是 `:medium`；轻量模型在压缩/轻量组是 `:low`、在测试/审查组是 `:high`。这正是 `@effort` 覆写 + 字面量逃生口要表达的东西——把强度写死在角色上就表达不了。
2. **`usage` 只给「成员可互换」的组**。真实配置里只有测试与轻量两组用 `usage`（模型多、质量相近、摊额度有意义），其余全 `order`（有明确主力，要的是故障转移）。给有主力的组用 `usage` 会把请求分给次选模型。
3. **classifier 分离做到供应商级更干净**。这台机器的 classifier 来自一个**与所有路由成员都不同**的供应商：判断请求不消耗任何路由池的额度，限流也互不牵连。模型级分离是底线，供应商级是加分。
4. **成员可以不带 `:effort`**。`g-light` 里两个成员无后缀，与 `:low` 成员并列——省略即按**组的 `effort`** 推理（`agent` 默认＝agent 要求的强度，`auto`＝classifier 每回合选），不是必须每个成员都标。
5. **子组数量按需增删**。真实配置有 9 个子组（多了文档写作意图）。加一个子组 = 模板里加一组 + 网关加一条意图规则 + 网关 members 加一个 `group/<id>`，三处都要改（漏改 members 会让规则指向非成员而被 magpie 拒绝保存）。
6. **组 id 别叫 `group`**。这台机器那个文档组的 id 真的就是 `group`（上表为可读性改写成 `g-docs`），成员引用写成 `group/group`——合法但极易读错。统一 `g-` 前缀。

另外：这份配置**所有组都没设 `affinity`**。粘性是可选优化，不是两层架构的必需件。

## 通用模式（旧 7 个，按官方口径校正）

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
**写法**：默认模型放 members 首位（**仅对 order 类模式成立**；usage/weight 子组按额度/权重分摊，没有首成员默认）；压缩流量用第 1 条 `{"use": "group/g-compact", "compact": true}` 分流（单层则 use 指向便宜/长上下文模型）。
**取舍**：默认成员承接所有未分类流量，不宜太弱；**所有组** members 必须非空（工具校验），不强制 compact:true。

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
**取舍**：默认 `auto` 通常够用；长会话重缓存用 `session`；`strict` 额度用完宁报错也不换账号，慎用。