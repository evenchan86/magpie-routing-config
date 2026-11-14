# Demo：虚构供应商的完整走通示例

用不存在的供应商 `acme/*` 演示 agent 工作流的输入与产物，不含任何真实模型或密钥。

## 文件

| 文件 | 对应工作流步骤 | 说明 |
|---|---|---|
| `input.providers.json` | 2. 探测 | 模拟使用者本机已有的供应商配置（密钥为虚构值） |
| `roles.mapped.json` | 3. 映射 | 使用者确认后的「角色 → 模型」映射 |
| `output.groups.json` | 4. 渲染 | 用映射填充 `templates/groups.template.json` 后的路由层产物 |

## 复现

```bash
# 已知模型清单（脱敏：只取模型名）
python3 -I -c "
import json
d=json.load(open('examples/demo/input.providers.json'))
print(json.dumps(sorted({m for p in d['providers'] for m in p['models']})))
" > /tmp/demo-known.json

# 完整校验：字段白名单、无占位、无密钥、模型引用已知（含 classifier）、规则完整、compact 兜底
python3 -I scripts/validate.py examples/demo/output.groups.json /tmp/demo-known.json

# 隔离验收：渲染 = 模板 + 映射，且与 output.groups.json 一致，含正反向断言
bash scripts/e2e.sh
```

## 应用（步骤 6）

真实使用中，agent 会把 `output.groups.json` 的 `groups` 数组按 **group id upsert** 合并进使用者本机配置：同 id 替换该组，新 id 追加，其余组与 providers 段原样保留；先备份、展示合并 diff、经使用者确认后写入，再做路由冒烟验证。本 demo 不执行写入。