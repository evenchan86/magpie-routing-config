# 贡献指南

本仓库是**文档 + 模板 + 脚本**三件套：交给使用者的是「怎么设计 magpie 路由」的方法，以及一套自己能跑的校验、诊断、合并工具。改代码前先读 [AGENTS.md](AGENTS.md)（agent 工作流与红线）与 [docs/schema.md](docs/schema.md)（字段参考）。

产品门面是英文 README（[README.md](README.md)）与中文 README（[README.zh.md](README.zh.md)）；本仓库的实质性文档（`docs/`、`AGENTS.md`、本文件与 `CHANGELOG.md`）都是中文。

## 环境

- **Python**：脚本本体 3.7+ 即可——只用标准库，不需要 `pip install` 任何东西（实测 3.7.6、macOS 自带的 3.9.6、3.13.5 均正常，含写盘失败路径）。**跑验收套件要 3.12+**：套件里有一个夹具要编码 1000 层嵌套的 JSON 值，低于 3.12 的 CPython 会在 `json` 模块里直接 `RecursionError`（实测 3.7 与 3.11 的 `json` 编码器都在这一步挂掉）。套件开头会先查版本并说人话，不会甩栈给你。
- **bash** 与 **git**：跑验收套件与提交闸用。
- **magpie**：只有要真的改自己的本机配置时才需要（已装好、配好供应商即可）；脚本与验收套件本身都不依赖 magpie 在跑。

## 跑验收

```bash
bash scripts/e2e.sh
```

期望最后一行形如 `E2E PASS: 143 checks`（条数随套件增长，以实际输出为准），退出码 0。套件在临时目录里用假 HOME 跑，**不碰你的真实配置**。

## 提交闸（建议开）

仓库自带 git 原生 pre-commit hook：

```bash
git config core.hooksPath .githooks
```

它跑的是公开面文档同步那一档：

```bash
python3 -I scripts/commit-gate.py --docs-only
```

提交闸分两档：

| 模式 | 查什么 | 给谁用 |
|---|---|---|
| `--docs-only` | 公开面 ↔ 公开文档 | 所有人。仓库自带 hook 用这个 |
| 默认（无旗标） | 上面那条 + 当日 review 档案的「文档对照」小节 | 维护者的个人 review 工作流 |

另一档要的档案目录（`docs/superpowers/code-reviews/`）是本机过程目录，在 `.gitignore` 里、不随仓库分发——**外部贡献者没有它，也不需要它**。`git commit --no-verify` 是 git 既定的跳过语义，闸门拦不住也不假装拦得住。

## 「公开面」是什么

只有三类，其余改动（函数体、注释、内部重构）不触发文档同步：

1. 任意 `scripts/*.py` 的 `usage` 行（CLI 签名）；
2. `scripts/validate.py` 里被 `scripts/docgate.py` 的 `PUBLIC_CONSTANTS` 点名的常量；
3. `templates/*.json` 的顶层键。

改了公开面 → **同批必须同步公开文档**。确属纯内部改动时，在改动里加一行独立注释并写明理由（**理由至少 6 个字符**）：

```python
# doc-sync: 纯内部修复，不改公开行为
```

豁免按文件生效，且只认 `scripts/`、`templates/` 里的独立注释行——文档里讲解豁免写法的示例不算数。

## PR 期望

- 一笔改动只做一件事。提交消息是**永久公开历史**：里面的计数、归因、引文会被读者照着核，写之前对着仓库里的事实核一遍。
- 公开文档里写脚本调用的地方都要与脚本自己的 `usage` 对得上——`scripts/e2e.sh` 会逐块校验**形如 `python3 -I scripts/<name>.py` 的调用**（位置参数个数与旗标白名单，以脚本源码为准）；写成别的拼写（如漏了 `-I`）不会被校验到。
- 中英 README 要同步改：套件会比对两版的行数、`## ` 标题数、表格行数、围栏数与链接序列。
- 改 `templates/groups.template.json` 必须**同批**重生成 `examples/demo/output.groups.json`（模板的组内形状由套件的断言守着，文档闸只看顶层键）。
- 不要提交真实配置、密钥或本机绝对路径。`.gitignore` 挡掉了常见形态，但**兜底靠人**。
- 验证靠 `scripts/e2e.sh`（隔离验收），本仓库不新增单元测试文件；改动要么有一条对应的验收用例，要么说明为什么现有用例已经覆盖它。

## 维护者侧：review 档案流程

`scripts/commit-gate.py` 的默认模式要求当日 review 档案（`docs/superpowers/code-reviews/` 下以当日日期开头的 `.md`）含「文档对照」或「文档同步」小节：逐个公开文件写「相关 / 无关 + 依据」，至少提到 3 个公开文件。该目录在 `.gitignore` 里，是本地过程目录，不随仓库发布。

## 许可

代码与文档均为 MIT，见 [LICENSE](LICENSE)。你提交的内容按同一许可发布。
