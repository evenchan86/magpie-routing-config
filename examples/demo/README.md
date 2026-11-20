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
- **输出脱敏**（形态判据单真源在 `scripts/validate.py`，三个输出面共用同一张表）：
  - **diff 段**：自由文本（`note`/`name`/未知键）只给 `<text N chars>`；整组还会先过一遍密钥/endpoint 形态自查，命中就把该组 diff 全部降级为形态摘要——校验的是合并结果，**被替换组的存量侧不过校验**，任何字段都可能夹带凭据。
  - **报错、组 id、首位成员**（`validate.py` 的 `unknown model ref`、`apply.py` 的重复 id、`doctor.py` 的组行与形状诊断）过 `shield()`，输出三种形态：`<ref N chars>`（整串可疑）、`provider/<model N chars>:档位`（model 段含三段点分域名）、`模型引用#<account N chars>`（只有账号段可疑）。后两种刻意保留骨架：组结构与档位是诊断要读的东西，不是凭据。
  - **代价要认**：点分模型名（如 `acme/model.v2.pro`）与 `acme/<内部 endpoint>` 形态完全同形，只看落盘分不出，只能一律掩。**骨架不是永远都在**：`:档位` 只在尾部正好是已知档位词时才保留（`acme/model.v2.pro` → `acme/<model 12 chars>`，没有档位尾巴）；串里没有 `/` 时（组 id、裸值）退化成 `<ref N chars>`（实测组 id `acme.leak.host.example` → `<ref 22 chars>`）。**绝不打印密钥或 endpoint**——这一句现在由 `validate.py` 的 `q()` 兜底：报错文本里每个插进去的组 id、成员引用、字段名、权重键都过 `shield()`。
- **输入闸门**：组元素必须是对象、id 必须是非空字符串、两侧 id 不得重复——重复 id 会让 upsert 静默丢组，故两侧都直接拒绝（**存量侧**的报错会指向 `doctor.py` 让你先修现有配置）。
- `--write` 会**先备份**（`providers.json.bak-<时间戳>`，保留原权限、同秒重跑加序号）、写入后**读回磁盘校验**（providers 段逐键不变 + 落盘 groups 合法），任何一步失败**自动从备份恢复**并非零退出。
- **漂移要复跑查**：magpie 曾被观测到在之后的回写里重排 `members`（把锚挪出首位；本机一次观测，触发规则未知）。刚写完的读回几乎总是与草案一致（只有 magpie 恰好在写入窗口内插一手才会不同，本机没观测到），所以那种比对查不到漂移，工具只打一行指引——隔段时间用**同一份草案**再跑一次不带 `--write`，漂移会显式打成 `members: order changed`；`doctor.py` 只看落盘配置也能报「共享同一成员却不同时以它开头」和「首位同模型但不同档」（需要两组 order 类组才有得比，单组配置的漂移在这里不可见）。**还有一类看不见**：锚在**所有**组里都被挪到非首位时，落盘数据与「各组有自己的锚、只共用一个便宜备胎」完全同形，只看落盘的判据分不出——这种对称漂移只能靠复跑同一份草案那条路抓。
- 写完还要**接线冒烟**，而且**先验接线再评价组**：用 `magpie ls` / `magpie <agent>`（单参数形式）确认 agent 入口指向 `group/<id>` 而不是某个具体模型——入口是具体模型时组级的一切都不参与。改接线用 `magpie <agent> group/<id>`，只影响新会话；验收证据是 `~/.config/magpie/routing/<日期>.jsonl` 里那一轮带 `group.id`（单行 `null` 不能断定入口是模型）。接线语义与陷阱见仓库 `docs/concepts.md` 的「agent 入口」一节；`doctor.py` 会打印这些步骤（含对活实例的 CLI 写操作）。

本 demo 只跑 dry-run，不执行写入。
