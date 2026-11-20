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

   校验覆盖：字段白名单（rule 字段以 JSON 为准）、无占位残留、无密钥（形态判定除常见凭据前缀外，还包含本仓库夹具用的虚构前缀，见 `scripts/validate.py` 的 `SECRET_VALUE`——真实配置的 `note`/组名里别用那个前缀，否则会被判 secret-like）、模型引用已知（含 classifier）、组引用存在/禁自包含/嵌套深度≤8（有环时报「环」、超深时报「太深」，都出判决而不是抛异常）；**深结构不靠递归**：引用链与自由值都用显式栈遍历，`classifier` 互引 1200 层、自由值套 1000 层都出判决而不是 `RecursionError` traceback（递归写法在 ~1000 层就炸，炸掉的是**整次校验**——已经查出来的问题也一起没了），且**报错顺序就是配置里的先后顺序**，不是栈的弹出顺序：深度不该改变你先看到哪条、**classifier 跨组分离守卫**（classifier 模型不得进任何路由组的成员/规则目标）、规则 use/more 须为本组成员、每条规则有 `use`、**每组 members 或 match 至少有一个非空**（`hidden:true` 墓碑豁免；默认兜底按组 routing 模式，不强制 `compact:true`）、routing/affinity/effort 枚举、`levels` 的元素必须是强度**字符串**（`levels:[[]]` 这种不可哈希元素要先判类型再查集合，否则 `[] in {…}` 抛 TypeError——**出判决而不是抛异常**是这里的标准，崩的代价也不止一条报错：doctor 会据此判「校验器崩了」而**整段抑制形状诊断**，apply 只能回「这是崩溃报告不是对你配置的判决」）、where/time/exceptFolders 等类型结构、数值字段必须是有限数（`NaN`/`Infinity` 不是合法 JSON，一律拒绝——放行就等于把非标准 JSON 写进 `providers.json`）、**dict 的键也过 secret-like 判据，并且同样过「占位残留」与「存不进 UTF-8」那两条**（键会原样落进 `providers.json`，只查值等于给「凭据当键」留了一条路；同一个理由也推出键侧那两条——实测漏判时 validate 打 `PASS`，危害推到 apply 写盘那一刻才出现，报的是「write failed part-way」而不是「你的键存不进去」；键里留 `<role:` 占位写法同样进配置，因为 render 只展开成员与 classifier，**键永远不会被展开**）、**provider 的 id 一律给长度摘要**（它是内网主机名，两段式也算——全局表刻意放过两段主机名，但 provider id 没有「模型名带点」这种误伤顾虑）；**模型引用里的 provider 段同样不给原样**：主机形态（含点，如 `llm.internal`）也给长度摘要，内网网关名不能借一条模型引用绕回来；不含点的短标识符（如 `acme`）照原样显示——否则每条报错都变成 `<ref 4 chars>/…`，可读性归零。这条住在 `shield()` 里，不在某个报错点上——回显面有四个（validate 报错、doctor 组行、apply 的 diff 段、doctor 的降级面），只补一处就会从别的面漏回去。**还拒「存不进 UTF-8 的字符」**：合法 JSON 允许孤立代理对（形如反斜杠 u + 四位十六进制的转义写法），python 也收，但它按 UTF-8 编码时会炸——而配置、产物、临时文件全是 UTF-8，这种东西**根本存不进去**。所以它是一条指到 JSON 路径的 finding，而不是写盘那一刻才炸出来的 traceback（e2e 第 125 条）。
6. **应用（用 `scripts/apply.py`，合并语义明确）**：
   - **先 dry-run**：`python3 -I scripts/apply.py <草案.json> ~/.config/magpie/providers.json`——先按 id 合并、再校验**合并结果**（不通过不合并、不写文件），然后展示合并计划：组级（新增/替换/保留）+ **每个被替换组的组内字段级变化**（成员增删 `±模型:强度`、列表字段纯换序标 `<字段>: order changed`（`rules` 重排另标 `rules: reordered`）、`routing`/`affinity`/`classifier` 等标量旧→新、规则数与**逐条规则的改向/条件/强度变化**（`rules[0].use: 旧 → 新`）、权重逐键旧→新、**被删掉的字段标 `→ (unset)`**；内容相同标 `identical`，纯换序标 `reordered`）。**「两侧看着一样但值确实不同」按面各有说法**（同一个改动落在 `members` 还是 `more` 上，说法必须同义；三态表见下），别混用：标量字段与 `more` 折叠先按**同一张三态表**判（与成员列表共用判据，同一个说法在两处必须同义）：核心引用没变（换通道）用 `differ only inside a masked segment`（差别落在被掩的那段）；核心引用变了用 `the reference itself was replaced`（说成「只换了通道」就是骗人——审批者会以为成本很低）；核心也被掩、分不清用 `the model and the channel cannot be told apart`；不是模型引用的自由文本用 `the value is withheld; the two values differ`（整条值被扣下）；容器字段塌成同形用 `shape only: the values differ inside`（值里并没有凭据）；`where` 的值被扣下用 `the values are withheld; the two differ`；**成员串**里只差 `#账号` 段的用 `differ only inside a masked segment`（差别落在被掩的那段，模型没变）；**自由文本**（`note`/`name` 这类整条被扣下的）用 `the value is withheld; the two values differ`——自由文本**不是**「差别落在被掩那段」：它没有任何一段被掩过；成员列表里有条目只差被掩那段用 `changed only inside a masked segment`；**换了模型/供应商**（剥掉 `#账号` 后的核心引用变了）用 `the model reference was replaced`——这两种混成一句会让人以为只是换了通道，而换模型恰恰是批准写入时最该看见的一种；`members` 以外的列表字段（`levels` 等）换的是**条目**，说 `the entry was replaced`（拿「模型引用」去描述别的字段就是撒谎）；`more` 列表与成员列表**各桶都要披露**——用 if/elif 只报第一个桶会把「分不清」那部分整个吞掉；**模型段也被掩时工具分不清**是换了模型还是换了通道——那就明说 `the model and the channel cannot be told apart`，不许二选一给一句可能是假的断言（多条成员掩成同一形态时，配对优先挑「核心引用相同」的那条，否则「两个模型各换了通道」会被说成「模型引用被换掉」）；**交叉配对退回保守话**：两条成员各自换了通道、又彼此能配上时，「谁对应谁」本身分不出来，那一条仍说 `the model and the channel cannot be told apart`，不许挑一条讲成「只换通道」。**成员列表与 `more` 的配对判据是同一个入口**（`pair_masked`，单真源）：两处各写一份，同一个改动落在 `members` 和落在 `more` 上就会给出不同说法，而「同一个改动在两处必须同义」正是这一族措辞唯一的存在理由；整组降级时用 `the values are withheld (shape only); the entries differ`。反向也钉住：两侧掩后**确实不同**时不许打这些句子。**三态措辞只属于「这一面真的按段掩过」**（echo=True 的字段）：`note` 里贴一条模型引用（`route acme/m:high#team-a`）仍然是自由文本，拿「模型引用被换掉」或「差别落在被掩那段」描述它就是假的——判据要看本面的 echo，不能只看值的形态。**「分不清」只能留给 `#账号` 段也不同**的那一条：账号段两侧**逐字相同**而核心被掩时，通道没变，差异只能落在被掩的那一段——那是确定的换条目（`the model reference was replaced`），在这里说「分不清」是一句事实为假的保守话（e2e 第 120 条一正一反钉住）。规则的 `intent` 与 `note` 同属「整条被扣下的自由文本」，等长改动必须带同一句 `the value is withheld; the two values differ`：少那一句，`<text 6 chars> → <text 6 chars>` 读起来就是「没改」，而 intent 恰恰是意图分发的判据（e2e 第 122 条）。**存量侧的列表元素不参与「换模型/换通道」那套措辞**：那些元素**不过 validate**（合并结果里该字段的值是草案侧的，校验器看不见旧值），diff 面必须自己防类型畸形——非字符串元素不配对、照原样打成 `-旧 +新`（否则一句 `TypeError` 让 dry-run 与 `--write` 连一行判决都没有，实测过：存量 `match: [5]` 配草案 `match: ["5"]`）。整组降级那一面**根本不取三态桶**——取一个空桶再去按 key 索引会 KeyError，dry-run 与 `--write` 一起走不下去（e2e 第 121 条）。**回显字符串过两道闸**：①只有模型引用/枚举字段才回显，`note`/`name`/`intent`/未知键等自由文本一律只给 `<text N chars>`（**两侧都是**：草案侧「已过校验」不是回显理由，校验只拒已知前缀的凭据，两段内网主机名与连字符分隔的长 token 都能过校验）；②整组先过密钥/endpoint 形态自查（走 validate.py 的**单真源**入口 `looks_secret`/`looks_endpoint`：它们先剥控制字符再判形态——换行不能切断一条连续凭据，抄一份正则 search 就会漏），命中就把该组 diff 全部降级成形态摘要——校验的是合并结果，**被替换组的存量侧不过校验**，任何字段都可能夹带凭据，**不写文件**。校验对象必须是合并后的全量 groups：classifier 跨组分离、组引用存在这类守卫只在合并结果上才成立（只校验草案孤岛会既漏判跨组冲突，又误拒「草案引用已存在组」这种合法写法）。
   - 把 dry-run 的合并计划**连同组内变化一起展示给使用者**（upsert 是整组替换，草稿没写的字段会被删——`→ (unset)` 那几行必须让使用者看见），得到明确确认后才加 `--write` 写入。`--write` 会**先备份**（`providers.json.bak-<时间戳>`，保留原文件权限如同秒重跑加序号不覆盖）、按 group `id` **upsert**（同 id 替换该组对象、新 id 追加末尾、其余原样保留）、**只动 groups 不碰 providers**，**正式写入是原子替换**（同目录临时文件写完再 `os.replace`，与 render 同一写法：中途磁盘满 / 超单文件大小上限 / 进程被杀，都不会在活配置的位置留下半份文件——那种情况下 apply 自己的「读回比对 + 写回原文」根本不会跑，因为跑它的进程已经死了），并在**写盘前重读目标文件核对内容没变**（本机有人在运行期间改了它就停下、什么都不写，避免把别人的改动抹掉），写后做**读回磁盘校验**（providers 段逐键不变 + 落盘 groups 合法）。**原子替换会绕过只读位**，而那个只读位是使用者自己立的护栏（「这份配置别动」）——所以目标文件不可写时照旧拒绝，不静默覆盖（目录只读是另一回事：那时临时文件都建不出来，走同一条可读 FAIL）；「findings 来自存量组」那条指引**只属于不合格分支**——崩溃分支里没有 findings，跟在 traceback 后面打它等于凭空造出一个不存在的对象。写入损坏或校验失败会**自动把写盘前读到的原文写回**（不是从备份文件读回来，措辞要如实；备份文件同时保留）并非零退出；写回本身失败会给可读 FAIL 与备份路径，不抛 traceback。**写盘本身失败**时按「读回比对原文」决定备份去留：文件与原文一致（没被打开过，如只读目标）就删掉备份并说「原文件未动」；可能被写坏（中途失败留下截断）就先把原文写回去，写回成功才删备份；两者都失败才保留备份并把路径打出来——备份是那时唯一完好的副本，不能顺手删掉。**删备份这件事本身也会失败**（备份目录只读、文件被别人占着），那时如实说「备份留下了」并给路径，**不许**打成「没留下备份」：后者会让读者以为磁盘上没有任何完好副本，实际是有一份没清掉——排查时这两件事完全相反。草案里若带 providers 段会被忽略（只合并 groups），脚本会提示。
   - 若校验报的问题出在**本次不替换的存量组**，那是使用者现有配置的问题：先用 doctor.py 诊断，与使用者确认后再决定怎么处理，不要为了通过校验擅自改动存量组。
   - 诊断现有配置用 `python3 -I scripts/doctor.py ~/.config/magpie/providers.json`（只读，**输出是英文**，组结构含 `affinity` 与 order 类组（`order`/`drain`）首位成员 + 校验结果 + `shape findings:` 形状诊断 + 接线冒烟步骤，不含密钥与 endpoint 形态（**两段主机名作为 provider 段一律给长度摘要**：`llm.internal`、`proxy.corp` 这类内网网关名不给原样；**不含点的短标识符**（`acme`）与**模型名里的点**（`acme/model.v2.pro` 的 model 段）照旧可读，理由与代价见 `examples/demo/README.md`）；**冒烟步骤本身含对活实例的 CLI 写操作**，按里面的隔离说明执行）。配置畸形（providers 非对象列表、groups 非 list）会明确 FAIL，不会谎报「尚未配置」。**退出码语义**：0=诊断完成（**含校验或形状发现问题**）、1=文件/JSON/畸形、2=用法——结论看输出的 `validation:` 与 `shape findings:` 两段，**不要**用 `doctor.py && …` 当闸门（有问题时它会打印提醒）。形状诊断抓的是 schema 合法但吃亏的配法（单成员的叶子组（除 `manual`，它不做故障转移）＝该组内无退路，缺省 `smart` 也在射程内；两个 order 类组共享同一成员（同模型同档）却首位不同——**可能是刻意不锚，也可能是回写把首位挪走，工具分不出**；两条首位同基名但档位不同——这条按 `validate.base_model` 比，漏判它最贵（档位进缓存键）。**两条粒度不同**：前者只认完全相同的成员串，按基名配会在刻意不锚的组上刷噪声（这两个数来自**临时把判据放宽的副本**，仓库里的代码没有这个开关；复现入口是**跑那份副本** `python3 -I ./doctor-relaxed.py examples/demo/output.groups.json`（跑正式脚本拿到的不是这两个数），读数就在那份夹具上：放宽到基名并保留「至少在一组居首」→ 6 对，连「居首」一起去掉 → 7 对，其中只打印 6 对 + `(+1 more pairs not listed)`，配对上限是 6；配对按成员建索引枚举候选对，不是所有组两两比，有条数预算；预算按成员**轮转**消耗（按成员名字母序推进会让排序靠后的共享成员吃不到预算、漂移直接漏报），超预算时**独立**披露「这份列表只是下界、没被检查过的候选对可能整个没被检出」——即使一条都没匹配上也要说，绝不把「没查完」写成 `none`）；后者必须按基名比。同组混档；`usage`/`rotate`/`weight` 组档位不一致（这三个都假设成员可互换）。混档那行里解析不出的档位打 `?` 并写明 `(? = unparseable tier)`，缺 id 的组打 `<no id>`（doctor 自己的哨兵，不是配置内容）。**`first=` 列是形态、不是身份**：两条**不同**的成员串掩完可能一模一样（同长度的 `acme/<model N chars>:high` 就会撞），doctor 会在组表之后打一条 note 说有几个形态撞了——别把撞形的两行读成「两组同锚同档」。**射程要读准**：只看不含 `group/` 成员的叶子组（主路由不参与）；首位类判据只配对 order 类组（= `order` 与 `drain`，见模式 8；`usage`/`weight`/`rotate`（以及 `pace`）没有首成员语义）；配了 `match` 的组**完全跳过**单成员判据（输出里不会有任何相关句子——还有模式成员兜着，且跨模式成员的故障转移未实测）；裸引用与 `:low+high` 多级成员解析不出档位，档位类判据对它们沉默；载入 `validate.py` 失败时会打 `model-name and effort checks were NOT RUN (could not load validate.py)` 而不是 `none`；`validation:` 段同理——**判据是「载不载得进来」不是「文件在不在」**：文件在但语法坏/是半成品拷贝时，子进程以 SyntaxError 退出而那份报错没有崩溃头部行 → 会被判成「没崩」→ 段里只剩一个空行，读起来像「校验没查出问题」；两种故障都要明说 `validation not run`（缺比较器就不能假装查过；不依赖比较器的单成员判据仍会跑），并额外声明**组行的 id、首位成员与 classifier 列此时按形态放行**（不在封闭表里的串一律给 `<ref N chars>`；`routing`/`affinity` 只有在落在已知枚举词上时才原样出现（组行的 `routing` 列：空串打 `(empty)`，**非字符串**打 `(invalid)`——把畸形值说成「配了但配成空」是一句事实为假的话））。降级面是 deny-by-default：只有封闭枚举表（模式名、档位词、doctor 自己的哨兵 `(unset)`/`(empty)`/`(invalid)`/`-`/`<no id>`/空串）里的字面量可原样打印，其余一律掩——判据不能是「像不像名字」，凭据本身也可以是个合法 identifier。**按词放行不等于按列放行**：恰好等于表里某个词的**组 id** 会原样出现在 id 列，所以别把那一列读成「必然是形态摘要」。同一句声明还会说清**首位、漂移与档位那几条判据在降级时同样不跑**（拿被掩后的形态比较会凭空造出「相同」），只有单成员与重复组 id 两条判据仍会跑。降级不是「一切照常只是少几项」：那份表里的读数只够看组结构，模型名与档位的结论一概没有。**至少两组 order 类组才有首位可比**，单组配置的漂移在这里不可见——这句现在由 doctor **自己打出来**（`first-member checks: nothing to compare here — only 1 order-like leaf group(s)`）：不打印就等于让读者把「没报警」读成「首位没问题」，而那正是这条判据要防的唯一一种误读。**对称漂移也看不见**：锚在全部组里都被挪到非首位时，落盘数据与「各组有自己的锚、只共用一个便宜备胎」完全同形，只看落盘分不出——那种只能靠复跑同一份草案（`members: order changed`）抓。重复组 id 会先单独声明一条（否则后面的判据看起来「同一个 id 自相矛盾」）。**还有第三种状态：校验器跑得起来却什么都没打**（退出码 0、stdout 全空）。validate 的每个出口都必然打印一行判决，所以「rc=0 且 stdout 全空」只能解释为**没跑到判决**——一份被截断成「只剩定义」的 validate.py 正落在这一档。判据住在 `validate.no_verdict`（单真源，apply 与 doctor 共用）：apply 直接拒合并、不写文件、不留孤儿备份，并且**不**把它说成「不合格」（那也是一句关于配置的假结论）；doctor 的 `validation:` 段打 `validation not run`，而不是留一个空行配上下面的 `shape findings: none`（e2e 第 123 条钉两个脚本口径一致）。判据**只看 stdout 里有没有判决行，不看退出码**：被 SIGKILL 这类信号杀掉时退出码是负的，而「非零」既可能是配置不合格也可能是没跑到——拿退出码推结论，就会把「没查」读成「查过且不合格」，那同样是一句关于配置的假结论。更早一档还有「校验器根本没开跑」：喂给它的临时文件建不出来（磁盘满、临时目录不可用）时 apply 照样拒绝合并、不写文件，并把原因打出来（`could not run the validator: …`），doctor 在 `validation:` 段说 `validate.py could not be started`——「没开跑」「没跑到」「跑了判它不合格」是三种状态，哪一档都不能被读成「查过且干净」。**判据表住在 `validate.PUBLIC_API`**：apply 需要的那几个名字（判决、崩溃、脱敏入口）少任何一个，apply 在**启动时**就 FAIL 并点名缺哪几条——半份判据跑出来的 PASS 是最坏的一种绿；doctor 不整段罢工，只把对应段降级成 `present but missing …` 的点名，其余读数照常。**校验器崩溃 ≠ 通过**：判崩据**只看 stderr**（stdout 是判决输出，不是崩溃报告），且 `Traceback (most recent call last)` 必须落在**第一条非空行**（前面一行别的都不许有）、并**紧跟一帧 `File "…"`**——只判「输出里出现过这一行」会被值本身骗过（`routing: "Traceback"` 这类合法 FAIL 也在 stdout 打出那样一行），只看 stderr 却不看位置，一样能被值在 stderr 里插行骗过去。这条判据在 `validate.validator_crashed`，**doctor 与 apply 共用**：apply 以前只看退出码，把校验器崩溃报成「你的合并结果不合格」，现在两边都分得清（e2e 第 75 条用同一份必崩夹具钉两个脚本口径一致）。**值伪造行首这条路已经关掉**：含控制字符的串在 `shield()` 里按 ascii 转义，值造不出新行（转义表覆盖 `\x00-\x1f`、`\x7f` 与 `U+0085`/`U+2028`/`U+2029`——后三个会被 `str.splitlines()` 切开但不属于 C0，漏掉它们等于留了一条伪造新行的路）。**顺序是「先按形态掩、再转义」**：反过来（先转义、整条原样返回）就等于「带控制字符就不脱敏」——凭据形态的串只要带一个换行就会整条原样打进终端（e2e 第 87 条钉死这一点）。**控制字符还不是判据的刀**：掩码判据作用在**去掉控制字符后的串**上，否则一个换行就能把一条连续凭据切成碎片、让「连续 16+ 位」判不出来（e2e 第 90 条）。转义**只转控制字符**，非 ASCII 原样保留（中文组 id 不该被转成 `\uXXXX`）——把整帧（头部行 + `File "…"`）写进组 id 也伪装不了崩溃（e2e 第 74 条把整帧那种最强构造也钉死）。真崩时 doctor 打 `the validator CRASHED` 提醒，形状段**只打** `not evaluated:` 而**不列任何 finding**（崩溃时形状判据可能读到畸形结构，那段不是结论；把结论和「不是结论」一起打出来，读者无从取舍）。`groups` 为空时整段不存在——只打「尚未配置路由」，别把「没有 `shape findings:` 段」读成「形状没问题」。判据出处：模式 9（故障转移）、模式 13 与坑 3（首位）、模式 3 的代价段与经验 1（档位）、模式 2 与经验 2（可互换前提）。
   - **写后验收（先验接线，再评价组）**：接线语义、陷阱与读数的真源是 [docs/concepts.md](docs/concepts.md) 的「agent 入口」一节——**先读它**，尤其这条：**两参数形式 `magpie <agent> X`，`X` 不是该 agent 的字段名时就是「把主 model 设成 `X`」**（`magpie claude opus` 写 `"model": "opus"` 并让 magpie 退出该 agent；`magpie codex run` 写 `model = "run"`，因为 `run` 只有 claude 有）。操作面：只读用单参数 `magpie ls` / `magpie <agent>`；写接线 `magpie <agent> group/<id>`；改字段 `magpie <agent> <field> <value>`；恢复默认 `magpie <agent> <field> default`（claude 的四档默认＝回主 model，其它字段＝该字段自己的默认）；改接线只影响新会话，claude 可用 `magpie claude run` 起验收会话。验收证据 = `~/.config/magpie/routing/<日期>.jsonl` 里那一轮带 `group.id`（那一轮 `group` 为 `null` 只说明它没走组，**不能据此断定入口是具体模型**，同一节里有反例）。**没看到这条记录就不要宣称已生效**；无法自动验证时给接线冒烟步骤（doctor.py 会打印，里面含 CLI 写操作）。

## 红线

- 探测/实测本机配置一律用解析器只输出字段名或 id/models，**禁止全文件 Read/cat**（密钥会进入上下文）。
- 永不重新生成或修改供应商连接配置（endpoint、key）——使用者本机已有。
- 不把密钥写入本仓库或任何输出（这是红线，但红线是「**已知前缀的凭据**绝不打印」，不是「任意形态的 token 都能认出来」：熵判据只认**连续** 16+ 位字母数字，带分隔符的长 token（UUID 形那种）**不在射程内**——这是为了让真实模型名可读而付的代价。形态判据的射程与已知漏网形态写在 `examples/demo/README.md`）；示例一律使用虚构供应商与虚构密钥。
- **classifier 分离**：意图判断模型（`intent/judge`）只做意图判断，绝不进路由成员/规则目标/兜底。
- 配置 schema 用 `intent` / `effort:"on"` / `compact:true` / `more` / `where:[{field,op,value}]`。**rule 字段名以 JSON 为准**（`where`、`time` 对象、`exceptFolders` 驼峰）；CLI 旗标名 `when`/`tz`/`days`/`except-folders`/`at` 不是 JSON 字段（写进 JSON 会被 magpie 静默忽略）；**不要**把运行时日志里的 `n`/`held`/`classified`/`when` 当配置写法。
- **组级同理**：CLI `weight=`/`listed=` 的 JSON 真键名是 **`weights`**（成员引用→1..1000 整数，键含 `:effort`）与 **`unlists`**（bool）；glob/`re:` 模式写进独立的 **`match`** 数组，**不是 `members`**（写进 members 会被当字面模型 id 跳过）。键名错→静默忽略；**类型错→整份 providers.json 解析失败且 CLI 退出码仍 0**。
- **classifier 需要消费者**：组里至少一条 `intent` 规则或 `effort:"auto"`，否则 CLI 的 `classifier=` 被静默丢弃；有消费者却缺 classifier 则硬报错。宽模式（`match:["acme/*"]`）会把 classifier 模型拉进路由组，校验器查不出——用窄模式或让 classifier 用独立供应商。
- **实测本机 magpie 二进制时必须真隔离**：只设 `HOME` 不够（CLI 按端口连活实例，会改到真实配置）。加 `MAGPIE_ADDR=127.0.0.1:1` 并先断言 `magpie status --json` 的 `running` 为 `false`；方法见 `docs/schema.md` 末节。
- 默认兜底按**组的 routing 模式**（未命中规则→照组本来方式路由：`order`/`drain` 按成员顺序（首成员先用，`drain` 那条是推论、见 schema.md 待验证清单）、`usage` 按额度分摊），不是 `compact:true`；`compact:true` 只是压缩触发条件。
- `affinity`、规则/成员指向组（`group/<id>`）均已实测支持；其余未验证项见 `docs/schema.md` 待验证清单——不要当作已支持特性写进配置。
- **主链锚定是模板的默认形状**（取舍见 `docs/patterns.md` 模式 13）：会话会跨意图互切的那几组，`members[0]` 写同一个模型、组内一律同档、并设 `affinity: session`。改成员强度等于换缓存键；要逐组换模型家族就用字面量成员，别打散锚。改 `templates/groups.template.json` 必须**同批**重生成 `examples/demo/output.groups.json`——`scripts/docgate.py` 对 `templates/*.json` 只看顶层键集合，不会替你发现组内漂移；模板形状由 `scripts/e2e.sh` 的断言守着。

## 文档索引

- `CHANGELOG.md`：对使用者可见的变更记录（按日期，每条括注提交号；本仓库不打版本标签，版本即 git 提交号）。
- `CONTRIBUTING.md`：贡献指南（环境与版本底线、怎么跑验收、怎么启用提交闸、公开面怎么定义、PR 期望、维护者侧 review 档案流程、许可）。
- `docs/concepts.md`：两层路由、池路由 vs 故障转移、compact vs 默认兜底、classifier 独立、affinity 粘性、配置与日志区分。
- `docs/schema.md`：字段参考（逐字段标来源与校验状态）、routing 12 模式（含 manual）/ affinity 5 值语义、member 写法、组嵌套、待验证清单。
- `docs/patterns.md`：13 条模式——主模式（两层意图分发）+ 子组模式（池、每模型强度、多通道分摊、classifier 独立）+ 通用模式 6–13（含会话粘性、主链锚定）+ 复现配方 + 真实案例与「落盘与观测的坑」。
- `templates/roles.json`：6 个模型角色（含独立 `intent/judge`）；每角色 `signals`（名字正/负信号 + 需确认的能力 + 排序偏好）与 `mapping_rules`；mapping 为「角色 → 有序模型列表」。
- `scripts/render.py`：把角色列表映射展开进模板（成员多模型展开 + @effort 覆写 + classifier 取首元素裸引用）；mapping 的键与元素都是使用者写的串，报错也走 `validate.q()` 同一张脱敏表（第四个输出面）。**渲染产物本身也要过一遍**：产物里有 secret-like 的串就**不打印也不写盘**（凭据一进终端就等于带进了上下文；validate 事后会拒，但那时已经打过一遍）；**键也要查**（`levels`/`weights` 这类映射的键就是使用者的串）；按**熵**或**主机名/endpoint** 形态可疑、但无已知前缀的串**只警告不拦**——长模型名、点分模型名与 token、内网主机名形态完全同形，硬拦会把好配置也堵死，但使用者有权知道自己在终端里打了什么；拒绝写盘的**每个**分支（凭据形态拒绝、非有限数拒绝、写盘失败）都要说「目标路径上还留着上一次的陈旧文件、本次没更新它」——漏一个分支，那个分支的读者就不知道自己看的是旧产物。警告按**位置**计数（同一个串落在 6 处就说 6 处，不是「1 个串」），只列前 3 条位置并明说**还剩几条没列**——按去重后的串数报会让另外几处根本定位不到。可疑形态包括两段主机名（`llm.internal`）——三段形态在 endpoint 表里，两段不在，但两段同样是内网拓扑；警告走 **stderr**（stdout 是产物本体，掺进警告会把 JSON 弄脏）；只重定向 stdout 的调用方会漏掉它——这是有意的取舍，捕获 stderr 才是完整用法。**产物不受「回显脱敏」约束**：那条约束管的是报错与诊断文字，render 的产物就是**配置本体**（要原样进 providers.json）——凭据形态的产物会被拒绝，其余形态只警告。**产物必须是严格 JSON**：模板里的 `NaN`/`Infinity` 一律拒绝（`allow_nan=False`），stdout 与文件两个出口都是——产物是要进 `providers.json` 的配置本体，写出非标准 JSON 等于让下游解析器整份读不回来；这道闸**排在可疑形态警告之前**：警告的措辞是「它们会原样打出来」，在一次什么都没打的运行里先打它就是谎报——同一个理由，**警告整条挪到「产物真的产出来了」之后**才打；**先编码、再碰目标路径**（`out.encode("utf-8")` 成功之后才落盘）：模板里可以有存不进 UTF-8 的字符，而「先截断再写」会把上一次的产物清成 0 字节、手里只剩一句 traceback。**落盘是原子的**：同目录临时文件写完再 `os.replace`——`write_bytes` 同样是**先截断再写**，磁盘满、超过单文件大小上限、进程中途被打断，任何一种都会在目标路径上留下半份产物（实测旧产物 5099 字节被截成 4096 字节的残片：旧的读不回来、新的解析不出，而报错还写着「nothing was written」）。replace 之前目标文件始终是完整的旧内容，失败时要么旧的全在、要么新的全在，没有第三种状态；换 inode 的两条代价也都处理了——符号链接按真实落点替换（不会把链接换成普通文件），权限位显式搬过去（临时文件默认 0600，直接 replace 会悄悄改掉旧产物的权限位）；失败路径上那个临时残片一定删掉，目录里留半份文件同样是垃圾。**stdout 那条路接住 `BrokenPipeError`**：下游 `| head` 提前关掉管道不是渲染失败——产物已经算出来了，只是没人读；只往 stderr 打一句 note、不甩 traceback（退出码仍非零，那是管道断掉的惯例信号，但调用方去 stderr 找错时不会读到一段根本不存在的错误）；入口类型闸：模板顶层不是对象、或 `groups` 不是 list → 可读 FAIL（不甩 AttributeError）；旁边缺 `validate.py`（只拷走这一个脚本）同样干净 FAIL 并说破是安装坏了。
- `scripts/apply.py`：草案按 id upsert 合并进本机配置（dry-run 默认；校验合并结果 + 展示组内字段级变化，`--write` 备份+写后读回校验+失败自动恢复，只动 groups）。`--write` 成功后打印**漂移复跑指引**：magpie 曾被观测到在之后的回写里重排 `members`（本机一次观测，触发规则未知），刚写完的读回几乎总是与草案一致（重排发生在 magpie 之后的回写），那种比对查不到漂移；要查漂移就用同一份草案再跑一次不带 `--write`。旁边缺 `validate.py` 时同样干净 FAIL（校验与脱敏表都在那里），不甩 traceback；只拷走**半份**也算安装坏了：apply 启动时按 `validate.PUBLIC_API` 核对那几个名字还在不在，缺谁点谁的名，然后停下——判据自己不全时，跑出来的 `PASS:` 毫无意义。落盘口一律不把异常当结论：备份建不出来、写回失败、目标读不回来，都只有可读 FAIL 与备份路径，`except` 还要连 `ValueError` 一起接——磁盘上的原文可能含存不进 UTF-8 的字符，那时「把原文写回去」这件事根本做不到。喂给校验器的临时文件按 ASCII 转义写法落盘（`ensure_ascii=True`），否则同一类字符会让**判决还没开始**就抛异常（转义解码回来是同一个串，判据不受影响）。
- `scripts/doctor.py`：只读诊断现有配置（组结构含 `affinity` 与 order 类组（`order`/`drain`）首位成员 + 校验 + **形状诊断**：重复组 id、单成员的叶子组（**除 `manual` 与配了 `match` 的组之外的所有模式，含 routing 缺省的 `smart`**）、共享同一成员却不同时以它开头（**刻意不锚或锚被挪走，工具分不出**）、首位同基名不同档、同组混档、`usage`/`rotate`/`weight` 组档位不一致 + 接线冒烟步骤；输出英文且脱敏（遮蔽形态共四种：`<ref N chars>` / `provider/<model N chars>:档位` / `x#<account N chars>` / 含控制字符时的形态（**判可疑就整串掩成 `<ref N chars>`**，N=原串长度；不可疑才 ascii 转义），判据在 `validate.py` 单真源。**回显与检测共用同一组形态常量与同一个剥控制字符的入口**（`validate.looks_secret` / `looks_suspicious` / `looks_endpoint` / `looks_host`），但**射程有意不同**：拒绝（检测）侧只认**已知前缀的凭据**，回显侧额外掩熵与主机形态——这条红线是收窄过的（收窄的理由：把无前缀的高熵串也拒收会连带吃掉长模型名，把好配置堵死）。所以同一份配置可能出现「validate 说 PASS、doctor/apply 把那个串掩掉」：那是**两面的射程不同，不是判据打架**；控制字符不是判据的刀——凭据形态靠「前缀 + 连续 16 位」的连续性，一个换行就能把它切成碎片，所以两处都先剥控制字符再判；只堵回显侧、不堵检测侧，就会出现「脱敏表认为它是凭据、检测器认为它干净」，validate 的报错、doctor、apply 与 render **四个输出面共用**——组 id、`weights` 键、`mapping` 元素，以及 **apply diff 里的字段名**（存量侧的键不过校验）都走这一张表；点分模型名与 endpoint 同形 → 一律掩，宁可少显示可读性；provider 段自己就是主机形态**或自己就是那个高熵 token** 时整串掩，不保留骨架；另有**熵判据**——串里出现 16+ **连续** alnum 即判熵（`#账号` 段阈值 12），无已知前缀的高熵串也掩，前缀名单追不上真实凭据；**射程**：靠连字符/下划线分隔的长串不在射程内（真实模型名就长这样），要收这个口就得连带吃掉模型名），冒烟步骤含对活实例的 CLI 写操作）。形状问题是**建议**，`validate` 接受这些写法，发现问题也退 0；射程与「看不见什么」见上面「诊断现有配置用 `doctor.py`」那条 bullet。
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
