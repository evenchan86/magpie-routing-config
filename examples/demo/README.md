# Demo：虚构供应商的两层路由走通示例

用不存在的供应商 `acme/*` 演示 agent 工作流的输入与产物，不含任何真实模型或密钥。

## 文件

| 文件 | 对应工作流步骤 | 说明 |
|---|---|---|
| `input.providers.json` | 2. 探测 | 模拟使用者本机已有的供应商配置（密钥为虚构值） |
| `roles.mapped.json` | 3. 映射 | 使用者确认后的「角色 → 有序模型列表」映射（6 角色，含独立的 `intent/judge`；主模型在前，可多个做故障转移/池） |
| `output.groups.json` | 4. 渲染 | `scripts/render.py` 把模板成员 `<role:X>:强度` 展开为该角色所有模型各带强度后的两层路由产物（主路由 `auto` + 8 子组） |

## 两层结构

- 主路由 `auto`：`classifier=acme/judge`（取 `intent/judge` 列表首元素）只做意图判断，规则 `use=group/g-xxx` 分发到子组；无命中按成员顺序兜底到第一位 `group/g-code`。
- 8 个任务子组：成员是「模型:强度」（如 `acme/code-standard:high`），各带 `routing`（`order` 故障转移 / `usage` 额度分摊）。**子组内多模型**由映射列表长度决定——例如 `code/general=[acme/code-standard, acme/code-backup]`、`fast/cheap=[acme/lite-chat]`，模板 `g-code` 的 `[<role:code/general>:high, <role:fast/cheap>:medium]` 展开为 `[acme/code-standard:high, acme/code-backup:high, acme/lite-chat:medium]`（三模型有序链）。
- 同一角色槽的强度施加到该角色所有模型（uniform-per-slot）；需逐模型不同强度时渲染后手动微调。
- `acme/judge` 只出现在 `auto.classifier`，**绝不**进任何组的成员/规则目标/兜底。

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
# 组引用存在/禁自包含/深度≤8、classifier 分离、每组 members 非空（默认兜底按组 routing 模式）
python3 -I scripts/validate.py /tmp/demo-rendered.json /tmp/demo-known.json

# 隔离验收：render.py 渲染 = 模板 + 映射，且与 output.groups.json 一致，含多模型展开与正反向断言
bash scripts/e2e.sh
```

## 应用（步骤 6）

真实使用中，agent 会把 `output.groups.json` 的 `groups` 数组按 **group id upsert** 合并进使用者本机配置：同 id 替换该组，新 id 追加，其余组与 providers 段原样保留；先备份、展示合并 diff、经使用者确认后写入，再做路由冒烟验证。本 demo 不执行写入。