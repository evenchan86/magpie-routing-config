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
- 8 个任务子组：成员是「模型:强度」（如 `acme/code-standard:high`），各带 `routing`（`order` 故障转移 / `usage` 额度分摊）。**子组内多模型**由映射列表长度决定——例如 `code/general=[acme/code-standard, acme/code-backup]`、`fast/cheap=[acme/lite-chat]`，模板 `g-code` 的 `[<role:code/general>:high, <role:fast/cheap>:medium]` 展开为 `[acme/code-standard:high, acme/code-backup:high, acme/lite-chat:medium]`（三模型有序链）。
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
- **展示合并计划**：组级新增/替换/保留，加上**每个被替换组的组内字段级变化**——成员增删 `±模型:强度`、纯换序 `order changed`、`routing`/`classifier` 等旧→新、规则逐条改向与条件、权重逐键、**被删掉的字段标 `→ (unset)`**（upsert 是整组替换，草案没写的字段会消失）。内容相同标 `identical`。
- **输出脱敏**：自由文本（`note`/`name`/未知键）只给 `<text N chars>`；整组还会先过一遍密钥/endpoint 形态自查，命中就把该组 diff 全部降级为形态摘要。**绝不打印密钥或 endpoint**。
- **输入闸门**：组元素必须是对象、id 必须是非空字符串、两侧 id 不得重复——重复 id 会让 upsert 静默丢组，故两侧都直接拒绝（**存量侧**的报错会指向 `doctor.py` 让你先修现有配置）。
- `--write` 会**先备份**（`providers.json.bak-<时间戳>`，保留原权限、同秒重跑加序号）、写入后**读回磁盘校验**（providers 段逐键不变 + 落盘 groups 合法），任何一步失败**自动从备份恢复**并非零退出。
- 写完还要**接线冒烟**，而且**先验接线再评价组**：用 `magpie ls` / `magpie <agent>`（单参数形式）确认 agent 入口指向 `group/<id>` 而不是某个具体模型——入口是具体模型时组级的一切都不参与。改接线用 `magpie <agent> group/<id>`，只影响新会话；验收证据是 `~/.config/magpie/routing/<日期>.jsonl` 里那一轮带 `group.id`（单行 `null` 不能断定入口是模型）。接线语义与陷阱见仓库 `docs/concepts.md` 的「agent 入口」一节；`doctor.py` 会打印这些步骤（含对活实例的 CLI 写操作）。

本 demo 只跑 dry-run，不执行写入。