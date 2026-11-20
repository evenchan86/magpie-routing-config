# Demo：虚构供应商的两层路由走通示例

用不存在的供应商 `acme/*` 演示 agent 工作流的输入与产物，不含任何真实模型或密钥。

## 文件

| 文件 | 对应工作流步骤 | 说明 |
|---|---|---|
| `input.providers.json` | 2. 探测 | 模拟使用者本机已有的供应商配置（密钥为虚构值） |
| `roles.mapped.json` | 3. 映射 | 使用者确认后的「角色 → 有序模型列表」映射（6 角色，含独立的 `intent/judge`；主模型在前，可多个做故障转移/池）。候选由 `templates/roles.json` 的 `signals` 给出——模型名切段后整段匹配正/负信号，同角色内负信号否决，无信号的模型照常列给使用者确认 |
| `output.groups.json` | 4. 渲染 | `scripts/render.py` 把模板成员 `<role:X>:强度` 展开为该角色所有模型各带强度后的两层路由产物（主路由 `auto` + 8 子组） |

## 两层结构

- 主路由 `auto`：`classifier=acme/judge`（取 `intent/judge` 列表首元素）只做意图判断，规则 `use=group/g-xxx` 分发到子组；无命中按成员顺序兜底到第一位 `group/g-code`。
- 8 个任务子组：成员是「模型:强度」（如 `acme/code-standard:high`），各带 `routing`（`order` 故障转移 / `usage` 额度分摊）。**子组内多模型**由映射列表长度决定——例如 `code/general=[acme/code-standard, acme/code-backup]`、`fast/cheap=[acme/lite-chat]`，模板 `g-code` 的 `[<role:code/general>:high, <role:fast/cheap>:high]` 展开为 `[acme/code-standard:high, acme/code-backup:high, acme/lite-chat:high]`（三模型有序链，备用与主力同档）。
- **主链锚定**：`g-code`/`g-heavy`/`g-arch`/`g-review` 的 `members[0]` 都是同一个模型（`acme/code-standard:high`），组内一律同档，且都带 `"affinity": "session"`（usage 组 `g-test` 的首位成员也是这个锚——它唯一成员的角色是 code/general，渲染后展开成该角色的所有模型，demo 里 = 主力 + 备用模型）——按设计，会话跨意图切换时不换模型，因此不该重建前缀（本仓库没有跨组命中的观测，`docs/patterns.md` 模式 13 的数字只是方向，不是已实测的收益）。`auto`/`g-compact`/`g-ui` 刻意不带 `affinity`（理由见 `templates/groups.template.json` 各组 note，取舍见 `docs/patterns.md` 模式 13）。
- 同一角色槽的强度默认施加到该角色所有模型；单个模型可用 `@effort` 覆写。demo 的 `design/ui=["acme/vision-designer@high"]` 演示了这点：g-ui 槽位是 `:medium`，但 `acme/vision-designer` 覆写为 `:high`，于是 g-ui = `[vision-designer:high, code-standard:medium, code-backup:medium]`（同组混强度）。
- `acme/judge` 只出现在 `auto.classifier`（裸引用，不带强度），**绝不**进任何组的成员/规则目标/兜底。

## 复现

```bash
# 渲染：模板成员 <role:X>:强度 按映射列表展开（多模型子组），classifier 取首元素
python3 -I scripts/render.py templates/groups.template.json examples/demo/roles.mapped.json /tmp/demo-rendered.json

# 已知模型清单（脱敏：只取模型名）
python3 -I -c "
import json
d=json.load(open('examples/demo/input.providers.json'))
print(json.dumps(sorted({m for p in d['providers'] for m in p['models']})))
" > /tmp/demo-known.json

# 完整校验：字段白名单、无占位、无密钥、模型引用已知（含 classifier）、
# 组引用存在/禁自包含/深度≤8、classifier 分离、每组 members 或 match 至少一个非空
# （hidden:true 墓碑豁免；默认兜底按组 routing 模式）、weights/match/unlists 等真实键名与类型
python3 -I scripts/validate.py /tmp/demo-rendered.json /tmp/demo-known.json

# 合并预演（dry-run，不写任何文件）：把产物按 group id upsert 进 demo 夹具，
# 先校验【合并结果】再展示合并计划；demo 夹具没有同名组，故全部是 add
python3 -I scripts/apply.py examples/demo/output.groups.json examples/demo/input.providers.json

# 隔离验收：render.py 渲染 = 模板 + 映射，且与 output.groups.json 一致，含多模型展开与正反向断言
bash scripts/e2e.sh
```

## 应用（步骤 6）

真实使用中由 `scripts/apply.py` 完成，**默认 dry-run**：

```bash
python3 -I scripts/apply.py <草案.json> ~/.config/magpie/providers.json          # 预演，不写盘
python3 -I scripts/apply.py <草案.json> ~/.config/magpie/providers.json --write  # 使用者确认后才写
```

- **先按 group id upsert，再校验合并结果**（不是只校验草案孤岛）：同 id 替换该组对象、新 id 追加末尾、其余组与 providers 段原样保留。不通过就不合并、不写文件。
- **展示合并计划**：组级新增/替换/保留，加上**每个被替换组的组内字段级变化**——成员增删 `±模型:强度`、列表字段纯换序 `<字段>: order changed`（`rules` 重排另标 `rules: reordered`）、`routing`/`classifier` 等旧→新、规则逐条改向与条件、权重逐键、**被删掉的字段标 `→ (unset)`**（upsert 是整组替换，草案没写的字段会消失）。内容相同标 `identical`。
- **输出脱敏**（形态判据单真源在 `scripts/validate.py`，validate 的报错 / doctor / apply / render 四个输出面共用同一张表）：
  - **diff 段**：自由文本（`note`/`name`，以及两侧都查不到的未知键）只给 `<text N chars>`。`where` 的 `field`/`op` 看着像枚举，但 `validate.py` **只校验结构、从不校验取值**，存量侧也不过校验 → 只放过 `ECHO_WHERE_FIELDS`/`ECHO_WHERE_OPS` 两张白名单里的值（`tokens`/`contains`… 原样回显，diff 才读得出），名单外的一律按自由文本给形态。**存量侧的字段名也过 `shield()`**：合法字段名是短词、原样通过，怪键换成 `<ref N chars>`。整组还会先过一遍密钥/endpoint 形态自查，命中就把该组 diff 全部降级为形态摘要——校验的是合并结果，**被替换组的存量侧不过校验**，任何字段都可能夹带凭据。
  - **报错、组 id、首位成员**（`validate.py` 的每条报错文本**含报错路径里的每一段与 dict 键**、`apply.py` 的重复 id 与 diff 段的组标签、`doctor.py` 的组行与形状诊断、`render.py` 的 mapping 报错）过 `shield()`，输出只有四种形态：`<ref N chars>`（整串可疑）、`provider/<model N chars>:档位`（model 段含三段点分域名）、`模型引用#<account N chars>`（只有账号段可疑），以及**含控制字符**的串：判可疑就**整串掩成 `<ref N chars>`**（N=原串长度），不可疑才按 ascii 转义显示。后两种刻意保留骨架：组结构与档位是诊断要读的东西，不是凭据。除凭据前缀与 endpoint 形态外还有一条**熵判据**：串里**任意位置**出现 16+ 连续 alnum 就判熵（`#账号` 段阈值 12）——`sk-`/`ghp_`/`AKIA` 这类前缀名单永远追不上真实凭据，**无已知前缀的 token 也是 token**。熵判据命中且串里有 `/` 时仍走 `provider/<model N chars>:档位`，只掩 model 段本体（档位是漂移判据的输入）；但 provider 段**自己**就是主机形态或自己就是那个高熵 token 时整串掩成 `<ref N chars>`，因为那时没有可信骨架（实测 `网关.internal.example/模型:high` → `<ref 27 chars>`；`<20 位连续字母数字>/ops` 这种合法组 id 同样整串掩）。注意判据是**形态**：`内部网关/模型:high` 这种 provider 段不含点的写法仍然原样回显。计数一律按被掩本体的长度，所以 `<ref 22 chars>` 里的数字就是原串长度；**含控制字符**的串若被判可疑，一律**整串**掩成 `<ref N chars>`（长度按**原串**算、不给骨架）——否则同一段输出里会出现两种长度口径（骨架里的计数按「去掉控制字符后的串」算）。
  - **代价要认**：点分模型名（如 `acme/model.v2.pro`）与 `acme/<内部 endpoint>` 形态完全同形，只看落盘分不出，只能一律掩。**骨架不是永远都在**：`:档位` 只在尾部正好是已知档位词时才保留（`acme/model.v2.pro` → `acme/<model 12 chars>`，没有档位尾巴）；串里没有 `/` 时（组 id、裸值）退化成 `<ref N chars>`（实测组 id `acme.leak.host.example` → `<ref 22 chars>`）。**绝不打印密钥或 endpoint**——由 `validate.py` 的 `q()` 兜底：报错文本里每个插进去的组 id、成员引用、字段名、权重键，以及**报错路径里的每一段（含 dict 键）**，都过 `shield()`。**降级路径 deny-by-default**：`doctor.py` 载入不到 `validate.py` 时，只有那张封闭枚举表（模式名、档位词、以及 doctor 自己的哨兵 `(unset)`/`(empty)`/`(invalid)`/`-`/`<no id>`/空串）里的字面量可以原样打印，其余一律掩成 `<ref N chars>`——判据不能是「像不像名字」，凭据本身也可以是个合法 identifier。**一个必须知道的例外**：恰好等于表里某个词的**组 id** 也会原样出现在 id 列（表是按词放行、不是按列放行），所以那一列不是「全是形态摘要」。组 id 缺失时打 `<no id>`（哨兵，不是配置内容；打空列会被读成「这一行属于上面那个组」）。**刻意不掩的两类**：只含一个点的串（模型名里带点很常见，掩了回显就读不懂，于是 `#user@example.com` 这类两段域名原样保留）；以及枚举词本身。**熵判据的射程**也要写清：它认的是**连续** 16+ 位字母数字，所以靠连字符/下划线分隔的长串（UUID 形 token、带短横线的 base64 那种）**不在射程内**——这是为了让真实模型名可读而付的代价，收紧成长度+分隔符的总长判据会把 `claude-3-5-sonnet-20241022` 这类模型名一起吃掉。**红线与射程要分开读**：红线是「**已知前缀的凭据**绝不打印」，不是「任意形态的 token 都能认出来」——带分隔符的 token 形态认不出来，那是这条熵判据的已知代价。**控制字符**不在这张形态表里另算：含换行/ESC/BEL 的串一律按 ascii 转义回显，值不得在终端里造出新行；转义表覆盖 `\x00-\x1f`、`\x7f` 与 `U+0085`/`U+2028`/`U+2029`（后三个会被 `str.splitlines()` 切开但不属于 C0，漏掉它们等于留了一条伪造新行的路）。**顺序是「先按形态掩、再转义」**：反过来（先转义、整条原样返回）就等于「带控制字符就不脱敏」——凭据形态的串只要带一个换行就会整条原样打进终端。**控制字符还不是判据的刀**：掩码判据作用在**去掉控制字符后的串**上，否则一个换行就能把一条连续凭据切成碎片、让「连续 16+ 位」判不出来。转义**只转控制字符**，非 ASCII 原样保留（中文组 id 不该被转成 `\uXXXX`）。
  - **被掩不等于没改**：`apply.py` 的 diff 是批准写入的唯一证据物。成员只差 `#账号`（换通道）时两侧掩完长得一样，工具不写 `order changed`，而是明说改动确实存在。**「看不见的改动」按面各有说法，别混用**：**成员串**里只差 `#账号` 段的用 `differ only inside a masked segment`（差别落在被掩的那段，模型没变）；**标量字段与 `more` 列表**用同一张三态表：换通道同上，换了模型用 `the reference itself was replaced`，核心也被掩分不清时用 `the model and the channel cannot be told apart`——标量路径若一律说「只换了通道」，审批者会以为成本很低，实际换了模型；**自由文本**（`note`/`name` 这类整条被扣下的）用 `the value is withheld; the two values differ`——等长的 `name` 改动属于这一类：`<text 8 chars> → <text 8 chars> (the value is withheld; the two values differ)`（它**不是**「差别落在被掩那段」：这一条里没有任何一段被掩过）；容器字段塌成同形用 `shape only: the values differ inside`（值里并没有凭据）；`where` 的值被扣下用 `the values are withheld; the two differ`；成员列表里有条目只差被掩那段用 `changed only inside a masked segment`；**换了模型/供应商**（剥掉 `#账号` 后的核心引用变了）用 `the model reference was replaced`——这两种混成一句会让人以为只是换了通道，而换模型恰恰是批准写入时最该看见的一种；`members` 以外的列表字段（`levels` 等）换的是**条目**，说 `the entry was replaced`；**模型段也被掩时工具分不清**是换了模型还是换了通道——那就明说 `the model and the channel cannot be told apart`，不许二选一给一句可能是假的断言（多条成员掩成同一形态时，配对优先挑「核心引用相同」的那条，否则「两个模型各换了通道」会被说成「模型引用被换掉」）；整组降级时用 `the values are withheld (shape only); the entries differ`。三种措辞都表示「改动是真的，只是落在不显示的那段」，但**不是**「那是凭据」。**这套措辞只属于「这一面真的按段掩过」的字段**：`note` 里贴一条模型引用仍然是自由文本，只会打「值被扣下了」——判据看的是本面掩没掩，不是值的形状。**「分不清」只属于 `#账号` 段也不同**的那条：两侧账号段逐字相同而模型段被掩时，通道没变，这时说的就是 `the model reference was replaced`（说「分不清」是把一个看得清的改动说成看不清）。等长的 `intent` 改动与 `name` 同属「值被扣下、两侧确实不同」那一类，说法完全一样。自由文本**两侧都只给形态**（`intent` 也一样）：草案侧「已过校验」不是回显理由，校验只拒已知前缀的凭据。反向也钉住了：两侧掩后**确实不同**时不许打这些句子；raw 相同的纯换序仍然只打 `order changed`。
- **render 的产物也要过一遍**：产物里若有 secret-like 的串（**键也查**——`levels`/`weights` 这类映射的键就是使用者的串），render **不打印也不写盘**（凭据一进终端就等于带进了上下文；validate 事后会拒，但那时已经打过一遍）；按**熵**或**主机名/endpoint** 形态可疑、但无已知前缀的串**只警告不拦**（警告走 **stderr**：stdout 是产物本体，掺进警告会把 JSON 弄脏；只重定向 stdout 的调用方会漏掉它）——长模型名、点分模型名与 token、内网主机名形态完全同形，硬拦会把好配置也堵死，但你会知道自己往终端里打了什么；拒绝时若目标路径上还有上次留下的文件，会明说「未被更新」。**产物不受「回显脱敏」约束**：那条约束管的是报错与诊断文字；render 的产物就是**配置本体**，它要原样进 providers.json——凭据形态的产物会被拒绝打印与写盘，其余形态只警告。**编码失败也一个字节都不碰目标路径**：产物先按 UTF-8 编码，编不出来（模板里有存不进 UTF-8 的字符）就直接可读 FAIL——「先截断再写」会把上一次的产物清成 0 字节；**写文件是原子的**（同目录临时文件写完再替换）：磁盘满、超过单文件大小上限、进程中途被打断，都不会在目标路径上留下半份产物——要么旧的完整、要么新的完整，失败时临时残片也被清掉。代价是换 inode，所以符号链接按真实落点替换、权限位显式搬过去。**往 stdout 打产物时被 `| head` 之类提前关掉管道**不算渲染失败：只往 stderr 打一句 note，不甩 traceback（退出码仍非零，那是管道断掉的惯例信号）；这类字符 `validate.py` 也会拒并指到它所在的 JSON 路径。警告在**产物真的产出来之后**才打，那句「它们会原样打出来」到这时的才是真话；每条拒绝写盘的分支（包括「权限不够写不进去」）都会说「目标路径上还是上一次的产物」。
- **输入闸门**：组元素必须是对象、id 必须是非空字符串、两侧 id 不得重复——重复 id 会让 upsert 静默丢组，故两侧都直接拒绝（**存量侧**的报错会指向 `doctor.py` 让你先修现有配置）。
- `--write` 会**先备份**（`providers.json.bak-<时间戳>`，保留原权限、同秒重跑加序号）、**写盘前重读目标文件核对内容没变**（运行期间有人改了它就停下、什么都不写，并说明「changed on disk」，避免把别人的改动抹掉）、写入后**读回磁盘校验**（providers 段逐键不变 + 落盘 groups 合法），任何一步失败**自动从备份恢复**并非零退出。**正式写入是原子替换**（同目录临时文件写完再换）：中途磁盘满、超过单文件大小上限、进程被杀，都不会在活配置的位置留下半份文件；代价是换 inode，所以按真实落点替换符号链接、权限位显式搬过去。**目标文件不可写时照旧拒绝**——原子替换会绕过只读位，而那是你自己立的「这份配置别动」的护栏，工具不替你拆。
- **漂移要复跑查**：magpie 曾被观测到在之后的回写里重排 `members`（把锚挪出首位；本机一次观测，触发规则未知）。刚写完的读回几乎总是与草案一致（只有 magpie 恰好在写入窗口内插一手才会不同，本机没观测到），所以那种比对查不到漂移，工具只打一行指引——隔段时间用**同一份草案**再跑一次不带 `--write`，漂移会显式打成 `members: order changed`；`doctor.py` 只看落盘配置也能报「共享同一成员却不同时以它开头」和「首位同模型但不同档」（需要两组 order 类组才有得比，单组配置的漂移在这里不可见——不足两组时 doctor 会明说 `first-member checks: nothing to compare here`，不会默默什么都不打）。**还有一类看不见**：锚在**所有**组里都被挪到非首位时，落盘数据与「各组有自己的锚、只共用一个便宜备胎」完全同形，只看落盘的判据分不出——这种对称漂移只能靠复跑同一份草案那条路抓。
- 写完还要**接线冒烟**，而且**先验接线再评价组**：用 `magpie ls` / `magpie <agent>`（单参数形式）确认 agent 入口指向 `group/<id>` 而不是某个具体模型——入口是具体模型时组级的一切都不参与。改接线用 `magpie <agent> group/<id>`，只影响新会话；验收证据是 `~/.config/magpie/routing/<日期>.jsonl` 里那一轮带 `group.id`（单行 `null` 不能断定入口是模型）。接线语义与陷阱见仓库 `docs/concepts.md` 的「agent 入口」一节；`doctor.py` 会打印这些步骤（含对活实例的 CLI 写操作）。

本 demo 只跑 dry-run，不执行写入。
