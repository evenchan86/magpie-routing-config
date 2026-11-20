# 变更记录

本仓库**不打版本标签**：版本就是 git 提交号，`git log` 即版本史。本文件按日期记录**对使用者可见**的变更——CLI 签名、脚本行为、文档契约。内部重构、注释与措辞打磨不记（那些在 `git log` 里）。

每条后面括注提交号，可直接复核：

```bash
git show --stat <hash>
```

## 脚本 CLI 契约（截至 2026-11-20）

| 脚本 | 用法 | 退出码 |
|---|---|---|
| `scripts/validate.py` | `validate.py <groups.json> [known-models.json]` | 0 / 1 / 2（见下） |
| `scripts/render.py` | `render.py <template.json> <mapping.json> [output.json]` | 0 / 1 / 2 |
| `scripts/apply.py` | `apply.py <draft-groups.json> <providers.json> [--write]` | 0 / 1 / 2 |
| `scripts/doctor.py` | `doctor.py <providers.json>` | 0 诊断完成（含发现问题）/ 1 文件或 JSON 错误 / 2 用法 |
| `scripts/commit-gate.py` | `commit-gate.py [--docs-only]` | 0 / 1 / 2 |
| `scripts/docgate.py` | 无命令行入口 | — |

退出码：**0 = 通过**，**2 = 你把命令写错了**（参数给少了、或旗标不对），**1 = 结论是不合格**（校验没通过、诊断读不了文件、提交闸没同步文档）。

「多余参数」另有待遇，**不报用法错**：`validate.py` 只吃两个（第三个被忽略），`render.py` 的第四个被忽略——所以这两个脚本传多了参数不会退 2。

两条容易踩的：

- **doctor 发现问题时仍退 0**（形状问题与校验 FAIL 都算「诊断完成」的一部分），别拿 `doctor.py && ...` 当闸门用。
- **脚本自己崩了时退出码也是 1**（那是 Python 的默认），所以要读输出：看见 `Traceback` 说明是崩溃，不是判决。校验器崩溃或被杀时，`apply.py` / `doctor.py` 会显式说「没有判决」。

`scripts/docgate.py` 是**共享判定库**（公开面提取、豁免解析、从脚本 `usage` 解析 CLI 契约），被 `scripts/e2e.sh` 与 `scripts/commit-gate.py` import，不是独立闸。

> 上表是**手工同步**的副本，真源是各脚本自己的 `usage:` 行。改了 CLI 签名就一并改这张表——公开文档里的 bash 块由闸门逐条校验，这张表不在闸门覆盖范围内。

## 2026-11-20

### 形状诊断进入机器检查（`53fa47e`）

- `doctor.py` 新增 `shape findings:` 段：重复组 id、单成员的叶子组、两个组共享同一成员却不同时以它开头、首位同基名不同档、同组混档等形状问题按**建议**报出（发现形状问题仍退 0）。判据与校验器共用同一批常量，不抄第二份；校验器载入失败时报「没跑」而不是「没发现问题」。
- 形状段的段首限定语里声明判据出处的文档语言（输出是英文、判据出处是中文文档）。

### 模板改成我们推荐的形状（`d785a9c`）

- 会话会跨意图互切的那几组（`g-code` / `g-heavy` / `g-arch` / `g-review` / `g-test`）首位是同一个锚模型、组内一律同档、并设 `affinity: session`；`auto` / `g-compact` / `g-ui` 三处**刻意不设**粘性，`g-light` 刻意不锚——取舍见 `docs/patterns.md` 模式 13。

### 回显脱敏收成单真源（`53fa47e`、`526a78f`）

- 校验器里的脱敏入口成为「报错中回显用户可控串」的唯一入口，doctor、apply、render 三个下游输出面共用同一张表（render 是后接上的）。
- 遮蔽形态共四种：`<ref N chars>`、`provider/<model N chars>:档位`、`x#<account N chars>`，以及**含控制字符的串**——先按形态判（可疑才整串掩成 `<ref N chars>`，长度按原串算），再 ascii 转义；转义只是展示层，不替脱敏干活。

### 「没查成」与「写坏盘」不再被当成结论（`526a78f`）

- 校验器崩溃或被信号杀掉时，`apply.py` 报「校验器没有出判决」（no verdict），不再把这次失败算成「你的配置不合格」；`doctor.py` 在形状段写明「not evaluated: … not a verdict」，不让读者把它读成「查过且干净」。
- `render.py`：产物凭据闸、入口类型闸、拒绝 `NaN`/`Infinity`、原子落盘（临时文件 + `os.replace`，失败不留半份产物）、stdout 的管道被提前关掉时只往 stderr 打一句（退出码仍非零）。
- `apply.py --write`：备份建不出来或写失败 → 可读 FAIL，并删掉本次新建的备份；写盘前重读目标文件；只动 `groups`。
- diff 段的措辞按「到底能确定什么」分开写，不再笼统说成「一样」或「变了」：差异只在被掩段里（`differ only inside a masked segment` / `changed only inside a masked segment`）、引用本身被换掉（`the reference itself was replaced` / `the model reference was replaced` / `the entry was replaced`）、模型与通道分不出来（`the model and the channel cannot be told apart`）、两个值都被掩住且不同（`the value is withheld; the two values differ` / `the values are withheld; the two differ`）、只有形状可比（`shape only: the values differ inside`）。

### 其它（`2b9ab5a`、`da9bc7d`）

- doctor 的接线冒烟步骤补上「用 CLI 写」的路径（此前只写「magpie 没有 CLI 路由接管」）。
- `apply.py` 写盘后的下一步指引不再写死组名，并说清「从**新**会话发一次请求、看路由日志里有没有 `group.id`」。

### 写盘失败不再甩栈、验收套件先查版本（`ec98dd1`）

- `render.py` 与 `apply.py` 的写盘失败路径不再用 3.8 才有的 `unlink(missing_ok=…)`：3.7 上那里原本会甩 TypeError 盖掉真正的错因、还留下半份残片（render 的那条路径实测复现），现在是可读 FAIL 且不留残片。
- 验收套件开头先查 Python 版本：低于 3.12 时说人话并退出，而不是跑到一半甩一段 `RecursionError` 栈。

## 2026-11-17

- `docs/patterns.md` 说清「按任务分档」的缓存代价与适用范围，补 4 条落盘实测（`3d477f4`）。

## 2026-11-15

### 架构重构为两层意图分发（`3cd7031`）

- 单层蓝图重构为「主路由 classifier + 8 个任务子组」的两层意图分发；`validate.py`、`docs/schema.md`、`docs/patterns.md`、`templates/` 同步重写。

### 角色 → 有序模型列表，新增 `render.py`（`d4dc0f1`）

- 一个角色可映射多个模型，渲染后一个子组有多成员（故障转移链 / 额度池）。

### 逐模型强度覆写（`d3cb1e7`）

- mapping 支持 `model@effort`，同一子组可以混强度。

### 工作流工具化：新增 `apply.py` 与 `doctor.py`（`6d52757`）

- `apply.py` 按 id upsert 合并进本机配置（默认 dry-run，合并结果校验 + 写后读回守卫）；`doctor.py` 只读诊断现有配置。

### schema 对齐真实落盘形态（`bf41975`）

- 实测推翻三条 schema 结论并改写字段参考：模式成员另立 `match` 字段（pattern-only 组的 `members` 落盘为 `null`）、CLI 旗标与 JSON 真键名不同（`weight` → `weights`、`listed` → `unlists`，写错会被静默忽略）、键名写错与类型写错的后果完全不同（后者会让整份配置解析失败而 CLI 退出码仍是 0）。校验器随之对齐。

### 选型启发式结构化 + 合并计划显示组内变化（`b817806`）

- 模型名切段后整段匹配信号，负信号否决正信号；合并计划显示组内字段级变化，带两道脱敏闸门。

### 文档与事实修正（`12e0f90`）

- 补齐落后于代码的公开文档，修正 6 处事实失真。

### 文档同步做成三道闸（`89752f7`、`0f9b13b`）

- 新增 `scripts/docgate.py`（共享判定库）、`scripts/commit-gate.py`（提交闸）、`.githooks/pre-commit`（仓库自带 git 原生 hook）。公开面只有三类：`scripts/*.py` 的 `usage` 行、`docgate.py` 的 `PUBLIC_CONSTANTS` 白名单、`templates/*.json` 的顶层键。
- 提交闸下沉到 git 原生 hook：命令怎么拼写（`git -C`、`git -c`、`--no-pager`、`--amend`）都照样触发——靠正则匹配命令的外部 hook 会被绕开。

### 视觉（`da4b0d3`）

- 双语 README 视觉刷新，新增 3 张项目原生 SVG。

## 2026-11-14

- 首次公开发布：路由蓝图 + 校验器 + 模板 + 虚构供应商示例 + 验收套件（`3e7a818`）。
- 修复 e2e 的 README 链接检查只覆盖英文版的问题（`b26f1b3`）。
