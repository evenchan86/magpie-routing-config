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
   - **先 dry-run**：`python3 -I scripts/apply.py <草案.json> ~/.config/magpie/providers.json`——先按 id 合并、再校验**合并结果**（不通过不合并、不写文件），然后展示合并计划：组级（新增/替换/保留）+ **每个被替换组的组内字段级变化**（成员增删 `±模型:强度`、列表字段纯换序标 `<字段>: order changed`（`rules` 重排另标 `rules: reordered`）、`routing`/`affinity`/`classifier` 等标量旧→新、规则数与**逐条规则的改向/条件/强度变化**（`rules[0].use: 旧 → 新`）、权重逐键旧→新、**被删掉的字段标 `→ (unset)`**；内容相同标 `identical`，纯换序标 `reordered`）。**回显字符串过两道闸**：①只有模型引用/枚举字段才回显，`note`/`name`/未知键等自由文本一律只给 `<text N chars>`；②整组先过密钥/endpoint 形态自查（复用 validate.py 的判定），命中就把该组 diff 全部降级成形态摘要——校验的是合并结果，**被替换组的存量侧不过校验**，任何字段都可能夹带凭据，**不写文件**。校验对象必须是合并后的全量 groups：classifier 跨组分离、组引用存在这类守卫只在合并结果上才成立（只校验草案孤岛会既漏判跨组冲突，又误拒「草案引用已存在组」这种合法写法）。
   - 把 dry-run 的合并计划**连同组内变化一起展示给使用者**（upsert 是整组替换，草稿没写的字段会被删——`→ (unset)` 那几行必须让使用者看见），得到明确确认后才加 `--write` 写入。`--write` 会**先备份**（`providers.json.bak-<时间戳>`，保留原文件权限如同秒重跑加序号不覆盖）、按 group `id` **upsert**（同 id 替换该组对象、新 id 追加末尾、其余原样保留）、**只动 groups 不碰 providers**，并做**写后读回磁盘校验**（providers 段逐键不变 + 落盘 groups 合法）；写入损坏或校验失败会**自动从备份恢复原配置**并非零退出。草案里若带 providers 段会被忽略（只合并 groups），脚本会提示。
   - 若校验报的问题出在**本次不替换的存量组**，那是使用者现有配置的问题：先用 doctor.py 诊断，与使用者确认后再决定怎么处理，不要为了通过校验擅自改动存量组。
   - 诊断现有配置用 `python3 -I scripts/doctor.py ~/.config/magpie/providers.json`（只读，**输出是英文**，组结构含 `affinity` 与 order 类组（`order`/`drain`）首位成员 + 校验结果 + `shape findings:` 形状诊断 + 接线冒烟步骤，不含密钥/endpoint；**冒烟步骤本身含对活实例的 CLI 写操作**，按里面的隔离说明执行）。配置畸形（providers 非对象列表、groups 非 list）会明确 FAIL，不会谎报「尚未配置」。**退出码语义**：0=诊断完成（**含校验或形状发现问题**）、1=文件/JSON/畸形、2=用法——结论看输出的 `validation:` 与 `shape findings:` 两段，**不要**用 `doctor.py && …` 当闸门（有问题时它会打印提醒）。形状诊断抓的是 schema 合法但吃亏的配法（单成员的叶子组（除 `manual`，它不做故障转移）＝该组内无退路，缺省 `smart` 也在射程内；两个 order 类组共享同一成员（同模型同档）却首位不同——**可能是刻意不锚，也可能是回写把首位挪走，工具分不出**；两条首位同基名但档位不同——这条按 `validate.base_model` 比，漏判它最贵（档位进缓存键）。**两条粒度不同**：前者只认完全相同的成员串，按基名配会在刻意不锚的组上刷噪声（实测：放宽到基名但保留「至少在一组居首」→ demo 报 6 对；连「居首」一起去掉 → 7 对，其中只打印 6 对 + `(+1 more pairs not listed)`，配对上限是 6）；后者必须按基名比。同组混档；`usage`/`rotate` 组档位不一致）。**射程要读准**：只看不含 `group/` 成员的叶子组（主路由不参与）；首位类判据只配对 order 类组（= `order` 与 `drain`，见模式 8；`usage`/`weight` 没有首成员语义）；配了 `match` 的组**完全跳过**单成员判据（输出里不会有任何相关句子——还有模式成员兜着，且跨模式成员的故障转移未实测）；裸引用与 `:low+high` 多级成员解析不出档位，档位类判据对它们沉默；载入 `validate.py` 失败时会打 `model-name and effort checks were NOT RUN (could not load validate.py)` 而不是 `none`（缺比较器就不能假装查过；不依赖比较器的单成员判据仍会跑），并额外声明**组行的 id/首位/粘性读数此时全是 `<ref N chars>` 形态摘要**——降级不是「一切照常只是少几项」，那份表读不得。**至少两组 order 类组才有首位可比**，单组配置的漂移在这里不可见。**对称漂移也看不见**：锚在全部组里都被挪到非首位时，落盘数据与「各组有自己的锚、只共用一个便宜备胎」完全同形，只看落盘分不出——那种只能靠复跑同一份草案（`members: order changed`）抓。重复组 id 会先单独声明一条（否则后面的判据看起来「同一个 id 自相矛盾」）。**校验器崩溃 ≠ 通过**：判崩据是 stderr 里的 `Traceback (most recent call last)` 行（不是「输出里含 Traceback 字样」——那会被 `routing: "Traceback"` 这种合法 FAIL 骗到，实测过）。真崩时 doctor 打 `the validator CRASHED` 提醒，形状段打 `not evaluated:` 而不是 `none`（崩溃时形状判据可能读到畸形结构，那段不是结论）。`groups` 为空时整段不存在——只打「尚未配置路由」，别把「没有 `shape findings:` 段」读成「形状没问题」。判据出处：模式 9（故障转移）、模式 13 与坑 3（首位）、模式 3 的代价段与经验 1（档位）、模式 2 与经验 2（可互换前提）。
   - **写后验收（先验接线，再评价组）**：接线语义、陷阱与读数的真源是 [docs/concepts.md](docs/concepts.md) 的「agent 入口」一节——**先读它**，尤其这条：**两参数形式 `magpie <agent> X`，`X` 不是该 agent 的字段名时就是「把主 model 设成 `X`」**（`magpie claude opus` 写 `"model": "opus"` 并让 magpie 退出该 agent；`magpie codex run` 写 `model = "run"`，因为 `run` 只有 claude 有）。操作面：只读用单参数 `magpie ls` / `magpie <agent>`；写接线 `magpie <agent> group/<id>`；改字段 `magpie <agent> <field> <value>`；恢复默认 `magpie <agent> <field> default`（claude 的四档默认＝回主 model，其它字段＝该字段自己的默认）；改接线只影响新会话，claude 可用 `magpie claude run` 起验收会话。验收证据 = `~/.config/magpie/routing/<日期>.jsonl` 里那一轮带 `group.id`（那一轮 `group` 为 `null` 只说明它没走组，**不能据此断定入口是具体模型**，同一节里有反例）。**没看到这条记录就不要宣称已生效**；无法自动验证时给接线冒烟步骤（doctor.py 会打印，里面含 CLI 写操作）。

## 红线

- 探测/实测本机配置一律用解析器只输出字段名或 id/models，**禁止全文件 Read/cat**（密钥会进入上下文）。
- 永不重新生成或修改供应商连接配置（endpoint、key）——使用者本机已有。
- 永不把密钥写入本仓库或任何输出；示例一律使用虚构供应商与虚构密钥。
- **classifier 分离**：意图判断模型（`intent/judge`）只做意图判断，绝不进路由成员/规则目标/兜底。
- 配置 schema 用 `intent` / `effort:"on"` / `compact:true` / `more` / `where:[{field,op,value}]`。**rule 字段名以 JSON 为准**（`where`、`time` 对象、`exceptFolders` 驼峰）；CLI 旗标名 `when`/`tz`/`days`/`except-folders`/`at` 不是 JSON 字段（写进 JSON 会被 magpie 静默忽略）；**不要**把运行时日志里的 `n`/`held`/`classified`/`when` 当配置写法。
- **组级同理**：CLI `weight=`/`listed=` 的 JSON 真键名是 **`weights`**（成员引用→1..1000 整数，键含 `:effort`）与 **`unlists`**（bool）；glob/`re:` 模式写进独立的 **`match`** 数组，**不是 `members`**（写进 members 会被当字面模型 id 跳过）。键名错→静默忽略；**类型错→整份 providers.json 解析失败且 CLI 退出码仍 0**。
- **classifier 需要消费者**：组里至少一条 `intent` 规则或 `effort:"auto"`，否则 CLI 的 `classifier=` 被静默丢弃；有消费者却缺 classifier 则硬报错。宽模式（`match:["acme/*"]`）会把 classifier 模型拉进路由组，校验器查不出——用窄模式或让 classifier 用独立供应商。
- **实测本机 magpie 二进制时必须真隔离**：只设 `HOME` 不够（CLI 按端口连活实例，会改到真实配置）。加 `MAGPIE_ADDR=127.0.0.1:1` 并先断言 `magpie status --json` 的 `running` 为 `false`；方法见 `docs/schema.md` 末节。
- 默认兜底按**组的 routing 模式**（未命中规则→照组本来方式路由：`order`/`drain` 按成员顺序（首成员先用，`drain` 那条是推论、见 schema.md 待验证清单）、`usage` 按额度分摊），不是 `compact:true`；`compact:true` 只是压缩触发条件。
- `affinity`、规则/成员指向组（`group/<id>`）均已实测支持；其余未验证项见 `docs/schema.md` 待验证清单——不要当作已支持特性写进配置。
- **主链锚定是模板的默认形状**（取舍见 `docs/patterns.md` 模式 13）：会话会跨意图互切的那几组，`members[0]` 写同一个模型、组内一律同档、并设 `affinity: session`。改成员强度等于换缓存键；要逐组换模型家族就用字面量成员，别打散锚。改 `templates/groups.template.json` 必须**同批**重生成 `examples/demo/output.groups.json`——`scripts/docgate.py` 对 `templates/*.json` 只看顶层键集合，不会替你发现组内漂移；模板形状由 `scripts/e2e.sh` 的断言守着。

## 文档索引

- `docs/concepts.md`：两层路由、池路由 vs 故障转移、compact vs 默认兜底、classifier 独立、affinity 粘性、配置与日志区分。
- `docs/schema.md`：字段参考（逐字段标来源与校验状态）、routing 12 模式（含 manual）/ affinity 5 值语义、member 写法、组嵌套、待验证清单。
- `docs/patterns.md`：13 条模式——主模式（两层意图分发）+ 子组模式（池、每模型强度、多通道分摊、classifier 独立）+ 通用模式 6–13（含会话粘性、主链锚定）+ 复现配方 + 真实案例与「落盘与观测的坑」。
- `templates/roles.json`：6 个模型角色（含独立 `intent/judge`）；每角色 `signals`（名字正/负信号 + 需确认的能力 + 排序偏好）与 `mapping_rules`；mapping 为「角色 → 有序模型列表」。
- `scripts/render.py`：把角色列表映射展开进模板（成员多模型展开 + @effort 覆写 + classifier 取首元素裸引用）。
- `scripts/apply.py`：草案按 id upsert 合并进本机配置（dry-run 默认；校验合并结果 + 展示组内字段级变化，`--write` 备份+写后读回校验+失败自动恢复，只动 groups）。`--write` 成功后打印**漂移复跑指引**：magpie 曾被观测到在之后的回写里重排 `members`（本机一次观测，触发规则未知），刚写完的读回几乎总是与草案一致（重排发生在 magpie 之后的回写），那种比对查不到漂移；要查漂移就用同一份草案再跑一次不带 `--write`。
- `scripts/doctor.py`：只读诊断现有配置（组结构含 `affinity` 与 order 类组（`order`/`drain`）首位成员 + 校验 + **形状诊断**：重复组 id、单成员的 order 类组、共享同一成员却不同时以它开头（**刻意不锚或锚被挪走，工具分不出**）、首位同基名不同档、同组混档、`usage`/`rotate` 组档位不一致 + 接线冒烟步骤；输出英文且脱敏（遮蔽形态 `<ref N chars>` / `provider/<model N chars>:档位` / `x#<account N chars>`，判据在 `validate.py` 单真源；点分模型名与 endpoint 同形 → 一律掩，宁缺可读性），冒烟步骤含对活实例的 CLI 写操作）。形状问题是**建议**，`validate` 接受这些写法，发现问题也退 0；射程与「看不见什么」见上面「诊断现有配置用 `doctor.py`」那条 bullet。
- `scripts/docgate.py`：文档同步守卫的共享判定（公开面提取、豁免解析、从脚本 usage 解析 CLI 契约），被 e2e 与提交闸共用。
- `scripts/commit-gate.py`：提交闸——公开面变更必须同批同步公开文档；默认模式还要求当日 review 档案含「文档对照」小节，`--docs-only` 只查前者。
- `.githooks/pre-commit`：仓库自带的 git 原生提交闸（`git config core.hooksPath .githooks` 启用），不依赖任何外部工具。
- `examples/demo/`：虚构供应商的两层完整走通示例（含多模型子组）。

## 本仓库自身的开发命令

```bash
bash scripts/e2e.sh    # 隔离验收（假 HOME，不碰真实配置）
```

### 收尾流程：文档同步不可跳过

「开发完 → review 通过 → 直接提交」这条路在本仓库走不通。文档失真有三种性质，对应三道闸：

| 闸 | 挡什么 | 在哪强制 |
|---|---|---|
| 机器闸 | 公开面变了但文档没跟；公开文档里的命令签名与脚本 `usage` 不一致 | `scripts/e2e.sh` 第 63/64 条（提交前必跑） |
| 流程闸 | 语义类失真（过度承诺、散文与实现分叉、来源标注错） | review 任务书 + 档案「文档对照」小节 |
| 提交闸 | 上面两项的产物不全 | 仓库自带 `.githooks/pre-commit`（git 原生）→ `scripts/commit-gate.py` |

**强制点必须在 git 层，不能靠解析命令字符串。** 外部工具 hook 靠 `git\s+commit` 之类的正则认命令，实测 `git -C <path> commit`、`git -c k=v commit`、`git --no-pager commit`、提交消息里含 `--amend` 四种形态全部绕过，`echo 'git commit'` 反而被误拦。git 原生 hook 由 git 自己触发，**与命令怎么拼写无关**，`--amend` 也照样跑。e2e 第 65 条用**真提交**验证这五种形态（字符串匹配探针证明不了）。

启用一次（本机局部配置，可 `git config --unset core.hooksPath` 撤销）：

```bash
git config core.hooksPath .githooks
```

- **别的项目要复用**：把 `.githooks/pre-commit` + `scripts/commit-gate.py` + `scripts/docgate.py` 拷过去（**两个脚本必须放在 `<仓库根>/scripts/`**，hook 里的路径与此对应），同样设 `core.hooksPath`，需要 `python3` 在 PATH。**不放这些文件的项目完全不受影响**——没有全局 hook，没有跨仓库依赖。
- **退出通道**：`git commit --no-verify` 是 git 既定语义，拦不住也不假装拦得住。同类还有 plumbing（`git commit-tree` 不跑 hook）、合并冲突解决不触发 pre-commit、删除 hook 或 unset `core.hooksPath`。这些都是**显式动作**，与「命令换个写法就静默绕过」性质不同；内容正确性最终由 e2e 兜底。

**公开面**只有三类，纯内部实现改动不触发：任意 `scripts/*.py` 的 `usage` 行、`scripts/docgate.py` 里 `PUBLIC_CONSTANTS` 白名单那批常量（其余模块级常量如 `SECRET_VALUE` 改了不触发）、`templates/*.json` 的顶层键。

- 改了公开面 → **同批必须改公开文档**。闸门会列出「哪个脚本变了、该对照哪份文档」（按文档里是否提到该脚本自动给出，不维护手工映射表）。
- 确属纯内部改动时，在改动里加一行**独立注释**并写明理由（≥6 字）：

  ```python
  # doc-sync: 纯内部修复，不改公开行为
  ```

  豁免**按文件生效**（一条无关文件的豁免不能掩护整批公开面漂移），且只认**代码文件**（`scripts/`、`templates/`）里的独立注释行——闸门自己的帮助文本、docstring、以及文档里讲解豁免写法的示例，都不能当豁免用（两处自指都已实测复现）。
- **review 任务书必须包含文档对照**：明确「不要只审 diff，也翻没碰过的公开文件」，并要求产出逐文件结论。
- **review 档案必须有「文档对照」小节**：逐个公开文件写「相关/无关 + 依据」，至少提到 3 个公开文件。没有这一节，`commit-gate.py` 直接拦下。
- 公开文档清单 = 仓库里的 `.md`（含本批新增、尚未 git 跟踪的），排除 `docs/superpowers/`、`tasks/` 内部过程目录（两者都在 `.gitignore` 里，是本地过程目录，克隆里看不到）。
- **闸门分两层，对应两种使用者**：

  | 模式 | 查什么 | 给谁用 |
  |---|---|---|
  | `--docs-only` | 公开面 ↔ 公开文档 | 所有人。仓库自带 git hook 用这个：档案目录不随仓库分发，外部贡献者没有它 |
  | 默认（无旗标） | 上面那条 + 当日 review 档案「文档对照」小节 | 个人 review 工作流 |

  手动跑：`python3 -I scripts/commit-gate.py`（默认）或加 `--docs-only`。用法 `usage: commit-gate.py [--docs-only]`，未知旗标退出码 2。
