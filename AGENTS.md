# AGENTS.md · magpie-routing-config

本文件是 agent 的唯一入口，`CLAUDE.md` 只引用本文件。

## 这个仓库是什么

开源的 **magpie 路由策略架构方案**：概念文档、配置 schema 参考、路由模式库、角色占位模板。不含任何真实密钥、真实模型 id 或任何机器的配置。

使用者是**已安装 magpie、已配好供应商**的人。你的任务：按下面的工作流，帮使用者基于**他本机已有的模型**生成**两层路由层**（主路由意图分发 + 任务子组）配置。

## 核心架构：两层意图分发

- **主路由 `auto`**：`classifier`（小而快的意图判断模型）判断每回合意图，规则 `use=group/<id>` 分发到任务子组；自身不做模型选择。无意图命中时按组 routing 模式兜底（`auto` 用 `order`，故首位 `group/g-code`）。
- **8 个任务子组**：`g-compact`/`g-test`/`g-light`/`g-code`/`g-heavy`/`g-arch`/`g-ui`/`g-review`，各自管理**多个模型成员**（`模型:强度`，由角色列表展开）与 `routing`（`order` 有序故障转移 / `usage` 额度分摊）。
- **classifier 独立**：意图判断模型（角色 `intent/judge`）**只**做分类，**绝不**进任何组的成员/规则目标/兜底。这是硬约束。

## 工作流（按序执行）

1. **实测 schema（脱敏）**：解析使用者本机 `~/.config/magpie/providers.json`，验证本仓库文档描述的字段真实存在。**禁止用 Read/cat 读整个文件**——密钥会进入上下文；只用解析器输出字段名：

   ```bash
   python3 -I -c "
   import json
   d=json.load(open('$HOME/.config/magpie/providers.json'))
   print('top:', sorted(d.keys()))
   print('group fields:', sorted({k for g in d.get('groups',[]) for k in g}))
   print('rule fields:', sorted({k for g in d.get('groups',[]) for r in g.get('rules',[]) for k in r}))
   "
   ```

   文档以官方文档（usemagpie.ai/docs/zh）+ magpie CLI 帮助 + 本机实测为依据，**仍以你实测为准，文档只是先验**。找不到配置就先引导使用者安装并初始化 magpie，不要编造。
2. **探测（脱敏，禁止全文件读取）**：**不要**用 Read/cat 读整个 providers.json——密钥会进入上下文。一律用解析器只输出供应商 id 与模型名：

   ```bash
   python3 -I -c "
   import json
   d=json.load(open('$HOME/.config/magpie/providers.json'))
   print(json.dumps([{'id':p.get('id'),'models':p.get('models')} for p in d.get('providers',[])],ensure_ascii=False))
   "
   ```

3. **映射**：按 `templates/roles.json` 的启发式给出「角色 → 本机模型」建议（6 角色，含独立的 `intent/judge`），**必须经使用者确认**后填入 mapping。启发式已结构化为每个角色的 `signals`：先只取引用里**最后一个 `/` 之后的模型名段**（丢弃供应商前缀与中间路径段），**转小写、按非字母数字字符切段**，token 与**整段相等**才算命中——命中 `name_contains` 记正信号、命中 `name_avoid` 记负信号。**用整段不用子串**：子串下 `promini` 含 `mini`、`maximini` 含 `mini`/`max`，会把旗舰误判成快模型、把快模型误判成强模型。**同角色内负信号否决正信号**；一个模型命中多个角色属正常，交使用者裁决。**没命中任何信号的模型照常列给使用者确认，不得因此排除**（很多主流模型名不含这些 token），也不得硬凑名字。能力信息：`models` 数组只有裸名，但 provider 级**可能**有 `contexts`（模型名 → 上下文长度整数，可用 `*` 通配）：**被它覆盖到的模型**直接用，未列出的仍须确认（它可能只覆盖该供应商的一部分模型）；多模态 / 推理档没有元数据，必须问使用者或查供应商文档，**禁止从名字臆断**。mapping 值是**有序模型列表**（主模型在前，可多个做故障转移/池；元素为 base 引用 `provider/model`，可含 `#account` 通道，不含 `:effort`；可用 `model@effort` 覆写该模型强度，组合写法 `provider/model#account@effort`）。`@` 仅在最后一个 `@` 后恰为合法强度（支持 `+` 多级，如 `@low+high`）时才算覆写，否则整串按 base 引用——**模型 id / 账号名本身可含 `@`**（如 `gpt-4o@2024-08-06`、`#user@example.com`），不会被误伤。不要替使用者拍板模型选择。`intent/judge` 选一个小而快、不带推理的模型（列表首元素作 classifier，裸引用不带强度），且不得与任何路由角色复用同一模型——选定后**从其他角色候选中剔除**（`signals.exclusive`）。
4. **渲染**：用 `scripts/render.py` 把确认的 mapping 展开进 `templates/groups.template.json`——模板成员 `<role:xxx>:强度` 展开为该角色**所有模型**：带 `@effort` 的用覆写强度、其余用槽位强度（多模型子组，可同组混强度；强度插在 `#account` 前），`classifier` 取 `intent/judge` 列表首元素的裸引用，产出两层路由层草案（主路由 `auto` + 8 子组）：

   ```bash
   python3 -I scripts/render.py templates/groups.template.json <mapping.json> <草案.json>
   ```

   逐模型强度用 `@effort` 覆写，逐组差异化选型可在模板里直接写死 `模型:强度`（非角色成员原样透传，见 `docs/patterns.md` 复现配方）；组内重叠模型自动精确去重（保序）。使用者可增删意图、角色或子组。
5. **校验**：生成已知模型清单（脱敏）并对草案执行完整校验，必须通过：

   ```bash
   python3 -I -c "
   import json
   d=json.load(open('$HOME/.config/magpie/providers.json'))
   print(json.dumps(sorted({(m if '/' in m else p.get('id','')+'/'+m) for p in d.get('providers',[]) for m in (p.get('models') or [])})))
   " > /tmp/known-models.json
   python3 -I scripts/validate.py <草案.json> /tmp/known-models.json
   ```

   **已知清单须为 `provider/model` 引用**：真实 magpie 的 `models` 数组存**裸名**（可能带冒号，如虚构示例 `cn:coder-a`、`coder-b`），而 mapping/成员引用是 `provider/model`，故按供应商 id 拼前缀；模型名已含 `/` 的保持原样（兼容 demo 夹具）。直接取裸名会让校验器把所有引用判为 unknown。

   校验覆盖：字段白名单（rule 字段以 JSON 为准）、无占位残留、无密钥（形态判定除常见凭据前缀外，还包含本仓库夹具用的虚构前缀，见 `scripts/validate.py` 的 `SECRET_VALUE`——真实配置的 `note`/组名里别用那个前缀，否则会被判 secret-like）、模型引用已知（含 classifier）、组引用存在/禁自包含/嵌套深度≤8、**classifier 跨组分离守卫**（classifier 模型不得进任何路由组的成员/规则目标）、规则 use/more 须为本组成员、每条规则有 `use`、**每组 members 或 match 至少有一个非空**（`hidden:true` 墓碑豁免；默认兜底按组 routing 模式，不强制 `compact:true`）、routing/affinity/effort 枚举、where/time/exceptFolders 等类型结构。
6. **应用（用 `scripts/apply.py`，合并语义明确）**：
   - **先 dry-run**：`python3 -I scripts/apply.py <草案.json> ~/.config/magpie/providers.json`——先按 id 合并、再校验**合并结果**（不通过不合并、不写文件），然后展示合并计划：组级（新增/替换/保留）+ **每个被替换组的组内字段级变化**（成员增删 `±模型:强度`、纯换序标 `order changed`、`routing`/`affinity`/`classifier` 等标量旧→新、规则数与**逐条规则的改向/条件/强度变化**（`rules[0].use: 旧 → 新`）、权重逐键旧→新、**被删掉的字段标 `→ (unset)`**；内容相同标 `identical`，纯换序标 `reordered`）。**回显字符串过两道闸**：①只有模型引用/枚举字段才回显，`note`/`name`/未知键等自由文本一律只给 `<text N chars>`；②整组先过密钥/endpoint 形态自查（复用 validate.py 的判定），命中就把该组 diff 全部降级成形态摘要——校验的是合并结果，**被替换组的存量侧不过校验**，任何字段都可能夹带凭据，**不写文件**。校验对象必须是合并后的全量 groups：classifier 跨组分离、组引用存在这类守卫只在合并结果上才成立（只校验草案孤岛会既漏判跨组冲突，又误拒「草案引用已存在组」这种合法写法）。
   - 把 dry-run 的合并计划**连同组内变化一起展示给使用者**（upsert 是整组替换，草稿没写的字段会被删——`→ (unset)` 那几行必须让使用者看见），得到明确确认后才加 `--write` 写入。`--write` 会**先备份**（`providers.json.bak-<时间戳>`，保留原文件权限如同秒重跑加序号不覆盖）、按 group `id` **upsert**（同 id 替换该组对象、新 id 追加末尾、其余原样保留）、**只动 groups 不碰 providers**，并做**写后读回磁盘校验**（providers 段逐键不变 + 落盘 groups 合法）；写入损坏或校验失败会**自动从备份恢复原配置**并非零退出。草案里若带 providers 段会被忽略（只合并 groups），脚本会提示。
   - 若校验报的问题出在**本次不替换的存量组**，那是使用者现有配置的问题：先用 doctor.py 诊断，与使用者确认后再决定怎么处理，不要为了通过校验擅自改动存量组。
   - 诊断现有配置用 `python3 -I scripts/doctor.py ~/.config/magpie/providers.json`（只读，输出组结构 + 校验结果 + 手动冒烟步骤，不含密钥/endpoint）。配置畸形（providers 非对象列表、groups 非 list）会明确 FAIL，不会谎报「尚未配置」。**退出码语义**：0=诊断完成（**含校验发现问题**）、1=文件/JSON/畸形、2=用法——校验结论看输出的 `validation:` 段，**不要**用 `doctor.py && …` 当闸门（有 finding 时它会打印提醒）。
   - **写后验收**：magpie 无 CLI 路由接管，需引导使用者在 UI 把 agent 路由指向 `group/auto`（摘要组按 magpie 摘要入口选择），发一条简单测试请求，查 magpie 日志确认路由到预期模型；无法自动验证时给手动步骤（doctor.py 会打印），不要宣称已生效。

## 红线

- 探测/实测本机配置一律用解析器只输出字段名或 id/models，**禁止全文件 Read/cat**（密钥会进入上下文）。
- 永不重新生成或修改供应商连接配置（endpoint、key）——使用者本机已有。
- 永不把密钥写入本仓库或任何输出；示例一律使用虚构供应商与虚构密钥。
- **classifier 分离**：意图判断模型（`intent/judge`）只做意图判断，绝不进路由成员/规则目标/兜底。
- 配置 schema 用 `intent` / `effort:"on"` / `compact:true` / `more` / `where:[{field,op,value}]`。**rule 字段名以 JSON 为准**（`where`、`time` 对象、`exceptFolders` 驼峰）；CLI 旗标名 `when`/`tz`/`days`/`except-folders`/`at` 不是 JSON 字段（写进 JSON 会被 magpie 静默忽略）；**不要**把运行时日志里的 `n`/`held`/`classified`/`when` 当配置写法。
- **组级同理**：CLI `weight=`/`listed=` 的 JSON 真键名是 **`weights`**（成员引用→1..1000 整数，键含 `:effort`）与 **`unlists`**（bool）；glob/`re:` 模式写进独立的 **`match`** 数组，**不是 `members`**（写进 members 会被当字面模型 id 跳过）。键名错→静默忽略；**类型错→整份 providers.json 解析失败且 CLI 退出码仍 0**。
- **classifier 需要消费者**：组里至少一条 `intent` 规则或 `effort:"auto"`，否则 CLI 的 `classifier=` 被静默丢弃；有消费者却缺 classifier 则硬报错。宽模式（`match:["acme/*"]`）会把 classifier 模型拉进路由组，校验器查不出——用窄模式或让 classifier 用独立供应商。
- **实测本机 magpie 二进制时必须真隔离**：只设 `HOME` 不够（CLI 按端口连活实例，会改到真实配置）。加 `MAGPIE_ADDR=127.0.0.1:1` 并先断言 `magpie status --json` 的 `running` 为 `false`；方法见 `docs/schema.md` 末节。
- 默认兜底按**组的 routing 模式**（未命中规则→照组本来方式路由：`order` 首成员优先、`usage` 按额度分摊），不是 `compact:true`；`compact:true` 只是压缩触发条件。
- `affinity`、规则/成员指向组（`group/<id>`）均已实测支持；其余未验证项见 `docs/schema.md` 待验证清单——不要当作已支持特性写进配置。

## 文档索引

- `docs/concepts.md`：两层路由、池路由 vs 故障转移、compact vs 默认兜底、classifier 独立、affinity 粘性、配置与日志区分。
- `docs/schema.md`：字段参考（逐字段标来源与校验状态）、routing 12 模式（含 manual）/ affinity 5 值语义、member 写法、组嵌套、待验证清单。
- `docs/patterns.md`：两层意图分发主模式 + 子组池模式 + 每模型强度 + 多通道额度分摊。
- `templates/roles.json`：6 个模型角色（含独立 `intent/judge`）；每角色 `signals`（名字正/负信号 + 需确认的能力 + 排序偏好）与 `mapping_rules`；mapping 为「角色 → 有序模型列表」。
- `scripts/render.py`：把角色列表映射展开进模板（成员多模型展开 + @effort 覆写 + classifier 取首元素裸引用）。
- `scripts/apply.py`：草案按 id upsert 合并进本机配置（dry-run 默认；校验合并结果 + 展示组内字段级变化，`--write` 备份+写后读回校验+失败自动恢复，只动 groups）。
- `scripts/doctor.py`：只读诊断现有配置（组结构 + 校验 + 手动冒烟步骤，输出脱敏）。
- `examples/demo/`：虚构供应商的两层完整走通示例（含多模型子组）。

## 本仓库自身的开发命令

```bash
bash scripts/e2e.sh    # 隔离验收（假 HOME，不碰真实配置）
```