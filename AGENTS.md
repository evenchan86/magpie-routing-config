# AGENTS.md · magpie-routing-config

本文件是 agent 的唯一入口，`CLAUDE.md` 只引用本文件。

## 这个仓库是什么

开源的 **magpie 路由策略架构方案**：概念文档、配置 schema 参考、路由模式库、角色占位模板。不含任何真实密钥、真实模型 id 或任何机器的配置。

使用者是**已安装 magpie、已配好供应商**的人。你的任务：按下面的工作流，帮使用者基于**他本机已有的模型**生成**两层路由层**（主路由意图分发 + 任务子组）配置。

## 核心架构：两层意图分发

- **主路由 `auto`**：`classifier`（小而快的意图判断模型）判断每回合意图，规则 `use=group/<id>` 分发到任务子组；自身不做模型选择。无意图命中时按组 routing 模式兜底（`auto` 用 `order`，故首位 `group/g-code`）。
- **8 个任务子组**：`g-compact`/`g-test`/`g-light`/`g-code`/`g-heavy`/`g-arch`/`g-ui`/`g-review`，各自管理成员（`角色:强度`）与 `routing`（`order` 有序故障转移 / `usage` 额度分摊）。
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

3. **映射**：按 `templates/roles.json` 的启发式给出「角色 → 本机模型」建议（6 角色，含独立的 `intent/judge`），**必须经使用者确认**后填入 mapping。不要替使用者拍板模型选择。`intent/judge` 选一个小而快、不带推理的模型，且不得与任何路由角色复用同一模型。
4. **渲染**：用确认的 mapping 替换 `templates/groups.template.json` 中的 `<role:xxx>` 占位（含 `:effort` 后缀），产出两层路由层草案（主路由 `auto` + 8 子组）。使用者可增删意图、角色或子组。
5. **校验**：生成已知模型清单（脱敏）并对草案执行完整校验，必须通过：

   ```bash
   python3 -I -c "
   import json
   d=json.load(open('$HOME/.config/magpie/providers.json'))
   print(json.dumps(sorted({m for p in d.get('providers',[]) for m in p.get('models',[])})))
   " > /tmp/known-models.json
   python3 -I scripts/validate.py <草案.json> /tmp/known-models.json
   ```

   校验覆盖：字段白名单（rule 字段以 JSON 为准）、无占位残留、无密钥、模型引用已知（含 classifier）、组引用存在/禁自包含/嵌套深度≤8、**classifier 跨组分离守卫**（classifier 模型不得进任何路由组的成员/规则目标）、规则 use/more 须为本组成员、每条规则有 `use`、**每组 members 非空**（默认兜底按组 routing 模式，不强制 `compact:true`）、routing/affinity/effort 枚举、where/time/exceptFolders 等类型结构。
6. **应用（合并语义明确）**：
   - **先备份**原配置；**只合并 groups 路由层，不动 providers 供应商段**。
   - 合并规则：按 group `id` **upsert**——同 id 替换该组对象，新 id 追加到 groups 数组末尾；其余组原样保留。两层结构里主路由与子组都按 id upsert。
   - 写入前向使用者**展示合并 diff**，得到明确确认后才写入。
   - 写入后引导使用者在 magpie 中把 agent 路由指向 `group/auto`（摘要组按 magpie 摘要入口选择；入口未定位时请使用者在 UI 自行确认）。
   - **写后验收**：发一条简单测试请求，确认正常响应且路由到预期模型（可查 magpie 日志）；无法自动验证时，给使用者手动验证步骤，不要宣称已生效。

## 红线

- 探测/实测本机配置一律用解析器只输出字段名或 id/models，**禁止全文件 Read/cat**（密钥会进入上下文）。
- 永不重新生成或修改供应商连接配置（endpoint、key）——使用者本机已有。
- 永不把密钥写入本仓库或任何输出；示例一律使用虚构供应商与虚构密钥。
- **classifier 分离**：意图判断模型（`intent/judge`）只做意图判断，绝不进路由成员/规则目标/兜底。
- 配置 schema 用 `intent` / `effort:"on"` / `compact:true` / `more` / `where:[{field,op,value}]`。**rule 字段名以 JSON 为准**（`where`、`time` 对象、`exceptFolders` 驼峰）；CLI 旗标名 `when`/`tz`/`days`/`except-folders`/`at` 不是 JSON 字段（写进 JSON 会被 magpie 静默忽略）；**不要**把运行时日志里的 `n`/`held`/`classified`/`when` 当配置写法。
- 默认兜底按**组的 routing 模式**（未命中规则→照组本来方式路由：`order` 首成员优先、`usage` 按额度分摊），不是 `compact:true`；`compact:true` 只是压缩触发条件。
- `affinity`、规则/成员指向组（`group/<id>`）均已实测支持；其余未验证项见 `docs/schema.md` 待验证清单——不要当作已支持特性写进配置。

## 文档索引

- `docs/concepts.md`：两层路由、池路由 vs 故障转移、compact vs 默认兜底、classifier 独立、affinity 粘性、配置与日志区分。
- `docs/schema.md`：字段参考（逐字段标来源与校验状态）、routing 12 模式（含 manual）/ affinity 5 值语义、member 写法、组嵌套、待验证清单。
- `docs/patterns.md`：两层意图分发主模式 + 子组池模式 + 每模型强度 + 多通道额度分摊。
- `templates/roles.json`：6 个模型角色与映射启发式（含独立 `intent/judge`）。
- `examples/demo/`：虚构供应商的两层完整走通示例。

## 本仓库自身的开发命令

```bash
bash scripts/e2e.sh    # 隔离验收（假 HOME，不碰真实配置）
```