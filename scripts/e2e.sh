#!/usr/bin/env bash
# 隔离 E2E（两层路由）：不碰真实本机 magpie 配置。用法：bash scripts/e2e.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CHECKS=0
ok() { CHECKS=$((CHECKS+1)); echo "ok ${CHECKS} - $1"; }

# 0. Python 版本前置检查。套件里有一个夹具要编码 1000 层嵌套的 JSON 值，低于 3.12 的 CPython
#    会在 json 里抛 RecursionError——那时读者拿到的是一段栈，看不出是自己的 python 太老。
#    先说人话再跑。这一步不是一条验收用例（不满足就直接退出，不计入 CHECKS）。
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)'; then
  {
    echo "FAIL: the acceptance suite needs Python 3.12 or newer; the python3 on PATH is $(python3 -V 2>&1)."
    echo "      one fixture encodes a 1000-level nested JSON value; older CPython raises RecursionError inside json."
    echo "      the scripts themselves run on Python 3.7+; only this suite needs 3.12+."
  } >&2
  exit 1
fi

# 1. 假 HOME 夹具（虚构 acme 供应商）
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.config/magpie"
cp examples/demo/input.providers.json "$FAKE_HOME/.config/magpie/providers.json"
[ -f "$FAKE_HOME/.config/magpie/providers.json" ] && ok "isolated fake HOME fixture"

# 2. 渲染：render.py 把模板成员 <role:X>:强度 按映射【有序列表】展开（多模型子组）
python3 -I scripts/render.py templates/groups.template.json examples/demo/roles.mapped.json "$TMP/rendered.json" >/dev/null
ok "template renders with role->list mapping (render.py)"

# 3. 渲染产物与 demo 输出一致
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
a = json.loads((tmp/"rendered.json").read_text())
b = json.loads(Path("examples/demo/output.groups.json").read_text())
assert a == b, "rendered output diverges from demo"
PY
ok "rendered output matches demo"

# 4. 已知模型集合（demo 模型名自带 acme/ 前缀）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads(Path("examples/demo/input.providers.json").read_text())
models = sorted({m for p in doc["providers"] for m in p.get("models", [])})
(tmp/"known.json").write_text(json.dumps(models))
PY
ok "known model set derived from fixture"

# 5. validate 对 demo 产物 PASS
python3 -I scripts/validate.py "$TMP/rendered.json" "$TMP/known.json" >/dev/null
ok "validate PASS on two-layer demo"

# 6. 反向：占位残留必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["members"][0] = "<role:fast/cheap>"
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: placeholder accepted"; exit 1; fi
ok "placeholder draft rejected"

# 7. 反向：非法字段（日志 held；when/tz/days 等是 CLI 旗标名非 JSON 字段）必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
d["groups"][0]["rules"][1]["held"] = ["reasoning"]
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: unknown field accepted"; exit 1; fi
ok "unknown-field draft rejected"

# 8. 反向：规则内密钥必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
d["groups"][0]["rules"][1]["use"] = "FAKE-injected-secret"
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: secret accepted"; exit 1; fi
ok "secret-like draft rejected"

# 9. 反向：classifier 未知模型必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["auto"]["classifier"] = "acme/does-not-exist"
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: unknown classifier accepted"; exit 1; fi
ok "unknown classifier rejected"

# 10. 反向：顶层 providers 段必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
d["providers"] = [{"id": "acme", "key": "FAKE-top-level-key"}]
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" >/dev/null 2>&1; then echo "FAIL: top-level providers accepted"; exit 1; fi
ok "top-level providers section rejected"

# 11. 反向：缺 use 的规则必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
del d["groups"][0]["rules"][1]["use"]
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: missing-use accepted"; exit 1; fi
ok "missing-use rule rejected"

# 12. 反向：空成员（默认兜底失效）必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-code"]["members"] = []
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: empty members accepted"; exit 1; fi
ok "empty-members group rejected"

# 13. 反向：未知组引用必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["auto"]["members"][0] = "group/does-not-exist"
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: unknown group ref accepted"; exit 1; fi
ok "unknown group ref rejected"

# 14. 反向：自包含（组嵌套环）必须 FAIL，且输出 cycle 诊断、不崩溃
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-code"]["members"].append("group/g-code")
(tmp/"bad.json").write_text(json.dumps(d))
PY
OUT="$(python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" 2>&1)" && { echo "FAIL: self-inclusion accepted"; exit 1; }
if ! grep -q "cycle" <<< "$OUT"; then echo "FAIL: cycle not diagnosed: $OUT"; exit 1; fi
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: validator crashed on cycle"; exit 1; fi
ok "self-inclusion rejected with cycle diagnosis (no crash)"

# 15. 反向：classifier 模型进【本组】路由成员必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["auto"]["members"].append("acme/judge")
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: classifier-as-member accepted"; exit 1; fi
ok "classifier-as-routing-member rejected"

# 16. 反向：classifier 模型进【另一子组】成员必须 FAIL（跨组守卫，两层主架构）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-code"]["members"].append("acme/judge")
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: cross-group classifier accepted"; exit 1; fi
ok "cross-group classifier-as-member rejected"

# 17. 反向：规则 use 指向非成员模型必须 FAIL（magpie 强制成员资格）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-code"]["rules"] = [{"use": "acme/long-reader"}]
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: non-member use accepted"; exit 1; fi
ok "non-member rule target rejected"

# 18. 反向：错误 effort 后缀 ultra（应为 minimal；非法后缀→未知模型）必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["members"][0] = "acme/lite-chat:ultra"
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: ultra effort accepted"; exit 1; fi
ok "invalid effort suffix rejected"

# 19. 反向：非法 routing 模式必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["auto"]["routing"] = "bogus"
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: bogus routing accepted"; exit 1; fi
ok "invalid routing mode rejected"

# 20. 反向：非法 affinity 值必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["auto"]["affinity"] = "bogus"
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: bogus affinity accepted"; exit 1; fi
ok "invalid affinity rejected"

# 21. 反向：非法 useEffort 必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
d["groups"][0]["rules"][1]["useEffort"] = "bogus"
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: bogus useEffort accepted"; exit 1; fi
ok "invalid useEffort rejected"

# 22. 反向：意图规则缺 classifier 必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; del g["auto"]["classifier"]
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: intent without classifier accepted"; exit 1; fi
ok "intent rules without classifier rejected"

# 23. 反向：CLI 旗标名当 JSON 字段（except-folders）必须 FAIL（真实 JSON 名 exceptFolders）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["rules"] = [{"use": "acme/lite-chat", "except-folders": ["/x"]}]
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: CLI flag name accepted as JSON field"; exit 1; fi
ok "CLI-flag-name field rejected (JSON uses exceptFolders)"

# 24. 反向：布尔 intentSure 必须 FAIL（数值字段不接受 bool）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["auto"]["intentSure"] = True
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: bool intentSure accepted"; exit 1; fi
ok "boolean numeric field rejected"

# 25. 反向：where 为字符串（应为 {field,op,value} 数组）必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["rules"] = [{"use": "acme/lite-chat", "where": "tokens < 20k"}]
(tmp/"bad.json").write_text(json.dumps(d))
PY
if python3 -I scripts/validate.py "$TMP/bad.json" "$TMP/known.json" >/dev/null 2>&1; then echo "FAIL: string where accepted"; exit 1; fi
ok "malformed where rejected"

# 26. 正例：minimal 强度成员必须 PASS
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["members"][0] = "acme/lite-chat:minimal"
(tmp/"good.json").write_text(json.dumps(d))
PY
python3 -I scripts/validate.py "$TMP/good.json" "$TMP/known.json" >/dev/null
ok "minimal-effort member accepted"

# 27. 正例：tokens 条件（合法 JSON 字段，非密钥）必须 PASS
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["rules"] = [{"use": "acme/lite-chat", "tokens": 200000}]
(tmp/"good.json").write_text(json.dumps(d))
PY
python3 -I scripts/validate.py "$TMP/good.json" "$TMP/known.json" >/dev/null
ok "tokens condition accepted (not secret)"

# 28. 正例：exceptFolders（驼峰 JSON 名）必须 PASS
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["rules"] = [{"use": "acme/lite-chat", "exceptFolders": ["/x"]}]
(tmp/"good.json").write_text(json.dumps(d))
PY
python3 -I scripts/validate.py "$TMP/good.json" "$TMP/known.json" >/dev/null
ok "exceptFolders accepted"

# 29. 正例：where 条件数组（CLI when= 的 JSON 形态）必须 PASS
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["rules"] = [{"use": "acme/lite-chat", "where": [{"field": "tokens", "op": "lt", "value": "20k"}]}]
(tmp/"good.json").write_text(json.dumps(d))
PY
python3 -I scripts/validate.py "$TMP/good.json" "$TMP/known.json" >/dev/null
ok "where condition array accepted"

# 30. 正例：time 对象（{from,to,days,zone}，CLI time=/days=/tz= 的 JSON 形态）必须 PASS
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["rules"] = [{"use": "acme/lite-chat", "time": {"from": "09:00", "to": "18:00", "days": ["mon"], "zone": "Asia/Shanghai"}}]
(tmp/"good.json").write_text(json.dumps(d))
PY
python3 -I scripts/validate.py "$TMP/good.json" "$TMP/known.json" >/dev/null
ok "time object accepted"

# 31. 正例：pause 规则（use=<model> + pause:true）必须 PASS
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); d = json.loads((tmp/"rendered.json").read_text())
g = {x["id"]: x for x in d["groups"]}; g["g-light"]["rules"] = [{"use": "acme/lite-chat", "pause": True}]
(tmp/"good.json").write_text(json.dumps(d))
PY
python3 -I scripts/validate.py "$TMP/good.json" "$TMP/known.json" >/dev/null
ok "pause rule (use + pause:true) accepted"

# 32. 仓库密钥扫描（全量逐字节、多编码，无文件豁免）
#     扫描范围 = **会被发布出去的文件**（git 已跟踪的 + 未跟踪但没被忽略的）。
#     gitignore 的目录（tasks/、docs/superpowers/）是本机笔记，不进仓库、不发布——
#     把它们算进来会让这条验收命令在作者自己的机器上直接红（笔记里常要引用凭据形态做例子）。
#     注意这是**范围**的界定，不是**文件**的豁免：范围内每个文件都逐字节、多编码扫，没有例外。
python3 -I <<'PY'
import re, subprocess
from pathlib import Path
root = Path.cwd()
real = re.compile(
    r"sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}"
    r"|AIza[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----")
tracked = set(subprocess.run(["git", "ls-files"], capture_output=True, text=True, cwd=root).stdout.splitlines())
assert tracked, "git ls-files empty; cannot verify FAKE- placement"
# 会发布出去的文件：已跟踪的 + 未跟踪但没被 gitignore 的（`git ls-files -o --exclude-standard`）
published = set(subprocess.run(["git", "ls-files", "-co", "--exclude-standard"],
                               capture_output=True, text=True, cwd=root).stdout.splitlines())
assert published, "no publishable files found; cannot scan"
for rel in sorted(published):
    f = root / rel
    if not f.is_file():
        continue
    raw = f.read_bytes()
    cands = [raw.decode("latin-1")]
    for enc in ("utf-16-le", "utf-16-be"):
        try:
            cands.append(raw.decode(enc))
        except Exception:
            pass
    text = "\n".join(cands)
    assert not real.search(text), f"real secret pattern in {rel}"
    # 合成故障注入标记 FAKE- 只允许出现在公开的 scripts/ 与 examples/demo/；
    # 未 tracked 的本地文件不发布，不限位置，但同样接受上面的真实密钥扫描。
    if "FAKE-" in text and rel in tracked:
        assert rel.startswith("scripts/") or rel.startswith("examples/demo/"), f"FAKE- leaked into {rel}"
print("repo secret scan clean")
PY
ok "secret scan passed"

# 33. 文档围栏与 README 链接（含 README.zh.md）
python3 -I <<'PY'
import re
from pathlib import Path
root = Path.cwd()
for md in root.rglob("*.md"):
    if ".git" in md.parts:
        continue
    open_fence = False
    for line in md.read_text().splitlines():
        if line.lstrip().startswith("```"):
            open_fence = not open_fence
    assert not open_fence, f"unbalanced fences: {md}"
for name in ("README.md", "README.zh.md"):
    readme = (root / name).read_text()
    for link in re.findall(r"\]\(([^)]+)\)", readme):
        if "://" in link or link.startswith("#"):
            continue
        assert (root / link).exists(), f"broken README link in {name}: {link}"
print("docs fences and README links ok")
PY
ok "docs fences and README links"

# 34. 正例：多模型展开不变量（demo 映射无角色重叠，故每组成员数 = 各角色槽列表长度之和；classifier=首元素；重叠去重见 #38）
python3 -I - "$TMP" <<'PY'
import json, re, sys
from pathlib import Path
tmp = Path(sys.argv[1]); root = Path.cwd()
tpl = json.loads((root/"templates/groups.template.json").read_text())
mapping = json.loads((root/"examples/demo/roles.mapped.json").read_text())
rendered = {g["id"]: g for g in json.loads((tmp/"rendered.json").read_text())["groups"]}
role_re = re.compile(r"<role:([^>]+)>(.*)")
for tg in tpl["groups"]:
    rg = rendered[tg["id"]]
    expected = 0
    for member in tg.get("members", []):
        m = role_re.fullmatch(member)
        expected += len(mapping[m.group(1)]) if m else 1
    assert len(rg["members"]) == expected, f"{tg['id']}: member count {len(rg['members'])} != {expected}"
    cls = tg.get("classifier")
    if isinstance(cls, str) and role_re.fullmatch(cls):
        assert rg["classifier"] == mapping[role_re.fullmatch(cls).group(1)][0], f"{tg['id']}: classifier != first list element"
# 具体同构断言：g-code 三模型有序链（code/general 2 个 + fast/cheap 1 个），备用与主力同档
assert rendered["g-code"]["members"] == ["acme/code-standard:high", "acme/code-backup:high", "acme/lite-chat:high"], rendered["g-code"]["members"]
assert rendered["auto"]["classifier"] == "acme/judge"
# 模板形状守卫（防退化）。docgate 对 templates/*.json 只取顶层键集合，组内改动没有任何机器闸兜底
# ——「策略已改、模板没跟上」正是这类漂移的形状。所以策略本身进断言，不只留在文档里。
tg = {g["id"]: g for g in tpl["groups"]}
# 档位词取 validate 的常量，别在这里再抄一份（抄了就会漂）
import importlib.util
_vspec = importlib.util.spec_from_file_location("v", str(root / "scripts/validate.py"))
v = importlib.util.module_from_spec(_vspec); _vspec.loader.exec_module(v)
def tier(m):
    """成员尾部档位；先剥 `#account`（`provider/model:high#acc` 是合法写法），模型名/账号里的 `@` 不参与。
    返回 None = 解析不出单一档位：裸引用（省略 :effort，schema 允许）或多级 `:low+high`。"""
    base = m.split("#", 1)[0]
    suf = base.rsplit(":", 1)[1] if ":" in base else ""
    return suf if suf in v.MEMBER_EFFORT else None
ANCHOR = "<role:code/general>:high"
MAIN_CHAIN = ["g-code", "g-heavy", "g-arch", "g-review"]   # 会话会跨这些意图互切，见 docs/patterns.md 模式 13
# g-test 是 usage（首位没有「默认成员」语义，见坑 3），但渲染后它的首位成员就是主链锚：切到测试意图时首位不换模型
ANCHORED = MAIN_CHAIN + ["g-test"]
NO_AFFINITY = {"auto", "g-compact", "g-ui"}                # 刻意为之，理由各写在该组 note 里
MIXED_TIER_OK = set()   # 刻意混档的独立池登记在此并在该组 note 写清代价（模式 3）；空集=模板现在不混档
for gid in ANCHORED:
    assert gid in tg, f"模板缺锚定组 {gid}（ANCHORED 与模板对不上）"
    ms = tg[gid]["members"]
    assert ms[0] == ANCHOR, f"{gid}: 首位不是锚 {ANCHOR}，跨意图切换会整段重建 prompt cache"
    ts = [tier(m) for m in ms]
    assert None not in ts, f"{gid}: 同档靠成员各标 :effort 保证，裸引用或多级 :low+high 都算未标，实际 {ms}"
    assert set(ts) == {tier(ANCHOR)}, f"{gid}: 同组不同档 {ts}"
    assert tg[gid].get("affinity") == "session", f"{gid}: 缺 affinity=session"
leaf = [g for g in tpl["groups"] if g.get("members") and not any(str(m).startswith("group/") for m in g["members"])]
assert {g["id"] for g in leaf} - NO_AFFINITY == set(tg) - NO_AFFINITY - {"auto"}, "叶子组集合与锚定/便宜层对不上"
for g in leaf:
    gid = g["id"]
    # `affinity: auto` 就是不设（schema 默认值），两种写法等价，都算「刻意不设」
    ok_aff = (None, "auto") if gid in NO_AFFINITY else ("session",)
    assert g.get("affinity") in ok_aff, f"{gid}: affinity 应为 {'/'.join(map(str, ok_aff))}（取舍见该组 note 与模式 13）"
    if gid not in MIXED_TIER_OK:
        ts = [tier(m) for m in g["members"]]
        assert all(t == ts[0] for t in ts), f"{gid}: 同组不同档 {ts}（要刻意混档就登记进 MIXED_TIER_OK 并在 note 写代价）"
# 产物侧同样要闸：mapping 里的 `@effort` 覆写能把渲染后的主链重新拉成混档，只查模板 token 拦不住
RANCHOR = "acme/code-standard:high"
for gid in ANCHORED:
    ms = rendered[gid]["members"]
    assert ms[0] == RANCHOR, f"产物 {gid}: 首位不是锚 {RANCHOR}，实际 {ms}"
    ts = [tier(m) for m in ms]
    assert None not in ts and set(ts) == {"high"}, f"产物 {gid}: 主链成员档位不齐 {ts}（mapping 里的 @effort 覆写会打到主链上）"
PY
ok "multi-model expansion invariant + template shape guarded (anchor, tiers, affinity)"

# 35. 反向：render.py 缺映射角色必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
del m["code/general"]
(tmp/"bad-map.json").write_text(json.dumps(m))
PY
OUT="$(python3 -I scripts/render.py templates/groups.template.json "$TMP/bad-map.json" "$TMP/bad-out.json" 2>&1)" && { echo "FAIL: unmapped role accepted"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: render crashed on unmapped role: $OUT"; exit 1; fi
ok "render rejects unmapped role (clean FAIL, no crash)"

# 36. 反向：render.py 空列表映射必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["code/general"] = []
(tmp/"bad-map.json").write_text(json.dumps(m))
PY
OUT="$(python3 -I scripts/render.py templates/groups.template.json "$TMP/bad-map.json" "$TMP/bad-out.json" 2>&1)" && { echo "FAIL: empty list accepted"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: render crashed on empty list: $OUT"; exit 1; fi
ok "render rejects empty model list (clean FAIL, no crash)"

# 37. 反向：render.py 旧的单模型字符串映射必须 FAIL（须为有序列表）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["code/general"] = "acme/code-standard"
(tmp/"bad-map.json").write_text(json.dumps(m))
PY
OUT="$(python3 -I scripts/render.py templates/groups.template.json "$TMP/bad-map.json" "$TMP/bad-out.json" 2>&1)" && { echo "FAIL: string mapping accepted"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: render crashed on string mapping: $OUT"; exit 1; fi
ok "render rejects non-list (legacy string) mapping (clean FAIL, no crash)"

# 38. 正例：角色列表重叠时组内精确去重（保序）——g-compact 的 context/long 与 fast/cheap 共享模型不产生重复成员
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["context/long"] = ["acme/lite-chat"]  # 与 fast/cheap 首元素重叠
(tmp/"overlap-map.json").write_text(json.dumps(m))
PY
python3 -I scripts/render.py templates/groups.template.json "$TMP/overlap-map.json" "$TMP/overlap-out.json" >/dev/null
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"]: x for x in json.loads((tmp/"overlap-out.json").read_text())["groups"]}
mem = g["g-compact"]["members"]
assert mem == ["acme/lite-chat:low"], mem  # context/long:low + fast/cheap:low 去重后只剩一个
for grp in g.values():
    ms = grp.get("members", [])
    assert len(ms) == len(set(ms)), f"duplicate members in {grp['id']}: {ms}"
PY
ok "overlapping role lists deduped within group (order preserved)"

# 39. 反向：mapping 列表含非字符串元素必须干净 FAIL（不崩溃，有明确诊断）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["code/general"] = [123]
(tmp/"bad-map.json").write_text(json.dumps(m))
PY
OUT="$(python3 -I scripts/render.py templates/groups.template.json "$TMP/bad-map.json" "$TMP/bad-out.json" 2>&1)" && { echo "FAIL: non-string element accepted"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: render crashed on non-string element: $OUT"; exit 1; fi
if ! grep -q "non-empty model string" <<< "$OUT"; then echo "FAIL: missing clean diagnostic: $OUT"; exit 1; fi
ok "render rejects non-string element (clean FAIL, no crash)"

# 40. 反向：mapping 元素带强度后缀必须 FAIL（render 期明确诊断，而非下游 unknown ref）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["code/general"] = ["acme/code-standard:high"]
(tmp/"bad-map.json").write_text(json.dumps(m))
PY
OUT="$(python3 -I scripts/render.py templates/groups.template.json "$TMP/bad-map.json" "$TMP/bad-out.json" 2>&1)" && { echo "FAIL: effort-suffixed mapping element accepted"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: render crashed on effort suffix: $OUT"; exit 1; fi
if ! grep -q "强度后缀" <<< "$OUT"; then echo "FAIL: missing effort-suffix diagnostic: $OUT"; exit 1; fi
ok "render rejects effort-suffixed mapping element (clear diagnostic)"

# 41. 正例：多元素 intent/judge 列表 → classifier 必须取首元素（把取元素的下标改掉就该红）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["intent/judge"] = ["acme/judge", "acme/lite-chat"]
(tmp/"multi-judge-map.json").write_text(json.dumps(m))
PY
python3 -I scripts/render.py templates/groups.template.json "$TMP/multi-judge-map.json" "$TMP/multi-judge-out.json" >/dev/null
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"]: x for x in json.loads((tmp/"multi-judge-out.json").read_text())["groups"]}
assert g["auto"]["classifier"] == "acme/judge", g["auto"]["classifier"]
PY
python3 -I scripts/validate.py "$TMP/multi-judge-out.json" "$TMP/known.json" >/dev/null
ok "multi-element judge list: classifier = first element"

# 42. 正例：真实 magpie 裸名格式 → 拼前缀 known 校验 PASS（裸名 known 必 FAIL）；含冒号裸名不被强度守卫误伤
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
bare = {"providers": [{"id": "prov", "models": ["cn:coder-a", "coder-b", "judge-x"]}], "groups": []}
mapping = {"intent/judge": ["prov/judge-x"], "reasoning/strong": ["prov/cn:coder-a"],
           "code/general": ["prov/cn:coder-a", "prov/coder-b"], "design/ui": ["prov/cn:coder-a"],
           "fast/cheap": ["prov/coder-b"], "context/long": ["prov/coder-b"]}
(tmp/"bare-map.json").write_text(json.dumps(mapping))
known = sorted({(m if "/" in m else "prov/"+m) for m in bare["providers"][0]["models"]})
(tmp/"bare-known.json").write_text(json.dumps(known))
(tmp/"bare-known-raw.json").write_text(json.dumps(sorted(bare["providers"][0]["models"])))
PY
python3 -I scripts/render.py templates/groups.template.json "$TMP/bare-map.json" "$TMP/bare-rendered.json" >/dev/null
python3 -I scripts/validate.py "$TMP/bare-rendered.json" "$TMP/bare-known.json" >/dev/null
if python3 -I scripts/validate.py "$TMP/bare-rendered.json" "$TMP/bare-known-raw.json" >/dev/null 2>&1; then echo "FAIL: bare-name known accepted (should need prefix)"; exit 1; fi
ok "real bare-name format: prefixed known PASS, raw known FAIL (colon name preserved)"

# 43. 正例：@effort 覆写生效 + #account 顺序（model:effort#account）+ classifier 剥 override 为裸模型
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"]: x for x in json.loads((tmp/"rendered.json").read_text())["groups"]}
# demo design/ui 用 @high 覆写 g-ui 槽位 :medium → 同组混强度
assert g["g-ui"]["members"][0] == "acme/vision-designer:high", g["g-ui"]["members"]
assert g["g-ui"]["members"][1] == "acme/code-standard:medium", g["g-ui"]["members"]
PY
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["code/general"] = ["acme/code-standard#acc2@max", "acme/code-backup"]
m["intent/judge"] = ["acme/judge@max"]
(tmp/"override-map.json").write_text(json.dumps(m))
PY
python3 -I scripts/render.py templates/groups.template.json "$TMP/override-map.json" "$TMP/override-out.json" >/dev/null
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"]: x for x in json.loads((tmp/"override-out.json").read_text())["groups"]}
assert g["g-test"]["members"][0] == "acme/code-standard:max#acc2", g["g-test"]["members"]  # 强度在 #account 前
assert g["auto"]["classifier"] == "acme/judge", g["auto"]["classifier"]  # classifier 剥 @max，裸模型
PY
python3 -I scripts/validate.py "$TMP/override-out.json" "$TMP/known.json" >/dev/null
ok "@effort override + #account order (model:effort#account) + classifier strips override"

# 44. 正例：@ 兼容真实模型/账号名（含 @ 不当覆写）+ 多级覆写 @low+high + 同模型两强度保留（不得按 base 去重）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["code/general"] = ["acme/gpt-4o@2024-08-06", "acme/code-standard#user@example.com", "acme/code-standard@low+high"]
(tmp/"at-map.json").write_text(json.dumps(m))
known = json.loads((tmp/"known.json").read_text()) + ["acme/gpt-4o@2024-08-06"]
(tmp/"at-known.json").write_text(json.dumps(known))
PY
python3 -I scripts/render.py templates/groups.template.json "$TMP/at-map.json" "$TMP/at-out.json" >/dev/null
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"]: x for x in json.loads((tmp/"at-out.json").read_text())["groups"]}
mem = g["g-test"]["members"]
# 含 @ 模型名不当覆写（槽位 :high）；账号含 @ 不当覆写且强度在 # 前；@low+high 多级覆写
assert mem == ["acme/gpt-4o@2024-08-06:high", "acme/code-standard:high#user@example.com", "acme/code-standard:low+high"], mem
PY
python3 -I scripts/validate.py "$TMP/at-out.json" "$TMP/at-known.json" >/dev/null
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["code/general"] = ["acme/code-standard@low", "acme/code-standard@high"]
(tmp/"two-effort-map.json").write_text(json.dumps(m))
PY
python3 -I scripts/render.py templates/groups.template.json "$TMP/two-effort-map.json" "$TMP/two-effort-out.json" >/dev/null
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"]: x for x in json.loads((tmp/"two-effort-out.json").read_text())["groups"]}
assert g["g-test"]["members"] == ["acme/code-standard:low", "acme/code-standard:high"], g["g-test"]["members"]
PY
ok "@ compat (model/account names with @) + multi-level override + same-model two efforts kept"

# 45. 反向：空模型名（@max 无 base）必须干净 FAIL（明确诊断，不崩溃）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1]); m = json.loads(Path("examples/demo/roles.mapped.json").read_text())
m["code/general"] = ["@max"]
(tmp/"bad-map.json").write_text(json.dumps(m))
PY
OUT="$(python3 -I scripts/render.py templates/groups.template.json "$TMP/bad-map.json" "$TMP/bad-out.json" 2>&1)" && { echo "FAIL: empty base accepted"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: crashed: $OUT"; exit 1; fi
if ! grep -q "模型名为空" <<< "$OUT"; then echo "FAIL: missing diagnostic: $OUT"; exit 1; fi
ok "render rejects empty model base (clean FAIL)"

# 46. doctor：对未配置路由层（groups=[]）报告并给指引，退出 0
python3 -I scripts/doctor.py "$FAKE_HOME/.config/magpie/providers.json" > "$TMP/doc-empty.txt"
grep -q "no routing layer" "$TMP/doc-empty.txt"
ok "doctor reports unconfigured routing layer"

# 47. apply dry-run：展示合并计划但不写文件
cp examples/demo/input.providers.json "$TMP/apply-target.json"
python3 -I scripts/apply.py examples/demo/output.groups.json "$TMP/apply-target.json" > "$TMP/apply-dry.txt"
grep -q "dry-run: nothing written" "$TMP/apply-dry.txt"
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
a = json.loads(Path("examples/demo/input.providers.json").read_text())
b = json.loads((tmp/"apply-target.json").read_text())
assert a == b, "dry-run modified target"
PY
ok "apply dry-run shows plan without writing"

# 48. apply --write：备份 + upsert + providers 段 deep-equal 不变 + 写后校验 PASS
python3 -I scripts/apply.py examples/demo/output.groups.json "$TMP/apply-target.json" --write > "$TMP/apply-write.txt"
grep -q "post-write validation PASS" "$TMP/apply-write.txt"
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
orig = json.loads(Path("examples/demo/input.providers.json").read_text())
new = json.loads((tmp/"apply-target.json").read_text())
assert {k: v for k, v in orig.items() if k != "groups"} == {k: v for k, v in new.items() if k != "groups"}, "providers section changed"
assert len(new["groups"]) == 9
baks = list(tmp.glob("apply-target.json.bak-*"))
assert baks, "no backup created"
# 备份必须等于【写入前】的原始内容，否则「从备份恢复」恢复出来的是合并后的配置
assert json.loads(baks[0].read_text()) == orig, "backup does not match the pre-write original"
PY
ok "apply --write backs up (content == original), upserts, keeps providers, post-validates"

# 49. apply upsert 语义：同 id 替换、新 id 追加、其余保留
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
d = json.loads((tmp/"apply-target.json").read_text())
d["groups"].append({"id": "extra", "routing": "order", "members": ["acme/lite-chat:low"]})
(tmp/"apply-target.json").write_text(json.dumps(d))
(tmp/"draft2.json").write_text(json.dumps({"groups": [
    {"id": "g-code", "routing": "order", "members": ["acme/code-standard:max"]},
    {"id": "g-new", "routing": "usage", "members": ["acme/lite-chat:low"]}]}))
PY
python3 -I scripts/apply.py "$TMP/draft2.json" "$TMP/apply-target.json" --write >/dev/null
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"]: x for x in json.loads((tmp/"apply-target.json").read_text())["groups"]}
assert g["g-code"]["members"] == ["acme/code-standard:max"], "g-code not replaced"
assert "g-new" in g and "extra" in g and "auto" in g, "upsert lost groups"
assert len(g) == 11, len(g)
PY
ok "apply upsert replaces by id, appends new, keeps others"

# 50. apply 坏草案（未知模型）必须拒绝且不写
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
(tmp/"bad-draft.json").write_text(json.dumps({"groups": [{"id": "g-bad", "routing": "order", "members": ["acme/does-not-exist:high"]}]}))
PY
if python3 -I scripts/apply.py "$TMP/bad-draft.json" "$TMP/apply-target.json" --write >/dev/null 2>&1; then echo "FAIL: bad draft accepted"; exit 1; fi
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"] for x in json.loads((tmp/"apply-target.json").read_text())["groups"]}
assert "g-bad" not in g, "bad draft was written"
PY
ok "apply rejects invalid draft without writing"

# 51. apply/doctor 输出脱敏：不含密钥，也不含 endpoint
python3 -I scripts/doctor.py "$TMP/apply-target.json" > "$TMP/doc-full.txt"
python3 -I scripts/apply.py examples/demo/output.groups.json "$TMP/apply-target.json" > "$TMP/apply-plan.txt" 2>&1
if grep -q "acme-demo-key-fictional" "$TMP/doc-full.txt" "$TMP/apply-plan.txt"; then echo "FAIL: key leaked into output"; exit 1; fi
if grep -q "api.acme.invalid" "$TMP/doc-full.txt" "$TMP/apply-plan.txt"; then echo "FAIL: endpoint leaked into output"; exit 1; fi
# 必须被抓的正例：凭据形态放进【组字段】而不是 providers——doctor 的组行/形状诊断与 validate 的
# 报错都会回显成员串与组 id：只把密钥放 providers 的断言对这条路径恒绿，必须放进步骤 2 才会被抓。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
KEY = "FAKE-" + "g9Zk" * 6                  # 明显虚构字面量（validate 的 SECRET_VALUE 认这个前缀）
HOST = "leak.example.com"                   # 三段点分域名：endpoint 形态
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [
    {"id": "g-key", "routing": "order",
     "members": [f"acme/code-standard:high#{KEY}", "acme/code-backup:high"], "note": f"see {HOST}"},
    {"id": f"g-{KEY}", "routing": "order",
     "members": ["acme/" + HOST + ":high", "acme/long-reader:high"]},
]
p = tmp / "leak-members.json"; p.write_text(json.dumps(base, ensure_ascii=False))
# 草案只替换 g-key：apply 的 diff 会回显【存量组】的成员串（存量侧不过校验），正是最危险的那条路径
draft = tmp / "leak-draft.json"
draft.write_text(json.dumps({"groups": [{"id": "g-key", "routing": "order",
                                         "members": ["acme/code-standard:high"]}]}, ensure_ascii=False))
# 重复 id 的报错走 apply 自己的 check_ids（不经 validate），也要过 shield：同侧两份同 id 才触发
dup = tmp / "leak-dup.json"
dup.write_text(json.dumps({"groups": [
    {"id": f"g-{KEY}", "routing": "order", "members": ["acme/code-backup:high"]},
    {"id": f"g-{KEY}", "routing": "order", "members": ["acme/long-reader:high"]}]}, ensure_ascii=False))
# 可校验通过的夹具：草案替换掉带 `#KEY` 的存量组 → apply 走到 diff 段。上面那份停在写前校验，
# 根本没走到 diff，diff 段的脱敏在那份上恒绿——所以两份夹具都要有。
okb = json.loads(json.dumps(base))
okb["groups"] = [{"id": "g-key", "routing": "order",
                  "members": [f"acme/code-standard:high#{KEY}", "acme/code-backup:high"]}]
pb = tmp / "leak-members-ok.json"; pb.write_text(json.dumps(okb, ensure_ascii=False))
# 每个输出面钉它【该打出】的遮蔽形态（全部实测确认，不是推测）：
#   doctor          → 三个面都走 shield：`#<account N chars>`、`<ref N chars>`、`provider/<model N chars>:档位`
#   apply 写前校验  → shield（model 段含点分域名 → `<model N chars>`）
#   apply diff 段   → 整组降级 `<text N chars>`（secretish 命中就把组内所有串降级，比 shield 粗但同源）
#   apply 重复 id   → shield（`<ref N chars>`）
faces = (("doctor", [sys.executable, "-I", "scripts/doctor.py", str(p)], ("<account", "<ref ", "<model ")),
         ("apply-invalid", [sys.executable, "-I", "scripts/apply.py", str(draft), str(p)], ("<model ",)),
         ("apply-diff", [sys.executable, "-I", "scripts/apply.py", str(draft), str(pb)], ("<text ",)),
         ("apply-dup", [sys.executable, "-I", "scripts/apply.py", str(dup), str(p)], ("<ref ",)))
for label, cmd, marks in faces:
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = r.stdout + r.stderr
    for shape, token in (("key", KEY), ("endpoint host", HOST)):
        hits = [l for l in out.splitlines() if token in l]
        assert not hits, f"{label} 回显了 {shape} 形态：{len(hits)} 行\n" + "\n".join(hits)[:400]
    for m in marks:
        assert m in out, f"{label} 缺遮蔽痕迹 {m!r}（那条路径没挡，或夹具没落到那条路径上）：\n{out[:400]}"
assert KEY in p.read_text(), "夹具本身没落盘密钥形态 → 上面全是假绿"
PY

# （口径先说清：51b/51d 的 apply 面只覆盖「apply 原样转发 validate 的输出」——那两份夹具的合并结果
#   非法，apply 停在写前校验，它自己的 group_diff/brief/refs/diff_pair 一行都不走。apply 自己的 diff
#   面在下面第 72 条，那份夹具刻意让合并结果合法，才真的走得到渲染那一刻。）
# 51b. validate 的报错文本里**每一个**用户可控串都要过 shield。容易漏的正是这些边角：`weights` 键、
#      未知字段名、`pick`、未知组引用、嵌套环、classifier——doctor 与 apply 会把 validate 的输出
#      原样打进 stdout，漏一处就等于漏到使用者的终端里。夹具必须把每条消息都触发一次。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
KEY2 = "FAKE-" + "zQ7m" * 5
HOST2 = "corp-gw.example.invalid"          # 三段点分域名
DOM2 = "ops@acme.example.com"              # 账号段是域名形态（不在 SECRET_VALUE 里，属 endpoint 形态）
URL2 = "https://gw.invalid/x"              # scheme 形态（http(s)://）也要有正例，否则这一支从没被走过
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [
    {"id": "g-a", "routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"],
     "rules": [{"use": "acme/nope:high"}, {"more": ["group/" + DOM2]}],
     "weights": {KEY2: 5, URL2: 3}, KEY2: True, "uri": URL2},
    # 让 classifier 用的模型同时是别组的路由成员，`is a classifier model` 那条守卫才会触发
    # （它的报错同时回显组 id 与模型引用，正是需要过 shield 的两个插值）
    {"id": "g-" + HOST2, "routing": "order",
     "members": ["acme/code-standard:high", "group/missing-x", "acme/judge:low"]},
    {"id": "g-cyc", "routing": "order", "members": ["group/g-cyc", "acme/code-standard:high"]},
    {"id": "g-pick", "routing": "manual", "pick": "acme/" + KEY2 + ":high", "members": ["acme/code-standard:high"]},
    {"id": "g-cls", "routing": "order", "classifier": "acme/judge:low",
     "members": ["acme/code-standard:high", "acme/code-backup:high"]},
    {"id": "g-cls2", "routing": "order", "classifier": "acme/" + KEY2,
     "members": ["acme/code-standard:high", "acme/code-backup:high"]},
]
p = tmp / "leak-msgs.json"; p.write_text(json.dumps(base, ensure_ascii=False))
draft = tmp / "leak-msgs-draft.json"
draft.write_text(json.dumps({"groups": [{"id": "g-a", "routing": "order",
                                         "members": ["acme/code-standard:high", "acme/code-backup:high"]}]}))
known = sorted({(m if "/" in m else f"{pr['id']}/{m}")
                for pr in base["providers"] for m in (pr.get("models") or [])})
kp = tmp / "leak-known.json"; kp.write_text(json.dumps(known))
for label, cmd in (("validate", ["scripts/validate.py", str(p), str(kp)]),
                   ("doctor", ["scripts/doctor.py", str(p)]),
                   ("apply", ["scripts/apply.py", str(draft), str(p)])):
    r = subprocess.run([sys.executable, "-I"] + cmd, capture_output=True, text=True)
    out = r.stdout + r.stderr
    for shape, token in (("key", KEY2), ("endpoint host", HOST2), ("account domain", DOM2), ("url", URL2)):
        hits = [l for l in out.splitlines() if token in l]
        assert not hits, f"{label} 回显了 {shape} 形态：{len(hits)} 行\n" + "\n".join(hits)[:500]
    assert "<ref " in out or "<model " in out, f"{label} 没有遮蔽痕迹（夹具没触发那些消息？）：\n{out[:400]}"
# 夹具必须真的触发了那几条消息（否则上面全是「没触发所以没泄漏」的假绿）
r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(p), str(kp)], capture_output=True, text=True)
msgs = r.stdout + r.stderr
for needle in ("weights key '", "unknown field '", "pick: '", "references unknown group '",
               "nesting cycle", "classifier model", "is not a member of group '"):
    assert needle in msgs, f"夹具没触发 {needle!r} 那条消息 → 上面的脱敏断言是空跑:\n{msgs[:500]}"
PY

# 51c. 前缀名单追不上真实凭据：**无已知前缀的高熵串**也必须被掩。三条面各钉一次
#      （doctor 组行、doctor 降级路径、apply 的 diff 段）——三条各有各的漏法：
#      组行的 `first=…#<token>`、降级路径若按「是 identifier 就放行」、diff 段若把 echo 白名单当成「可原样打」。
python3 -I - "$TMP" <<'PY'
import json, shutil, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
NO_PREFIX = "noPrefixToken" + "Zx9Q" * 3      # 明显虚构：**无已知前缀**的高熵串（sk-/ghp_/AKIA 都不匹配）
FAKE_ID = "FAKE_" + "Zx9Q" * 5               # 明显虚构：identifier 形态的组 id（降级路径曾整串放行）
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [
    {"id": "g-acct", "routing": "order",
     "members": ["acme/code-standard:high#" + NO_PREFIX, "acme/code-backup:high"]},
    {"id": FAKE_ID, "routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"]},
]
p = tmp / "ent.json"; p.write_text(json.dumps(base, ensure_ascii=False))
draft = tmp / "ent-draft.json"
draft.write_text(json.dumps({"groups": [{"id": "g-acct", "routing": "order",
                                         "members": ["acme/code-standard:high", "acme/code-backup:high"]}]}))
iso = tmp / "iso"; iso.mkdir(exist_ok=True)
shutil.copy("scripts/doctor.py", iso / "doctor.py")   # 旁边没有 validate.py → 走降级路径
for label, cmd in (("doctor", [sys.executable, "-I", "scripts/doctor.py", str(p)]),
                   ("doctor-degraded", [sys.executable, "-I", str(iso / "doctor.py"), str(p)]),
                   ("apply-diff", [sys.executable, "-I", "scripts/apply.py", str(draft), str(p)])):
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = r.stdout + r.stderr
    for token in (NO_PREFIX, FAKE_ID):
        hits = [l for l in out.splitlines() if token in l]
        assert not hits, f"{label} 回显了高熵串形态：{len(hits)} 行\n" + "\n".join(hits)[:400]
    assert "<account" in out or "<ref " in out, f"{label} 没有遮蔽痕迹（夹具没落到那条路径上）：\n{out[:300]}"
# 三条路径都必须真的走到（否则又是「没触发所以没泄漏」）
d1 = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(p)], capture_output=True, text=True).stdout
assert "first=acme/code-standard:high#<account" in d1, f"doctor 组行的账号遮蔽没被触发:\n{d1[:300]}"
deg = subprocess.run([sys.executable, "-I", str(iso / "doctor.py"), str(p)], capture_output=True, text=True).stdout
assert "first=<ref " in deg and "were NOT RUN" in deg, f"那条 doctor 其实没降级或没掩 first=:\n{deg[:300]}"
PY

# 51d. 报错文本的**路径段**也要过闸：`check_value` 把 dict 的键拼进 path，而键同样是使用者写的串
#      （`weights` 的键本来就是模型引用，野字段键可能是任何东西）。这一族消息（`: secret-like value`）
#      此前没有任何夹具含过——51b 的 weights 值全是整数，check_value 只看字符串值，整条路径没被走到。
#      顺带把 render.py 这个第四输出面钉住：mapping 的键与元素原先是 `{x!r}` 原样回显。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
HOST = "gw" + ".corp" + ".example" + ".invalid"      # 虚构：三段点分域名（endpoint 形态）
SEC = "FAKE-" + "zQ7m" * 4                            # 明显虚构：secret-like 字符串值
DOMP = "build" + ".host" + ".example"                 # 虚构：落在 **provider 段** 的域名形态
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [
    {"id": "g-p", "routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"],
     "weights": {HOST: SEC},                          # 键 = endpoint 形态、值 = 凭据形态 → path 段回显
     DOMP: SEC},                                      # 野字段键同样进 path
    {"id": "g-q", "routing": "order", "classifier": f"{DOMP}/judge",
     "members": ["acme/code-standard:high", "acme/code-backup:high"]},
]
p = tmp / "pathleak.json"; p.write_text(json.dumps(base, ensure_ascii=False))
draft = tmp / "pathleak-draft.json"
draft.write_text(json.dumps({"groups": [{"id": "g-z", "routing": "order",
                                         "members": ["acme/code-standard:high", "acme/code-backup:high"]}]}))
known = tmp / "pathleak-known.json"
known.write_text(json.dumps(sorted({(m if "/" in m else f"{pr['id']}/{m}")
                                    for pr in base["providers"] for m in (pr.get("models") or [])})))
for label, cmd in (("validate", ["scripts/validate.py", str(p), str(known)]),
                   ("doctor", ["scripts/doctor.py", str(p)]),
                   ("apply", ["scripts/apply.py", str(draft), str(p)])):
    r = subprocess.run([sys.executable, "-I"] + cmd, capture_output=True, text=True)
    out = r.stdout + r.stderr
    for shape, token in (("endpoint host", HOST), ("dotted provider", DOMP)):
        hits = [l for l in out.splitlines() if token in l]
        assert not hits, f"{label} 回显了 {shape} 形态：{len(hits)} 行\n" + "\n".join(hits)[:400]
    assert "<ref " in out, f"{label} 没有遮蔽痕迹（那条 path 消息没被触发）：\n{out[:300]}"
# 反空跑：`check_value` 那一族必须真的报出来（否则上面全是「没触发所以没泄漏」）
r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(p), str(known)],
                   capture_output=True, text=True)
msgs = r.stdout + r.stderr
assert msgs.count(": secret-like value") >= 2, f"夹具没触发 path 段的 secret-like 消息（\n{msgs[:400]}"
# render 面：mapping 的键与元素都不得原样回显
mp = tmp / "pathleak-map.json"
mp.write_text(json.dumps({HOST: [f"{DOMP}/code:high"]}))
r = subprocess.run([sys.executable, "-I", "scripts/render.py", "templates/groups.template.json", str(mp)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode != 0, "render 没有拒绝带强度后缀的元素（夹具没走到那条报错）"
for token in (HOST, DOMP):
    hits = [l for l in out.splitlines() if token in l]
    assert not hits, "render 回显了 endpoint 形态：" + "\n".join(hits)[:300]
assert "<ref " in out, f"render 的报错没有遮蔽痕迹（原样回显？）：\n{out[:300]}"
PY

# 51e. 「先掩后比」的谎报：apply 的 diff 是使用者批准写入的**唯一证据物**。成员只差 `#账号`（换通道）
#      时两侧掩完一模一样 —— 报成 `order changed` 等于把真实改动说成没改。
#      同时钉住 brief() 的 echo 分支：`pick` 这类标量字段此前没有任何夹具走到（整组命中 secretish 时
#      走的是 `<text N chars>` 那条分支，所以这条面要单独钉住。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
A = "acme/code-standard:high" + "#acctTok" + "A1" * 5      # 明显虚构：两条只差账号段的成员串
Bd = "acme/code-standard:high" + "#acctTok" + "B2" * 5
LONG = "acme/" + "somelongmodelnamexyz" + ":high"           # 长单段模型名（骨架必须留下）
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [{"id": "g-m", "routing": "order", "members": [A, "acme/code-backup:high"], "pick": A}]
cur = tmp / "maskdiff-cur.json"; cur.write_text(json.dumps(base, ensure_ascii=False))
g2 = json.loads(cur.read_text())["groups"][0]
g2["members"][0] = Bd; g2["pick"] = Bd
drt = tmp / "maskdiff-draft.json"
drt.write_text(json.dumps({"groups": [g2]}, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(cur)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"apply 没跑通（夹具非法）：\n{out[:400]}"
for token in ("acctTokA1A1A1A1A1", "acctTokB2B2B2B2B2"):
    hits = [l for l in out.splitlines() if token in l]
    assert not hits, "apply 的 diff 回显了账号段原文：\n" + "\n".join(hits)[:300]
assert "order changed" not in out, f"真实成员改动被报成纯换序:\n{out[:400]}"
assert "changed only inside a masked segment" in out, f"成员侧的「改动被掩」标注丢了:\n{out[:400]}"
assert "differ only inside a masked segment" in out, f"标量字段（pick）的「改动被掩」标注丢了:\n{out[:400]}"
assert "<account " in out, f"标量行没走遮蔽（`#账号` 原样回显的前兆）：\n{out[:400]}"
# 骨架守卫：长单段模型名命中熵判据时，provider 前缀与 `:档位` 必须留下（档位是漂移判据的输入）
base["groups"] = [{"id": "g-l", "routing": "order", "members": [LONG, "acme/code-backup:high"]}]
lp = tmp / "skeleton.json"; lp.write_text(json.dumps(base, ensure_ascii=False))
known = tmp / "skeleton-known.json"
known.write_text(json.dumps(["acme/code-backup:high", "acme/code-standard:high"]))
r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(lp), str(known)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "somelongmodelnamexyz" not in out, f"长模型名原样回显:\n{out[:300]}"
assert "acme/<model 20 chars>:high" in out, f"骨架（provider 前缀 + 档位）被熵判据一起吃掉:\n{out[:300]}"
PY

# 51f. 三处边角：①`where` 的 `field`/`op` 看着像枚举，但 validate 从不校验取值、存量侧也不过校验
#      → 只放过白名单里的值（`tokens`/`contains`…），不认识的按自由文本掩；②`rules[].more` 换向被掩后
#      两侧一模一样，也要标「差别在被掩那段」；③`#账号` 不能被 model 段的熵连坐（档位与短账号标签
#      都不是凭据）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
UNKNOWN_F = "codename" + "-project" + "-helios"
UNKNOWN_O = "is" + "-not-ci"
base = json.loads(Path("examples/demo/input.providers.json").read_text())
mk = lambda f, o: [{"id": "w", "routing": "order",
                    "members": ["acme/code-standard:high", "acme/code-backup:high"],
                    "rules": [{"use": "acme/code-standard:high",
                               "where": [{"field": f, "op": o, "value": "x"}]}]}]
cur = tmp / "where-cur.json"; cur.write_text(json.dumps({**base, "groups": mk(UNKNOWN_F, UNKNOWN_O)}, ensure_ascii=False))
g2 = json.loads(cur.read_text())["groups"][0]
g2["rules"][0]["where"][0]["field"] = "tokens"; g2["rules"][0]["where"][0]["op"] = "contains"
drt = tmp / "where-drt.json"; drt.write_text(json.dumps({"groups": [g2]}, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(cur)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"apply 没跑通（夹具非法）：\n{out[:400]}"
for tok in (UNKNOWN_F, UNKNOWN_O):
    hits = [l for l in out.splitlines() if tok in l]
    assert not hits, "apply 把未登记的 where field/op 原样回显：\n" + "\n".join(hits)[:300]
wline = [l for l in out.splitlines() if "where:" in l]
assert wline and "tokens" in wline[0] and "contains" in wline[0], \
    f"白名单里的 field/op 被过度掩掉（diff 读不出来了）：\n{(wline or [''])[0][:200]}"
assert "<text " in wline[0], f"未登记的 field/op 没按自由文本给形态：\n{wline[0][:200]}"
# ② `more` 换向：两条成员串只差 `#账号`（换通道），掩完两侧一模一样 → 必须当场标注。
#    存量侧这次**真的带 more**（旧夹具的存量侧没有 more，打的是 `(unset) → …`，折叠路径从没走到），
#    两侧账号段刻意等长，所以掩完必然同形 → 标注断言是无条件的。
#    不写成 `if 两侧相等: assert 有标注`：比较条件一坏（旧写法把 `rules[0].more: ` 前缀只算在左侧，
#    于是永不成立）整条断言就变成空跑，摘掉实现侧的标注照样全绿。
OLD_A = "acctOld" + "0ld" * 4
NEW_A = "acctNew" + "ew1" * 4
assert len(OLD_A) == len(NEW_A)
g3 = json.loads(cur.read_text())["groups"][0]
g3["rules"] = [{"use": "acme/code-standard:high", "more": ["acme/code-backup:high#" + OLD_A]}]
c3 = tmp / "more-cur.json"; c3.write_text(json.dumps({**base, "groups": [g3]}, ensure_ascii=False))
g4 = json.loads(c3.read_text())["groups"][0]
g4["rules"][0]["more"] = ["acme/code-backup:high#" + NEW_A]
d3 = tmp / "more-drt.json"; d3.write_text(json.dumps({"groups": [g4]}, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d3), str(c3)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"apply 没跑通（夹具非法）：\n{out[:400]}"
mline = [l for l in out.splitlines() if ".more:" in l]
assert mline, f"夹具没打出 more 的改向：\n{out[:300]}"
for tok in (OLD_A, NEW_A):
    assert tok not in out, "more 行回显了账号段原文"
body = mline[0].split(": ", 1)[1]
i = body.index(" → ")
assert body[:i] == body[i + 3:].split(" (")[0], f"两侧掩后并没同形，标注断言会空跑：\n{mline[0][:200]}"
assert "differ only inside a masked segment" in mline[0], f"more 两侧一模一样却没标注：\n{mline[0][:200]}"
# 反向：掩后**确实不同**的改向不许打这个标注（标注满天飞，读者就会无视所有标注）
g5 = json.loads(c3.read_text())["groups"][0]; g5["rules"][0]["more"] = ["acme/code-standard:high"]
d5 = tmp / "more-vis.json"; d5.write_text(json.dumps({"groups": [g5]}, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d5), str(c3)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"反向夹具非法：\n{out[:400]}"
vline = [l for l in out.splitlines() if ".more:" in l]
assert vline and " → " in vline[0] and "masked segment" not in vline[0], \
    f"掩后不同的 more 改向也被打上「被掩」标注：\n{(vline or [''])[0][:200]}"
# ③ 长 model 段命中熵判据时，`:档位` 与 `#短账号` 都不该被连坐吞掉
LONG = "acme/" + "verylongmodelnamexxxxxxxx" + ":high#ops"
base2 = json.loads(Path("examples/demo/input.providers.json").read_text())
base2["groups"] = [{"id": "g-l3", "routing": "order", "members": [LONG, "acme/code-backup:high"]}]
lp = tmp / "acctstrip.json"; lp.write_text(json.dumps(base2, ensure_ascii=False))
kn = tmp / "acctstrip-known.json"; kn.write_text(json.dumps(["acme/code-backup:high"]))
r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(lp), str(kn)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert "verylongmodelnamexxxxxxxx" not in out, f"长模型名原样回显：\n{out[:300]}"
assert "acme/<model 25 chars>:high#ops" in out, f"档位或账号标签被 model 段的熵连坐吞掉：\n{out[:300]}"
# ④ 掩后同形的配对必须按**多重集**认，不能按位置：换序写法在位置配对下一对都对不上，
#    标注整条丢失，打出来的 `-A -B +B +A` 读起来像「把两条一样的串挪了个位置」，
#    而真实改动是两条都换了通道。三种形状一起钉：换序+同形 / 只改一条 / 纯换序（不许谎称被掩）。
ACCT = lambda s: s + "zX" * 6
mA, mB = "acme/code-standard:high", "acme/code-backup:high"
mc = [{"id": "hid", "routing": "order", "members": [f"{mA}#{ACCT('aOld')}", f"{mB}#{ACCT('bOld')}"]}]
mp = tmp / "hid-cur.json"; mp.write_text(json.dumps({**base, "groups": mc}, ensure_ascii=False))
for label, mem, want in (("重排+同形", [f"{mB}#{ACCT('bNw1')}", f"{mA}#{ACCT('aNw1')}"], "annot"),
                         ("只改一条", [f"{mA}#{ACCT('aOld')}", f"{mB}#{ACCT('bNw1')}"], "annot"),
                         ("纯换序", [f"{mB}#{ACCT('bOld')}", f"{mA}#{ACCT('aOld')}"], "order")):
    dp = tmp / f"hid-{len(label)}.json"
    dp.write_text(json.dumps({"groups": [{"id": "hid", "routing": "order", "members": mem}]}, ensure_ascii=False))
    r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(dp), str(mp)], capture_output=True, text=True)
    o = r.stdout + r.stderr
    mline2 = [l for l in o.splitlines() if l.strip().startswith("members:")]
    assert mline2, f"{label}：没打出 members 的改动：\n{o[:300]}"
    if want == "annot":
        assert "changed only inside a masked segment" in mline2[0], f"{label}：折叠没标注：\n{mline2[0][:200]}"
    else:
        assert "order changed" in mline2[0] and "masked segment" not in mline2[0], \
            f"{label}：纯换序被谎称成「差别在被掩那段」：\n{mline2[0][:200]}"
PY
ok "apply/doctor output contains no secrets or endpoints (incl. credential-shaped group fields)"

# 52. 合并结果非法（跨组 classifier 冲突：存量组成员 == 草案 classifier）必须【写前】拒绝
#     只校验草案孤岛会漏判此例（红线：classifier 绝不进任何路由成员）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [{"id": "g-legacy", "routing": "order", "members": ["acme/judge:low"]}]
(tmp/"cross-target.json").write_text(json.dumps(base))
(tmp/"cross-draft.json").write_text(json.dumps({"groups": [
    {"id": "auto", "routing": "order", "classifier": "acme/judge", "members": ["acme/code-standard:high"]}]}))
PY
if python3 -I scripts/apply.py "$TMP/cross-draft.json" "$TMP/cross-target.json" --write > "$TMP/cross.txt" 2>&1; then
  echo "FAIL: cross-group classifier conflict was written"; exit 1
fi
grep -q "nothing merged" "$TMP/cross.txt" || { echo "FAIL: merged conflict was not refused before writing"; exit 1; }
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
g = {x["id"] for x in json.loads((tmp/"cross-target.json").read_text())["groups"]}
assert g == {"g-legacy"}, f"target was modified: {g}"
assert not list(tmp.glob("cross-target.json.bak-*")), "wrote a backup although nothing was merged"
PY
ok "apply refuses an invalid MERGED result before writing (cross-group classifier)"

# 53. 草案引用【已存在】的组：合并后合法，不得误拒（孤岛校验的假阳性回归）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [{"id": "g-sub", "routing": "order", "members": ["acme/code-standard:high"]}]
(tmp/"ref-target.json").write_text(json.dumps(base))
(tmp/"ref-draft.json").write_text(json.dumps({"groups": [
    {"id": "auto", "routing": "order", "classifier": "acme/judge", "members": ["group/g-sub"]}]}))
PY
python3 -I scripts/apply.py "$TMP/ref-draft.json" "$TMP/ref-target.json" --write > "$TMP/ref.txt"
grep -q "post-write validation PASS" "$TMP/ref.txt"
ok "apply accepts a draft referencing an existing group (no island false-positive)"

# 54. 存量 groups 含非 dict 项：干净 FAIL，不 traceback
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [42, {"id": "g-old", "routing": "order", "members": ["acme/lite-chat:low"]}]
(tmp/"malformed.json").write_text(json.dumps(base))
PY
OUT="$(python3 -I scripts/apply.py "$TMP/ref-draft.json" "$TMP/malformed.json" 2>&1)" && { echo "FAIL: malformed existing groups accepted"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: apply crashed: $OUT"; exit 1; fi
grep -q "must be an object" <<< "$OUT"
ok "apply rejects non-object existing groups cleanly"

# 55. doctor 对畸形配置（providers 非对象列表 / groups 非 list）干净 FAIL，不谎报「未配置」
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
base = json.loads(Path("examples/demo/input.providers.json").read_text())
for name, patch in (("bad-providers", {"providers": {"id": "acme"}}),
                    ("bad-groups", {"groups": {"id": "x"}})):
    d = dict(base); d.update(patch)
    (tmp/f"{name}.json").write_text(json.dumps(d))
PY
for f in bad-providers bad-groups; do
  OUT="$(python3 -I scripts/doctor.py "$TMP/$f.json" 2>&1)" && { echo "FAIL: doctor accepted $f"; exit 1; }
  if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: doctor crashed on $f: $OUT"; exit 1; fi
  if grep -q "no routing layer" <<< "$OUT"; then echo "FAIL: doctor masked corruption in $f"; exit 1; fi
  grep -q "FAIL" <<< "$OUT"
done
ok "doctor reports malformed providers/groups cleanly (no crash, no false 'unconfigured')"

# 56. 备份保留原文件权限（0600 密钥文件不得放大成 0644）；同秒重跑不覆盖上一份备份
python3 -I - "$TMP" <<'PY'
import json, os, shutil, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tgt = tmp/"perm.json"
shutil.copyfile("examples/demo/input.providers.json", tgt)
os.chmod(tgt, 0o600)
original = tgt.read_text()
for _ in range(2):
    subprocess.run([sys.executable, "-I", "scripts/apply.py", "examples/demo/output.groups.json",
                    str(tgt), "--write"], check=True, capture_output=True, text=True)
baks = sorted(tmp.glob("perm.json.bak-*"))
assert len(baks) == 2, f"same-second runs overwrote a backup: {[b.name for b in baks]}"
for b in baks:
    assert (b.stat().st_mode & 0o777) == 0o600, f"backup mode widened: {oct(b.stat().st_mode & 0o777)}"
assert baks[0].read_text() == original, "first backup is not the pre-write original"
PY
ok "apply backups keep 0600 mode and never overwrite (same-second runs)"

# 57. 写后守卫探针（自变异，只在临时副本里改坏；先确认注入生效再断言守卫）：
#     落盘 JSON 损坏 / providers 被篡改 / groups 被写坏 → 写后读回校验必须 FAIL 并自动恢复
python3 -I - "$TMP" <<'PY'
import json, shutil, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
# 缩进是承重的：那行现在包在 `try:` 里（写盘失败要干净退出），变异体必须同缩进，
# 否则注入会把副本改成语法错——红在无关处，等于没测（下面那句 assert 就是防这个的）
# 锚点是**喂给落盘的那段文本**而不是 write 调用本身：写盘已改成「临时文件写完再 replace」，
# 变异要改的是内容——注入在文本上，两种落盘写法下含义完全相同，探针不会随写法漂移。
WRITE = '        text = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\\n"'
MUT = {
  "corrupt-json": '        text = "{ this is not json"',
  "providers-tampered": '        bad = dict(result); bad["providers"] = [{"id": "evil"}]\n'
                        '        text = json.dumps(bad, ensure_ascii=False, indent=2) + "\\n"',
  "groups-corrupted": '        bad = json.loads(json.dumps(result))\n'
                      '        bad["groups"][0]["members"] = ["acme/ghost-model"]\n'
                      '        text = json.dumps(bad, ensure_ascii=False, indent=2) + "\\n"',
}
src = Path("scripts/apply.py").read_text()
assert WRITE in src, "write-line anchor missing; mutation would not take effect"
for name, mut in MUT.items():
    work = tmp/f"mut-{name}"
    shutil.copytree("scripts", work/"scripts")
    (work/"scripts/apply.py").write_text(src.replace(WRITE, mut))
    tgt = work/"providers.json"
    shutil.copyfile("examples/demo/input.providers.json", tgt)
    original = tgt.read_text()
    p = subprocess.run([sys.executable, "-I", str(work/"scripts/apply.py"),
                        "examples/demo/output.groups.json", str(tgt), "--write"],
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    assert p.returncode != 0, f"{name}: corrupted write went undetected\n{out}"
    assert "restored the original config" in out, f"{name}: did not restore\n{out}"
    assert tgt.read_text() == original, f"{name}: target not restored to original"
    assert "post-write validation PASS" not in out, f"{name}: claimed success"
    # 对照：未改坏的原版同一输入必须成功
    tgt2 = work/"control.json"
    shutil.copyfile("examples/demo/input.providers.json", tgt2)
    c = subprocess.run([sys.executable, "-I", "scripts/apply.py", "examples/demo/output.groups.json",
                        str(tgt2), "--write"], capture_output=True, text=True)
    assert c.returncode == 0, f"control run failed: {c.stdout}{c.stderr}"
PY
ok "post-write on-disk guard catches corrupted writes and auto-restores (mutation probe)"

# 58. 空值容忍：magpie 自建/被移除组的 members 为 null（实测），rules 常整个键省略；
#     另外手写 rules:null 也要干净报错而非崩溃（本机实测 len(None) 曾让 doctor traceback）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [{"id": "auto-legacy", "routing": "order", "members": None, "rules": None},
                  {"id": "auto-nokey", "routing": "order", "members": None}]
(tmp/"null-members.json").write_text(json.dumps(base))
PY
OUT="$(python3 -I scripts/doctor.py "$TMP/null-members.json" 2>&1)"
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: doctor crashed on null members: $OUT"; exit 1; fi
grep -q "members=0" <<< "$OUT"
grep -q "needs members or match" <<< "$OUT"
grep -q "rules: must be list" <<< "$OUT"
grep -q 'do not use `doctor.py && ...` as a gate' <<< "$OUT"
OUT="$(python3 -I scripts/apply.py "$TMP/ref-draft.json" "$TMP/null-members.json" 2>&1)" && { echo "FAIL: null-members group passed validation"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: apply crashed on null members: $OUT"; exit 1; fi
grep -q "nothing merged" <<< "$OUT"
ok "doctor/apply tolerate real magpie null members/rules (no crash, honest findings)"

# 59. 组级真键名（实测反转）：weights/unlists/match 放行；CLI 旗标名 weight/listed 明确拒绝
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
known = tmp/"k59.json"
known.write_text(json.dumps(["acme/lite-chat", "acme/code-standard", "acme/judge"]))
def run(groups):
    gp = tmp/"g59.json"; gp.write_text(json.dumps({"groups": groups}))
    p = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(gp), str(known)],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr
base = {"id": "x", "members": ["acme/lite-chat", "acme/code-standard"]}
# 正例：magpie 真实落盘形态
good = [
    ("weights+unlists+fast+pick+family", {**base, "routing": "weight",
     "weights": {"acme/code-standard": 7}, "unlists": True, "fast": ["acme/lite-chat"],
     "pick": "acme/lite-chat", "family": "fam"}),
    ("pattern-only (members:null + match)", {"id": "p", "members": None, "match": ["acme/*"]}),
    ("named + match", {**base, "match": ["re:acme/.*"]}),
    ("weights key with :effort", {"id": "p", "members": ["acme/code-standard:high"],
     "weights": {"acme/code-standard:high": 4}}),
    # 模式组：weights/fast/pick 可引用【模式展开出来的】模型（magpie 接受，实测）——不得误拒
    ("pattern group + weights/fast/pick on expanded model",
     {"id": "p", "members": None, "match": ["acme/*"], "weights": {"acme/code-standard": 5},
      "fast": ["acme/code-standard"], "pick": "acme/code-standard"}),
    # hidden 墓碑：magpie `group rm` 自动发现组后有意保留的状态（实测），不是坏配置
    ("hidden tombstone", {"id": "auto-lite-chat", "name": "", "members": None, "hidden": True}),
    # subagent 条件天然无 value（magpie 落盘形态，实测）
    ("where subagent without value",
     {"id": "p", "members": ["acme/lite-chat"],
      "rules": [{"use": "acme/lite-chat", "tokens": 1,
                 "where": [{"field": "subagent", "op": "is"}]}]}),
]
for label, g in good:
    rc, out = run([g])
    assert rc == 0, f"valid shape rejected ({label}): {out}"
# 反例：已实测无效/危险
bad = [
    ("weight 单数键", {**base, "weight": {"acme/lite-chat": 5}}, "CLI flag"),
    ("listed 键", {**base, "listed": False}, "CLI flag"),
    ("模式写进 members", {"id": "p", "members": ["acme/*"]}, "belongs in 'match'"),
    ("members 与 match 皆空", {"id": "p", "members": [], "match": []}, "needs members or match"),
    ("weights 非成员键", {**base, "weights": {"acme/judge": 5}}, "not a member"),
    ("weights 值 1001", {**base, "weights": {"acme/lite-chat": 1001}}, "1..1000"),
    ("weights 值 bool", {**base, "weights": {"acme/lite-chat": True}}, "1..1000"),
    ("fast 给字符串", {**base, "fast": "acme/lite-chat"}, "list of model ref"),
    ("unlists 给字符串", {**base, "unlists": "no"}, "must be bool"),
    ("pick 给数组", {**base, "pick": ["acme/lite-chat"]}, "single model ref"),
    ("match 给字符串", {"id": "p", "match": "acme/*"}, "list of non-empty pattern"),
    ("fast 非成员", {**base, "fast": ["acme/judge"]}, "not a member"),
    ("ultra 非成员", {**base, "ultra": ["acme/judge"]}, "not a member"),
    ("pick 非成员", {**base, "pick": "acme/judge"}, "not a member"),
    ("fast 裸引用而成员带 :effort",
     {"id": "p", "members": ["acme/code-standard:high"], "fast": ["acme/code-standard"]}, "not a member"),
]
for label, g, needle in bad:
    rc, out = run([g])
    assert rc != 0, f"invalid shape accepted ({label})"
    assert needle in out, f"missing diagnostic for {label}: {out}"
PY
ok "group real key names: weights/unlists/match accepted, CLI weight/listed rejected"

# 60. 角色启发式结构化：signals 可机械执行，且与 demo 映射自洽
python3 -I - <<'PY'
import json
from pathlib import Path
roles_doc = json.loads(Path("templates/roles.json").read_text())
roles, mapping = roles_doc["roles"], roles_doc["mapping"]
assert set(roles) == set(mapping), "mapping keys must match roles"
for key in ("how_to_use_signals", "capability_is_not_in_config", "order", "element",
            "classifier_separation", "user_confirms"):
    assert isinstance(roles_doc["mapping_rules"].get(key), str) and roles_doc["mapping_rules"][key], key
for name, role in roles.items():
    s = role["signals"]
    for field in ("name_contains", "name_avoid", "needs"):
        assert isinstance(s[field], list), f"{name}.{field} must be a list"
        assert all(isinstance(x, str) and x and x == x.lower() for x in s[field]), \
            f"{name}.{field} tokens must be non-empty lowercase (matching is on the lowercased model name)"
    assert isinstance(s["prefer"], str) and s["prefer"], name
assert roles["intent/judge"]["signals"].get("exclusive") is True, "classifier role must be exclusive"
assert not any(r["signals"].get("exclusive") for n, r in roles.items() if n != "intent/judge")

# 行为断言：按 roles.json 描述的【整段匹配 + 负信号否决】机械执行，结果必须站得住。
# @effort 的剥离复用 render.py 的同一套判定（支持 + 多级；模型 id 本身含 @ 不误伤）。
import importlib.util, re
spec = importlib.util.spec_from_file_location("render", "scripts/render.py")
render = importlib.util.module_from_spec(spec); spec.loader.exec_module(render)

def base_of(ref):
    return render.split_override(ref)[0].split("#")[0]

def signals(role, ref):
    """返回 (正信号命中?, 负信号命中?)；整段相等，不是子串。"""
    segs = [s for s in re.split(r"[^a-z0-9]+", base_of(ref).split("/")[-1].lower()) if s]
    s = roles[role]["signals"]
    return (any(t in segs for t in s["name_contains"]), any(t in segs for t in s["name_avoid"]))

def check_mapping(mapping):
    for name, refs in mapping.items():
        for ref in refs:
            pos, neg = signals(name, ref)
            assert pos, f"{name}: {ref} not a signal candidate"
            assert not neg, f"{name}: {ref} hits a negative signal"
    judge = {base_of(r) for r in mapping["intent/judge"]}
    for name, refs in mapping.items():
        if name != "intent/judge":
            assert not judge & {base_of(r) for r in refs}, "classifier model reused"

demo = json.loads(Path("examples/demo/roles.mapped.json").read_text())
check_mapping(demo)
# 合法写法不得误判：多级强度 @low+minimal（minimal 含 mini）、模型 id 自带 @ 日期
check_mapping({**demo,
               "reasoning/strong": ["acme/strong-reasoner@low+minimal"],
               "intent/judge": ["acme/lite-judge@2024-08-06"],
               "fast/cheap": ["acme/lite-judge@2025-01-01"]})
# 供应商名自带 token 的碰撞：整段匹配下不得把旗舰当快模型、把快模型当强模型
for ref, role in (("acme/promini-2.5-pro", "fast/cheap"), ("acme/promini-2.5-pro", "intent/judge"),
                  ("acme/maximini-m3.1-flash", "reasoning/strong")):
    pos, neg = signals(role, ref)
    assert not pos or neg, f"{ref} wrongly ranked as {role} candidate"
assert signals("reasoning/strong", "acme/promini-2.5-pro") == (True, False)
assert signals("fast/cheap", "acme/maximini-m3.1-flash") == (True, False)
assert signals("reasoning/strong", "acme/mini-chat") == (False, True)
assert signals("intent/judge", "acme/pro-chat") == (False, True)
# 子串误伤：codec 不是编码模型、devops 不是开发模型
assert signals("code/general", "acme/turbo-codec") == (False, False)
assert signals("code/general", "acme/devops-agent") == (False, False)
# 真复用仍要被抓：classifier 与路由角色指向同一模型（且该模型确实命中两个角色的正信号）
try:
    check_mapping({**demo, "intent/judge": ["acme/lite-judge"], "fast/cheap": ["acme/lite-judge"]})
except AssertionError as exc:
    assert "classifier model reused" in str(exc), exc
else:
    raise AssertionError("classifier reuse was not caught")
PY
ok "role signals are machine-applicable and consistent with the demo mapping"

# 61. apply 合并计划显示【组内字段级变化】（含被删字段），且脱敏
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
models = ["judge", "judge-b", "lite-chat", "code-standard", "code-pro", "long-chat"]
target = {"providers": [{"id": "acme", "models": models, "key": "FAKE-acme-key-not-real"}],
          "groups": [
    {"id": "g-code", "members": ["acme/code-standard:high", "acme/lite-chat:low"],
     "routing": "order", "affinity": "session", "classifier": "acme/judge",
     "weights": {"acme/code-standard:high": 5},
     "rules": [{"use": "acme/code-standard:high", "intent": "impl"}]},
    {"id": "g-light", "members": ["acme/lite-chat"], "routing": "usage"},
    {"id": "g-order", "members": ["acme/lite-chat", "acme/long-chat"]},
    {"id": "g-keep", "members": ["acme/long-chat"]}]}
draft = {"groups": [
    {"id": "g-code", "members": ["acme/lite-chat:low", "acme/code-pro:high"],
     "routing": "usage", "classifier": "acme/judge-b",
     "rules": [{"use": "acme/code-pro:high", "intent": "impl"},
               {"use": "acme/code-pro:high", "intent": "refactor"}]},
    {"id": "g-light", "members": ["acme/lite-chat"], "routing": "usage"},
    {"id": "g-order", "members": ["acme/long-chat", "acme/lite-chat"]},
    {"id": "g-new", "members": ["acme/long-chat"]}]}
tp, dp = tmp/"t61.json", tmp/"d61.json"
tp.write_text(json.dumps(target)); dp.write_text(json.dumps(draft))
def run(path):
    p = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(dp), str(path)],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr
rc, out = run(tp)
assert rc == 0, out
for needle in ("members: -acme/code-standard:high +acme/code-pro:high",
               "routing: order → usage", "classifier: acme/judge → acme/judge-b",
               "rules: 1 → 2", "rules[0].use: acme/code-standard:high → acme/code-pro:high",
               "rules[1]: added (use acme/code-pro:high)",
               "affinity: session → (unset)", "weights: {1 keys} → (unset)",
               "members: order changed", "g-light: identical"):
    assert needle in out, f"merge plan missing {needle!r}:\n{out}"
assert "FAKE-acme-key-not-real" not in out, "merge plan leaked a provider key"
assert "nothing written" in out

# 畸形存量组（members 非列表 / 元素非字符串）不得崩溃，也不得把对象内容打印出来
bad = json.loads(json.dumps(target))
bad["groups"][0]["members"] = {"opaque": "opaque-member-object"}
bad["groups"][1]["members"] = [{"k": "opaque-member-object"}]
bp = tmp/"t61bad.json"; bp.write_text(json.dumps(bad))
rc, out = run(bp)
assert rc == 0, out
assert "opaque-member-object" not in out, "diff dumped a malformed member object"
assert "members: {1 keys} → [2 items]" in out and "members: -{1 keys} +acme/lite-chat" in out, out

# --write 路径同样先展示组内变化
wp = tmp/"t61write.json"; wp.write_text(json.dumps(target))
p = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(dp), str(wp), "--write"],
                   capture_output=True, text=True)
assert p.returncode == 0, p.stdout + p.stderr
assert "routing: order → usage" in p.stdout and "post-write validation PASS" in p.stdout
PY
ok "apply merge plan shows intra-group field changes (desensitized, both paths)"

# 62. 合并计划的脱敏与输入闸门：存量自由文本不回显、重复 id 拒绝、畸形输入不 traceback
python3 -I - "$TMP" <<'PY'
import importlib.util, json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("ap", "scripts/apply.py")
ap = importlib.util.module_from_spec(spec); spec.loader.exec_module(ap)
FAKE = "-".join(["FAKE", "acme", "key", "not", "real", "0123456789"])
URL = "https://FAKE-endpoint.invalid/v1"
EP = "https://gw.example.invalid/v1"  # 不含 FAKE- 前缀，才能单独验 endpoint 闸门
models = ["judge", "code-standard", "code-pro", "lite-chat"]
prov = {"providers": [{"id": "acme", "models": models, "key": FAKE}]}

def run(target, draft, write=False):
    t, d = tmp/"t62.json", tmp/"d62.json"
    t.write_text(json.dumps(target)); d.write_text(json.dumps(draft))
    cmd = [sys.executable, "-I", "scripts/apply.py", str(d), str(t)] + (["--write"] if write else [])
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr, json.loads(t.read_text())

# a) 存量组的自由文本（note/name/未知键/rule intent）可能夹带密钥或 endpoint：
#    校验的是合并结果，存量侧不过校验，故一律只给形态
old = {"id": "g-code", "members": ["acme/code-standard"], "classifier": "acme/judge",
       "note": f"rotate: {FAKE} / {URL}", "name": FAKE, "whatever": FAKE,
       "rules": [{"use": "acme/code-standard", "intent": f"impl {FAKE}"}]}
new = {"id": "g-code", "members": ["acme/code-standard"], "classifier": "acme/judge",
       "rules": [{"use": "acme/code-standard", "intent": "impl"}]}
for write in (False, True):
    rc, out, _ = run({**prov, "groups": [old]}, {"groups": [new]}, write=write)
    assert rc == 0, out
    assert FAKE not in out and URL not in out, f"free text echoed (write={write}):\n{out}"
    assert "note: <text" in out and "name: <text" in out and "whatever: <text" in out, out
    assert "rules[0].intent: <text" in out, out

# a2) 引用类字段的【存量侧】同样不过校验：members/use/where.field/classifier/组 id
#     若被塞进凭据或 endpoint，一律不得原样回显（白名单字段也要过 secretish 闸门）
# 前缀用字符码在运行时拼出来：源码里不留任何凭据形态的字面量——
# 密钥扫描按字节找**连续**形态，拼接出来的连续串它抓不到，等于扫描谎报干净。
SEC = "".join(chr(c) for c in (115, 107, 45)) + "a" * 26
for label, old_g, new_g in (
    ("members", {"members": [f"legacy {SEC}"]}, {"members": ["acme/code-standard"]}),
    ("classifier", {"members": ["acme/code-standard"], "classifier": SEC},
     {"members": ["acme/code-standard"], "classifier": "acme/judge"}),
    ("rule use", {"members": ["acme/code-standard"], "classifier": "acme/judge",
                  "rules": [{"use": SEC, "intent": "i"}]},
     {"members": ["acme/code-standard"], "classifier": "acme/judge",
      "rules": [{"use": "acme/code-standard", "intent": "i"}]}),
    ("where field", {"members": ["acme/code-standard"], "classifier": "acme/judge",
                     "rules": [{"use": "acme/code-standard", "intent": "i",
                                "where": [{"field": SEC, "op": "is"}]}]},
     {"members": ["acme/code-standard"], "classifier": "acme/judge",
      "rules": [{"use": "acme/code-standard", "intent": "i",
                 "where": [{"field": "subagent", "op": "is"}]}]}),
    ("endpoint", {"members": [EP]}, {"members": ["acme/code-standard"]}),
):
    for write in (False, True):
        rc, out, _ = run({**prov, "groups": [{"id": "g-code", **old_g}]},
                         {"groups": [{"id": "g-code", **new_g}]}, write=write)
        assert rc == 0, out
        assert SEC not in out and URL not in out and EP not in out, f"{label} leaked (write={write}):\n{out}"
# 组 id 是 endpoint 形态时 validate 不拦（SECRET_VALUE 无 URL 形态），
# 而 keep/add 列表不经 group_diff —— label() 必须挡住
rc, out, _ = run({**prov, "groups": [{"id": EP, "routing": "order", "members": ["acme/code-standard"]},
                                     {"id": "g-a", "members": ["acme/code-standard"]}]},
                 {"groups": [{"id": "g-a", "members": ["acme/code-pro"]}]})
# 遮蔽形态统一成 shield 那三种（`<ref N chars>` / `provider/<model N chars>:档位` / `#<account N chars>`）；
# apply 的 label() 不自带第二份形态表：组 id 与别处共用 shield()（brief() 的自由文本摘要是另一回事）
assert rc == 0 and EP not in out and "<ref " in out, out

# 组 id 是凭据形态时走不到 diff：validate 先拒（两侧 id 都会进合并结果）
rc, out, _ = run({**prov, "groups": [{"id": SEC, "members": ["acme/code-standard"]}]},
                 {"groups": [{"id": SEC, "members": ["acme/code-pro"]}]})
assert rc != 0 and "secret-like value" in out and SEC not in out, out

# b) 存量重复 id：upsert 会静默丢组，必须拒绝且不写盘
dup = {**prov, "groups": [{"id": "g-code", "members": ["acme/code-standard"], "note": "FIRST"},
                          {"id": "g-code", "members": ["acme/code-pro"], "note": "SECOND"},
                          {"id": "g-light", "members": ["acme/lite-chat"]}]}
rc, out, after = run(dup, {"groups": [{"id": "g-light", "members": ["acme/lite-chat"]}]}, write=True)
assert rc != 0 and "duplicates group id" in out, out
assert len(after["groups"]) == 3 and any(g.get("note") == "FIRST" for g in after["groups"]), after
# 草案侧重复 id 同样拒绝
rc, out, _ = run({**prov, "groups": []},
                 {"groups": [{"id": "g", "members": ["acme/lite-chat"]}] * 2})
assert rc != 0 and "draft groups[1] duplicates group id" in out, out

# c) 畸形 id / 非对象元素：干净 FAIL，不 traceback
for target, draft, needle in (
    ({**prov, "groups": [{"id": ["g-code"], "members": ["acme/code-standard"]}]},
     {"groups": [{"id": "g-light", "members": ["acme/lite-chat"]}]}, "non-empty string id"),
    ({**prov, "groups": []}, {"groups": ["g-code"]}, "must be an object"),
):
    rc, out, _ = run(target, draft)
    assert rc != 0 and needle in out and "Traceback" not in out, out

# d) 真实 magpie 形态不得产生假变化；真实改动不得被相等性吞掉
assert ap.group_diff({"members": None, "match": ["acme/*"]}, {"members": [], "match": ["acme/*"]}) == []
assert ap.group_diff({"rules": None}, {"rules": []}) == []
assert ap.group_diff({"weights": {"acme/a": 1}}, {"weights": {"acme/a": 1000}}) == ["weights: acme/a 1 → 1000"]
assert ap.group_diff({"levels": ["low", "high"]}, {"levels": ["low", "max"]}) == ["levels: -high +max"]
assert ap.group_diff({"disabled": 1}, {"disabled": True}) == ["disabled: 1 → True"]
assert ap.group_diff({"members": ["acme/a", "acme/a"]}, {"members": ["acme/a"]}) == [
    "members: duplicate count changed (2 → 1 entries)"]
assert ap.group_diff({"name": ""}, {}) == ["name: (empty) → (unset)"]
r1 = [{"use": "acme/code-standard", "intent": "a"}, {"use": "acme/code-pro", "intent": "b"}]
assert ap.group_diff({"rules": r1}, {"rules": list(reversed(r1))}) == ["rules: reordered"]
assert ap.group_diff({"rules": [{"use": "acme/code-standard", "intent": "i",
                                 "where": [{"field": "subagent", "op": "is"}]}]},
                     {"rules": [{"use": "acme/code-pro", "intent": "i",
                                 "where": [{"field": "tokens", "op": "gt", "value": 900000}]}]}) == [
    "rules: 1 → 1", "rules[0].use: acme/code-standard → acme/code-pro",
    "rules[0].where: [subagent is] → [tokens gt 900000]"]
PY
ok "merge plan never echoes unvalidated free text; duplicate ids and malformed input refused cleanly"

# 63. 文档 ↔ 代码 机检守卫：枚举/字段集合相等、历史错误写法、中英平行、demo 命令可跑
python3 -I - "$TMP" "$ROOT" <<'PY'
import importlib.util, os, re, shutil, subprocess, sys, time
from pathlib import Path
tmp, root = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("v", "scripts/validate.py")
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
dgspec = importlib.util.spec_from_file_location("dg", root / "scripts/docgate.py")
dg = importlib.util.module_from_spec(dgspec); dgspec.loader.exec_module(dg)
DOCS = dg.public_docs(root)          # 不写死清单：新增公开文档自动纳入（与第 64 条同口径）
schema = Path("docs/schema.md").read_text()

def section(pat):
    """按【行首整行】定位章节，返回 (文档里的实际标题, 正文)。用 str.index 会命中正文里
    更早出现的同名片段，标题被改名时抛裸 ValueError，看不出是哪一节丢了（实测）。
    数量词必须由调用方写成 \\d+：枚举扩容时标题里的数字本来就该跟着变，写死「12 种」
    会把「代码+文档同步加值」这种合法演进判成章节被改名（实测误拦正例）。"""
    m = re.search(rf"^({pat})\s*$", schema, re.M)
    assert m, f"[63a] 章节缺失或标题被改名: {pat}"
    return m.group(1), schema[m.end():]

def first_col(pat):
    """取某章节【第一张表】首列的标识符——那张才是本节的字段/枚举表。
    只取第一张表：节内后面可能有合法子表（某字段的取值表）或 CLI 旗标表，并入集合会
    误拦合法演进；靠「CLI 旗标」表头字面做分界，表头一改名就失效且报错误导（均实测）。
    数据行首列取不到标识符【直接 FAIL】：静默跳过会让这里漏计一个值、别处多计一个值
    互相抵消，集合相等就假绿（把判据改回去即可复现）。
    射程边界：本节第二张及以后的表不参与集合校验——它们声明的是别的东西（如 CLI 旗标），
    那类失真由 63b 的「旗标不得当 JSON 键名」与 64a 的命令契约负责。"""
    title, body = section(pat)
    table = []
    for line in body.splitlines()[1:]:
        if line.startswith("|"):
            table.append(line)
        elif table:
            break                                 # 第一张表结束即止
    rows = [l for l in table if not re.fullmatch(r"[\s|:\-]+", l)]
    out = []
    for row in rows[1:]:                          # rows[0] 是表头
        cell = row.split("|")[1].strip()
        toks = re.findall(r"`([A-Za-z][A-Za-z0-9_-]*)`", cell)
        assert toks, f"[63a] {title}: 表格首列没有裸标识符（期望 `字段名`）: {row[:70]}"
        out.extend(toks)
    return title, set(out)

# a) 文档枚举/字段表必须与校验器常量【集合相等】：漏写新值、写了不存在的值都抓。
# 标题里的数量词也纳入校验——集合扩到 13 个而标题仍写「12 种」同样是漂移（实测漏过）。
# 数量词取自【文档实际标题】而不是这里写死的字符串，否则那条断言校的是 e2e 自己。
for pat, const, name in (("## group 字段", v.GROUP_FIELDS, "group fields"),
                         ("## rule 字段", v.RULE_FIELDS, "rule fields"),
                         (r"## routing：\d+ 种池路由模式", v.ROUTING_MODES, "routing modes"),
                         (r"## affinity：\d+ 种会话粘性", v.AFFINITY, "affinity values")):
    title, doc = first_col(pat)
    assert doc == const, f"[63a] {name} drift: doc-only={sorted(doc - const)} code-only={sorted(const - doc)}"
    num = re.search(r"(\d+)\s*种", title)
    if num:
        assert int(num.group(1)) == len(const), \
            f"[63a] {title} 标题写 {num.group(1)} 种，实际常量 {len(const)} 个"
# effort 档位：两条独立断言。「凡 run 必须等于某集合」会误伤合法的子集表述（实测误拦），
# 只在含 minimal 时才判又会漏掉丢 minimal 的写法（实测漏过）。改为：
#  a) 任何含 ≥2 个档位词的 run 都不得含集合外的词（ultra 这类编造档位），逐项反引号写法也算
#  b) 承诺给出【完整枚举】的文件必须有一处把该集合列齐，防止被悄悄缩减或换成另一个集合
EFFORT_SETS = [v.MEMBER_EFFORT, v.USE_EFFORT, v.RULE_EFFORT]
UNION = set().union(*EFFORT_SETS)
FULL_RUN = {"docs/schema.md": [v.MEMBER_EFFORT, v.USE_EFFORT],
            "docs/patterns.md": [v.MEMBER_EFFORT, v.USE_EFFORT]}
# 断词只按 ASCII 字母数字：Python re 里汉字算 \w，`\b` 在「档位ultra/low/high」这种
# 紧贴汉字的写法上不成立——既漏判编造档位，又误拦紧贴汉字的完整枚举（实测两个方向）。
for rel in DOCS:
    text = Path(rel).read_text().replace("`", "")
    for run in re.findall(rf"(?<![A-Za-z0-9])(?:[a-z]+/){{2,}}[a-z]+(?![A-Za-z0-9])", text):
        parts = set(run.split("/"))
        if len(parts & UNION) >= 2:
            assert parts <= UNION, f"[63a] {rel}: 未知 effort 档位: {run}"
    # 完整枚举必须是【连续列举】：只按「某行含齐这些词」判，会被同句纠正语里的词凑齐
    #（「集合 none/low/…（…且缺 minimal）」那种写法会假绿）。分隔符不限 / 、 , 空格，
    # 但整段必须全是档位词，中间混进别的词就不算枚举。
    for want in FULL_RUN.get(rel, []):
        assert any(set(re.split(r"[ \t/、,，]+", run)) == set(want)
                   for run in re.findall(r"(?<![A-Za-z0-9])[a-z]+(?:[ \t/、,，]+[a-z]+)*(?![A-Za-z0-9])", text)), \
            f"[63a] {rel}: 没有任何一处完整列出档位枚举，应含 {sorted(want)}"

# b) 历史错误写法黑名单：已被实测推翻的表述不得复活。
# 射程说明：这是【枚举式防复发】，只认下列精确形态；中文数字、换句同义改写不在射程内，
# 那类语义失真仍靠收尾的全量文档对照 review。
def prose_lines(text):
    """产出 (行, 最近的 ## 级标题)，跳过 ``` 围栏内的行。
    围栏里的 `#!/bin/sh`、`# 待验证` 不是标题，`###` 子标题也不改变所属小节——
    三者都会污染 heading 判定，造成「清单内误拦 / 清单外假豁免」双向失真（实测）。"""
    heading, fence = "", False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        if line.startswith("## "):
            heading = line
        yield line, heading

# 豁免只认【明确宣告该说法作废】的判词，且判词必须与错写【在同一句】。
# 泛词（会报/不是/曾/旧版）不能单独构成豁免：「所有组的 members 必须非空，否则会报错」
# 是错写最自然的行文（实测放行）。只换词表也不够——同一长行别处的「…不成立」
# 仍会豁免行首的错写（实测回归），故按句判，不按整行判。
EXEMPT = ("是错的", "已作废", "已纠正", "已推翻", "已废弃", "不成立")
SENT = "。；;！!？?"

def clause_at(line, pos):
    """取 pos 所在的句子（按句末标点切）。逗号不算句界——纠正判词常在括号内的同一句里。"""
    left = max([line.rfind(c, 0, pos) for c in SENT])
    rights = [i for i in (line.find(c, pos) for c in SENT) if i != -1]
    return line[left + 1: min(rights) if rights else len(line)]

# (模式, 说明, 是否需要纠正语境豁免, 附加条件)
#  附加条件 "PENDING" = 待验证清单小节内不算（那里写「待核」是合法的，字段表里才是失真）；
#  附加条件为正则 = 该行还须命中它才判（与 routing 无关的「11 种意图分类」不误拦）
NONEMPTY = r"(?:非空|不能为空|不得为空)"      # 同义近变体与词序颠倒都算（实测漏过）
BANNED = [(rf"(?:所有|每个|各)组[^。\n]*(?:members[^。\n]*{NONEMPTY}|{NONEMPTY}[^。\n]*members)",
           "members-or-match rule", True, None),
          (r"11 (?:模式|种)", "routing has 12 modes", True, r"routing|池路由"),
          (r"\b11 modes\b", "routing has 12 modes", True, r"routing"),
          (r"必须[^。\n]*compact:\s*true", "compact 是压缩触发条件不是兜底", True, None),
          # 「magpie 没有 agent 接线的 CLI」曾被写进收尾验收步骤与 demo 文档，实测推翻：
          # magpie ls（列接线与落点文件）、magpie <agent> <model>（写主 model）、
          # magpie <agent> <field> default（该档回继承）都可用
          (r"无 CLI 路由接管|no CLI routing takeover", "magpie has an agent-wiring CLI", True, None),
          # 把启动器当成通用子命令写进给使用者的步骤 = 会写坏配置（实测 `magpie codex run`
          # 写出 model = "run"，因为只有 claude 有 run）。射程同样是精确形态，换句式不判。
          (r"magpie <agent> run", "run 只有 claude 有；其它 agent 的两参数形态会写主 model", True, None),
          (r"值形态待核", "value shapes already probed", False, "PENDING"),
          (r"语义仍待核", "semantics already settled", False, "PENDING")]
for rel in DOCS:
    for line, heading in prose_lines(Path(rel).read_text()):
        live = re.sub(r"~~.*?~~", "", line)     # 划掉的历史条目是明示已作废的原文
        for pat, why, contextual, needs in BANNED:
            if needs == "PENDING" and "待验证" in heading:
                continue
            if needs and needs != "PENDING" and not re.search(needs, live):
                continue
            hit = re.search(pat, live)
            if hit and contextual and any(w in clause_at(live, hit.start()) for w in EXEMPT):
                continue
            assert not hit, f"[63b] {rel}: stale claim ({why}): {line[:90]}"
# 精确命令形态不接受「纠正词豁免」：schema.md 那行【同时】含错误命令与「会报」，
# 只凭纠正词放行就会把真错误用法也放过去（实测回归）。规则：引用错误命令的【同一段】
# 必须给出正确写法。段 = 空行分隔的块——「示错围栏 + 紧随的纠正句」是正当排版，
# 按物理行判会误拦它（实测）。裸 `restore auto`（无 magpie group 前缀）同样误导，一并认。
for rel in DOCS:
    for block in re.split(r"\n\s*\n", Path(rel).read_text()):
        live = re.sub(r"~~.*?~~", "", block)
        if re.search(r"restore\s+auto\b(?!-)", live):
            assert "restore <" in live, \
                f"[63b] {rel}: `restore auto` 不是合法用法且同段未给出正确写法: {live.strip()[:90]}"

# CLI 旗标不得被当 JSON 键名陈述。`weight`/`listed` 也是 routing 模式值，`when` 也可能是英文单词，
# 故只在【JSON 键语境】里判：「组级/字段/真键名是 … `X`」这类写法必须写真键名。
# 不做整行豁免——同一行别处提到 CLI 不代表这处声明就是对的。
CLI_FLAGS = {**v.GROUP_CLI_ONLY, "when": "where", "except-folders": "exceptFolders"}
for rel in DOCS:
    for line, _ in prose_lines(Path(rel).read_text()):
        live = re.sub(r"~~.*?~~", "", line)
        for flag, real in CLI_FLAGS.items():
            # 正序「真键名是 `X`」与倒序「`X` 是 JSON 字段」两种句式都要认（实测倒序漏过）
            assert not re.search(rf"(?:组级|字段|真键名|键名|JSON 名)\s*(?:是|为|叫)?\s*(?:\*\*)?\s*`{flag}`", live), \
                f"[63b] {rel}: `{flag}` stated as a JSON key (use `{real}`): {line[:90]}"
            assert not re.search(rf"`{flag}`\s*(?:是|为|叫)\s*(?:\*\*)?\s*(?:JSON|组级|字段)", live), \
                f"[63b] {rel}: `{flag}` stated as a JSON key (use `{real}`): {line[:90]}"

# c) 中英 README 结构平行：只改一版会被抓
en, zh = Path("README.md").read_text(), Path("README.zh.md").read_text()
def shape(t):
    return (len(t.splitlines()), len(re.findall(r"^## ", t, re.M)),
            len([l for l in t.splitlines() if l.startswith("|")]),
            t.count("```"), tuple("<lang>" if l in ("README.md", "README.zh.md") else l
                                  for l in re.findall(r"\]\(([^)]+)\)", t)))
assert shape(en) == shape(zh), (f"[63c] README EN/ZH out of sync: {shape(en)} vs {shape(zh)}"
                                " — 单侧改动请同步另一版；计数相同也可能内容不平行，仍需人工对照")

# d) demo 文档里的 bash 块：可执行的整块在【TMP 内的仓库副本】里真跑，其余只做静态校验。
# 这一段的每一条限制都对应一次实测逃逸，别当多余防御删掉：
#  - 不在真仓库里跑：fence 写相对路径会污染工作区，而 64b 读 git diff 会吃到这些改动（实测）
#  - 只跑白名单命令：`cd scripts && bash e2e.sh` 会无限递归；`magpie …` 会按端口连活实例（实测）
#  - 禁止 --write：本检查的职责是命令契约，不是写入配置。绝对路径 --write 实测改写穿过沙箱
#  - HOME 指向 TMP + MAGPIE_ADDR 死端口：只设 HOME 不够，CLI 按端口连活实例
SANDBOX = tmp / "repo"
shutil.copytree(root, SANDBOX, ignore=shutil.ignore_patterns(".git", "__pycache__"))
REAL_CFG = str(Path.home() / ".config/magpie")
fences = re.findall(r"```bash\n(.*?)```", Path("examples/demo/README.md").read_text(), re.S)
assert fences, "[63d] demo README has no bash fence"
ran = 0
for idx, block in enumerate(fences):
    # 任何拼法的自调用都剔除（不只 scripts/e2e.sh）：`cd scripts && bash e2e.sh` 会无限递归
    lines = [l for l in block.splitlines() if "e2e.sh" not in l]
    code = "\n".join(re.sub(r"#.*$", "", l) for l in lines)
    # 指向真实配置的一律不执行：先归一 ${HOME}/$HOME/~ 再比对，只认字面 "~/.config" 会漏（实测）
    # expanduser 只展开【字符串开头】的 ~，命令行中间的 ~/.config 展开不到（实测漏判）。
    # 统一把 ${HOME}/$HOME/~/ 换成真实 home 再比对
    home = str(Path.home())
    norm = code.replace("${HOME}", home).replace("$HOME", home).replace("~/", home + "/")
    if re.search(r"<[^>]+>", code) or REAL_CFG in norm:
        continue
    # 白名单：只接受 `python3 -I scripts/<脚本>.py …` 与 `python3 -I -c "…"`（含多行），
    # 且不得带 --write、不得有 shell 元字符。其它命令（cd/magpie/rm/bash…）一律不执行。
    runnable, why = True, ""
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.strip()
        i += 1
        if not line or line.startswith("#"):
            continue
        if not line.startswith("python3 -I "):
            runnable, why = False, f"命令不在白名单内: {line[:60]}"
            break
        if "--write" in line:
            runnable, why = False, "带 --write 的命令不在验收里执行"
            break
        if re.search(r"&&|\||;|`|\$\(", line):
            runnable, why = False, f"含 shell 元字符: {line[:60]}"
            break
        if line.startswith("python3 -I -c "):
            # 内联脚本：吃掉到收尾引号为止的后续行；其中不得出现绝对路径字面量
            while line.count('"') % 2 == 1 and i < len(lines):
                line += "\n" + lines[i]
                i += 1
            if re.search(r"[\"']/(?:Users|home|etc|var|tmp)/", line):
                runnable, why = False, "内联脚本里出现绝对路径字面量"
                break
    if not runnable:
        # 复现块必须可执行，否则这条守卫会静默退化成只看签名
        assert "scripts/render.py" not in code, f"[63d] fence {idx} 应可执行却被拒: {why}"
        print(f"[63d] fence {idx} 跳过执行（{why}），仅做静态签名校验")
        continue
    cmds = "\n".join(lines)
    # 产物一律改写进本 fence 专属目录（共用目录会让第二个 fence 被「陈旧产物」误伤）
    work = tmp / f"fence{idx}"
    work.mkdir()
    paths = set(re.findall(r"/tmp/[\w.-]+", cmds))
    arts = [work / Path(x).name for x in paths]
    for x in paths:
        cmds = cmds.replace(x, str(work / Path(x).name))
    # 任何残留的沙箱外绝对路径都拒绝执行——「改写 /tmp 前缀」不等于「写入落在沙箱内」（实测）
    check_text = cmds.replace("${HOME}", home).replace("$HOME", home).replace("~/", home + "/")
    outside = [t for t in re.findall(r"(?<![\w.\"'])/[\w./-]+", check_text)
               if not t.startswith(str(tmp))]
    assert not outside, f"[63d] fence {idx}: 沙箱外绝对路径，拒绝执行: {outside[:3]}"
    t0 = time.time()
    p = subprocess.run(["bash", "-c", "set -euo pipefail\n" + cmds], cwd=SANDBOX,
                       env={**os.environ, "HOME": str(tmp / "home"),
                            "MAGPIE_ADDR": "127.0.0.1:1"},
                       capture_output=True, text=True)
    assert p.returncode == 0, f"[63d] demo fence {idx} failed: {p.stdout + p.stderr}"
    if "scripts/validate.py" in code:   # 用剥注释后的 code：注释里提到不算
        # 组数不写死：demo 扩组时这里不该成为绑定约束
        assert re.search(r"PASS: \d+ group\(s\) valid", p.stdout), f"[63d] fence {idx}: {p.stdout}"
    # 新鲜度：产物必须是本次真生成的。只防「命令失败被吞」不够——命令被整条删掉、
    # 旧产物还在，校验照样绿（实测）
    for a in arts:
        assert a.exists() and a.stat().st_mtime >= t0 - 1, \
            f"[63d] {a.name} not regenerated (stale artifact)"
    ran += 1
assert ran, "[63d] no demo fence was executed"
PY
ok "docs stay in sync with code (enums/fields, stale claims, EN-ZH parity, demo commands)"

# 64. 文档同步闸：公开面变更必须同批同步公开文档；全部公开文档的命令签名与脚本 usage 一致
python3 -I - "$ROOT" <<'PY'
import importlib.util, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("dg", root / "scripts/docgate.py")
dg = importlib.util.module_from_spec(spec); spec.loader.exec_module(dg)
docs = dg.public_docs(root)
assert docs, "[64] no public docs found"

# a) 全部公开文档的 bash 块：命令签名必须与脚本自己的 usage 契约一致（含用法占位符示例）
probs = dg.check_doc_commands(root, docs)
assert not probs, "[64a] doc command contract drift:\n  " + "\n  ".join(probs)

# b) 本批（工作区相对 HEAD，含未跟踪文件）改了公开面 → 必须同批改了公开文档
def git(*a):
    p = subprocess.run(["git", *a], cwd=root, capture_output=True, text=True)
    return p.returncode, p.stdout

rc, out = git("diff", "HEAD", "--name-only")
if rc == 0:                      # 干净克隆/无 git 时跳过：本条只约束「本批改动」
    files = set(out.split())
    rc2, untracked = git("ls-files", "--others", "--exclude-standard")
    if rc2 == 0:
        files |= set(untracked.split())
    pairs = []
    for f in sorted(files):
        orc, old = git("show", f"HEAD:{f}")
        p = root / f
        pairs.append((f, old if orc == 0 else None,
                      p.read_text(encoding="utf-8", errors="replace") if p.is_file() else None))
    changed = dg.surface_changes(pairs)
    if changed:
        _, diff = git("diff", "HEAD", "--", "scripts/", "templates/")
        reasons = dg.exemptions(diff)                   # {文件: [理由]}
        touched = [f for f in sorted(files) if f in docs]
        # 无文档同步时，每个公开面文件都必须自带豁免（一条无关豁免不能掩护整批）
        uncovered = [] if touched else [f for f in changed if f not in reasons]
        assert not uncovered, (
            "[64b] public surface changed without any public doc update:\n  "
            + "\n  ".join(f"{f} → {', '.join(dg.docs_mentioning(root, f, docs)) or '(no doc mentions it)'}"
                          for f in uncovered)
            + "\n  同步公开文档后再提交；确属纯内部改动时在【该文件】写 `# doc-sync: <理由>`")
PY
ok "doc sync gate: public-surface changes need doc updates; all doc commands match script usage"

# 65. 仓库自带 git hook：强制点必须在 git 层，不能靠解析命令字符串。
# 外部工具 hook 靠 `git\s+commit` 之类的正则认命令，实测 `git -C <path> commit`、
# `git -c k=v commit`、`git --no-pager commit`、消息里含 `--amend` 四种形态全部绕过，
# `echo 'git commit'` 反而误拦。git 原生 hook 由 git 自己触发，与命令拼写无关。
python3 -I - "$ROOT" <<'PY'
import importlib.util, os, re, stat, subprocess, sys, tempfile
from pathlib import Path
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("dg", root / "scripts/docgate.py")
dg = importlib.util.module_from_spec(spec); spec.loader.exec_module(dg)

hook = root / ".githooks/pre-commit"
assert hook.is_file(), "[65] 缺 .githooks/pre-commit：本仓库的提交闸就没有强制力"
assert hook.stat().st_mode & stat.S_IXUSR, "[65] .githooks/pre-commit 没有可执行位，git 会静默跳过"
body = hook.read_text()
assert "core.hooksPath" in body, "[65] hook 里要写明启用方式（git config core.hooksPath .githooks）"
m = [l.strip() for l in body.splitlines() if l.strip() and not l.strip().startswith("#")]
assert len(m) == 1 and m[0].startswith("exec python3 -I scripts/commit-gate.py"), \
    f"[65] hook 的可执行部分必须只有一条 exec 调用 commit-gate.py: {m}"
contract = dg.cli_contract((root / "scripts/commit-gate.py").read_text())
assert contract, "[65] commit-gate.py 没有 usage 行，无法校验 hook 的调用签名"
flags = m[0].split()[4:]        # exec python3 -I <script> <flags…>；注释里的用法说明不参与
assert set(flags) <= contract[3], f"[65] hook 用了未声明的旗标: {set(flags) - contract[3]}"
# 只跑对所有人都成立的那条：档案层不随仓库分发，外部贡献者没有它
assert "--docs-only" in flags, "[65] 仓库自带 hook 必须用 --docs-only，否则会拦住没有 review 档案的贡献者"

# 真提交验证：各种命令拼写都必须被拦。字符串匹配探针证明不了这件事。
with tempfile.TemporaryDirectory() as td:
    work = Path(td) / "repo"
    subprocess.run(["git", "clone", "-q", str(root), str(work)], check=True)
    def sync():
        for rel in ("scripts/commit-gate.py", "scripts/docgate.py", ".githooks/pre-commit"):
            (work / rel).parent.mkdir(parents=True, exist_ok=True)   # 新文件克隆里没有
            (work / rel).write_bytes((root / rel).read_bytes())
        (work / ".githooks/pre-commit").chmod(0o755)
    sync()
    def git(*a, **kw):
        return subprocess.run(["git", *a], cwd=work, capture_output=True, text=True, **kw)
    git("config", "core.hooksPath", ".githooks")
    git("config", "user.email", "probe@example.invalid")
    git("config", "user.name", "probe")
    # 制造公开面漂移：改 usage 行且不同步任何公开文档
    p = work / "scripts/doctor.py"
    src = p.read_text()
    assert "usage: doctor.py" in src, "[65] doctor.py usage 锚点缺失"
    p.write_text(src.replace("usage: doctor.py", "usage: doctor.py [--probe-drift]", 1))
    git("add", "scripts/doctor.py")
    forms = [
        ("plain", ["commit", "-m", "probe"]),
        ("-C 绝对路径", ["-C", str(work), "commit", "-m", "probe"]),
        ("-c k=v", ["-c", "user.name=probe", "commit", "-m", "probe"]),
        ("--no-pager", ["--no-pager", "commit", "-m", "probe"]),
        ("消息含 --amend", ["commit", "-m", "probe --amend handling"]),
    ]
    for name, args in forms:
        r = git(*args)
        assert r.returncode != 0, f"[65] {name} 绕过了提交闸（真提交实测）"
        assert "提交闸未通过" in r.stdout + r.stderr, f"[65] {name} 失败原因不是提交闸: {r.stdout + r.stderr}"
    # --no-verify 是 git 的显式退出通道，拦不住也不该假装拦得住
    r = git("commit", "--no-verify", "-m", "probe")
    assert r.returncode == 0, "[65] --no-verify 本应能显式跳过（这是 git 的既定语义）"
    # 正例：克隆里没有 review 档案（gitignored，不随仓库分发），不碰公开面的提交必须能过。
    # 少了这条，hook 可能把外部贡献者的每一次提交都挡死而我们看不见。
    git("reset", "-q", "--hard", "HEAD")
    sync()   # reset --hard 会把拷进去的已跟踪文件还原成 HEAD 旧版（实测踩过：旧版不认 --docs-only）
    (work / "README.md").write_text((work / "README.md").read_text() + "\n<!-- probe -->\n")
    git("add", "README.md")
    r = git("commit", "-m", "probe: doc-only change")
    assert r.returncode == 0, f"[65] 不碰公开面的提交被误拦: {r.stdout + r.stderr}"
    # 二进制文件进暂存区不得让闸门崩成堆栈：给文档加截图是现实场景，实测 UnicodeDecodeError
    (work / "shot.png").write_bytes(b"\x89PNG\r\n\x1a\n\x00\x01\xff\xfe")
    git("add", "shot.png")
    r = git("commit", "-m", "probe: binary asset")
    assert r.returncode == 0, f"[65] staged 二进制文件让提交闸崩了: {r.stdout + r.stderr}"
PY
ok "repo-owned git hook enforces the gate regardless of commit command spelling"

# 66. doctor 的接线冒烟步骤：必须【先验接线再评价组】、必须警告两参数会写主 model、
#     必须给全隔离三件套；且不得复活旧失真或给出会写坏配置的命令形态。
#     断言写成显式 FAIL 文案：裸 grep 在 set -euo pipefail 下会静默退 1，红都不知道红在哪。
python3 -I - > "$TMP/smoke-providers.json" <<'PY'
import json
print(json.dumps({"providers": [{"id": "acme", "models": ["acme/x"]}],
                  "groups": [{"id": "auto", "name": "gateway", "routing": "order",
                              "members": ["acme/x:high"]}]}))
PY
python3 -I scripts/doctor.py "$TMP/smoke-providers.json" > "$TMP/smoke.txt" 2>&1 || true
smoke_need() { grep -q -- "$2" "$TMP/smoke.txt" || { echo "FAIL: [66] 冒烟步骤缺少「$1」"; exit 1; }; }
smoke_deny() { if grep -q -- "$2" "$TMP/smoke.txt"; then echo "FAIL: [66] 冒烟步骤含失真/危险表述「$1」"; exit 1; fi; }
smoke_need "组级一切都不参与"        "nothing at group level runs at all"
smoke_need "先读接线的命令形态"      'magpie <agent> group/'
smoke_need "只有 claude 有启动器"    'magpie claude run'
smoke_need "两参数会写主 model"      'main model to that word'
smoke_need "验收证据是 group\\.id"   'group\.id'
smoke_need "applied.json 是陈旧账本" 'stale ledger'
smoke_need "隔离三件套含假 HOME"    'fake HOME'
smoke_deny "旧的「无 CLI 接管」说法" 'no CLI routing takeover'
smoke_deny "通用 run（会写坏配置）"  'magpie <agent> run'
ok "doctor smoke steps verify agent wiring before judging groups"

# 67. doctor 的形状诊断：每条判据都要有**必须报**的正例，也要有**必须不报**的反例（防空洞、防误伤）。
#     工具输出是英文（与 validate/apply 一致，README 入口是英文），needle 按英文原句取。
#     必须不报的五类：干净夹具；配了 match 的单成员组（还有模式成员兜着）；members 畸形
#     （null/字符串/数字/对象——不得崩，也不得把字符串长度当成员数）；**各自有锚、只在第二位共用
#     一个便宜备胎**的两组（最常见、也最容易误报的一面）；只有一组 order 类组的配置。
#     demo 那条反向断言同时是**粒度守卫**：把共享判定与「至少在一组居首」两处一起放宽成「同基名」，
#     demo 立刻刷出 6 对噪声；连「居首」一起去掉 → 7 对（只打印 6 对 + 溢出提示）。它会红。
python3 -I - "$TMP" <<'PY'
import json, shutil, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
demo_prov = json.loads(Path("examples/demo/input.providers.json").read_text())
demo_prov["groups"] = json.loads(Path("examples/demo/output.groups.json").read_text())["groups"]
DRIFT = "share a member but do not start with it the same way"
SINGLE = "group has a single member and no match"
TIER_DIFF = "start with the same model at different effort"
clean = [{"id": "a", "routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"]},
         {"id": "b", "routing": "order", "members": ["acme/code-standard:high", "acme/strong-reasoner:high"]},
         {"id": "c", "routing": "usage", "members": ["acme/lite-chat:low", "acme/long-reader:low"]}]
bad = [{"id": "a", "routing": "order", "members": ["acme/code-standard:high"]},
       {"id": "b", "routing": "order", "members": ["acme/strong-reasoner:high", "acme/code-standard:high"]},
       {"id": "c", "routing": "usage", "members": ["acme/lite-chat:low", "acme/code-standard:high"]},
       {"id": "e", "routing": "drain", "members": ["acme/long-reader:low"]},
       {"id": "f", "routing": "order", "members": ["acme/code-standard:medium", "acme/code-backup:medium"]}]
must_not = [{"id": "m", "routing": "order", "members": ["acme/lite-chat:low"], "match": ["acme/*"]},
            {"id": "n", "routing": "drain", "members": "oops", "match": ["acme/lite-chat:low"]},
            {"id": "k", "routing": "order", "members": None, "match": ["acme/long-reader:low"]},
            {"id": "k2", "routing": "order", "members": 7, "match": ["acme/long-reader:low"]},
            {"id": "k3", "routing": "order", "members": {"a": True}, "match": ["acme/long-reader:low"]}]
own_anchors = [{"id": "x", "routing": "order", "members": ["acme/code-standard:high", "acme/lite-chat:low"]},
               {"id": "y", "routing": "order", "members": ["acme/strong-reasoner:high", "acme/lite-chat:low"]}]
drain_only = [{"id": "dz", "routing": "drain", "members": ["acme/code-standard:high", "acme/code-backup:high"]}]
single = [{"id": "only", "routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"]}]
# 档位判据对多级 `:low+high` 与 `:fast` 必须沉默（AGENTS 这样写，没有夹具就是空话）
tier_silent = [{"id": "ts1", "routing": "order", "members": ["acme/code-standard:low+high", "acme/code-backup:high"]},
               {"id": "ts2", "routing": "order", "members": ["acme/code-standard:fast", "acme/code-backup:high"]}]
# 主路由（成员是 group/*）不参与叶子组判据
main_router = [{"id": "auto", "routing": "order", "members": ["group/g-x"]},
               {"id": "g-x", "routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"]}]
# 漂移配对封顶：9 组两两配对 = 36 对，必须截断并报出未列出的对数
# 首尾互换才能触发漂移（判据要 fa != fb 且共享成员至少在一组居首）：5 偶 × 4 奇 = 20 对 > 上限 6
many = [{"id": f"c{i}", "routing": "order",
         "members": (["acme/strong-reasoner:high", "acme/code-standard:high"] if i % 2 == 0
                     else ["acme/code-standard:high", "acme/strong-reasoner:high"])} for i in range(9)]
# match 写成字符串：不能算「有模式成员」，也不能打成长度数字
match_str = [{"id": "ms", "routing": "order", "members": ["acme/lite-chat:low"], "match": "acme/*"}]
# 重复 id：判据会「同一个 id 自相矛盾」，必须先声明
dup_ids = [{"id": "same", "routing": "order", "members": ["acme/code-standard:high"]},
           {"id": "same", "routing": "order", "members": ["acme/code-standard:medium"]}]
# 校验器遇到畸形枚举值不得崩（崩了 doctor 会打 traceback 再报 none = 假体检合格）
bad_enum = [{"id": "be", "routing": ["order"], "members": ["acme/code-standard:high"]}]
# 三段点分的模型名与 endpoint host 形态同形，必须 fail closed，但骨架（provider + 档位）要留下
dotted = [{"id": "dt", "routing": "order", "members": ["acme/glm-5.1.flash:high", "acme/code-backup:high"]}]
def run(groups, name, script="scripts/doctor.py"):
    doc = json.loads(json.dumps(demo_prov)); doc["groups"] = groups
    p = tmp / f"t67{name}.json"; p.write_text(json.dumps(doc, ensure_ascii=False))
    r = subprocess.run([sys.executable, "-I", script, str(p)], capture_output=True, text=True)
    assert r.returncode == 0, "doctor 退非 0（契约：发现问题也退 0）：\n" + r.stdout + r.stderr
    return r.stdout + r.stderr
def section(out):
    # 只在 `shape findings:` 段内判定——扫全份 stdout 会被冒烟文案里的词污染（将来某句含 none 就恒绿）
    lines = out.splitlines()
    i = next(k for k, l in enumerate(lines) if l.strip() == "shape findings:")
    body = []
    for l in lines[i + 1:]:
        if not l.strip():
            break
        body.append(l)
    return "\n".join(body)
def head(out):
    return out.split("validation:")[0]
b, c, d = run(bad, "bad"), run(clean, "clean"), run(demo_prov["groups"], "demo")
for needle in ("order " + SINGLE, "drain " + SINGLE,   # 单成员（模式 9），order 类含 drain
               DRIFT,                                  # 跨组首位（模式 13 / 坑 3）
               TIER_DIFF,                              # 同锚不同档：档位进缓存键，漏它最贵
               "members at different effort", "assumes interchangeable members"):
    assert needle in section(b), f"坏夹具漏报「{needle}」:\n{section(b)}"
assert "  none" in section(c), f"干净夹具不该有 finding:\n{section(c)}"
assert "validate does not enforce these" in section(c), f"限定语漂移（该段的英文限定句）:\n{section(c)}"
# 组行读数也要钉住：文档承诺每组打 `affinity=`、order 类组打 `first=`。不钉就会静默漂成只认 order。
assert "affinity=session" in head(d) and "first=acme/code-standard:high" in head(d), head(d)
dz = run(drain_only, "drain")
assert "first=acme/code-standard:high" in head(dz) and "routing=drain" in head(dz), head(dz)
# demo 反向断言＝粒度守卫：混档要报，不锚组不得被首位判据误伤
assert "members at different effort" in section(d) and DRIFT not in section(d), \
    f"demo 夹具失真（混档要报、不锚组不得被首位判据误伤）:\n{section(d)}"
# 反例：配了 match 就不说「没有故障转移」；members 畸形按空处理（组行显式 members=0，不是数字符串）
mu = run(must_not, "mustnot")
assert SINGLE not in section(mu), f"match 组被误判单成员 / 或畸形 members 处理不当:\n{section(mu)}"
assert "Traceback" not in mu, f"members 畸形时崩了:\n{mu}"
for z in ("n", "k", "k2", "k3"):
    assert f"{z:<14} routing=" in mu and f"routing={ 'drain' if z=='n' else 'order'}" in mu, f"{z} 组行缺失:\n{head(mu)}"
assert mu.count("members=0 match=1") == 4, f"畸形 members 没有统一按空处理:\n{head(mu)}"
# 假报警面：两组各自有自己的锚、只在第二位共用同一个便宜备胎 → 不是锚被挪走
oa = run(own_anchors, "ownanchors")
assert DRIFT not in section(oa), f"共用便宜备胎被误判成锚漂移:\n{section(oa)}"
# 单组配置：没有可比对象 → 首位类判据必须沉默（apply 的指引也写了这个前提）
sg = section(run(single, "single"))
assert DRIFT not in sg and TIER_DIFF not in sg, f"只有一组却报了首位类 finding:\n{sg}"
# 降级路径：doctor 旁边没有 validate.py → 必须明说没查，不得打 none 假装干净；
# 也不能把解释器报错原文当校验结论打出来
iso = tmp / "doctor_iso.py"; shutil.copy("scripts/doctor.py", iso)
dg = run(clean, "deg", str(iso))
deg = section(dg)
assert "were NOT RUN (could not load validate.py)" in deg and "  none" not in deg, f"缺比较器却谎报干净:\n{deg}"
assert "can't open file" not in dg, f"缺 validate.py 时把解释器错误当结论:\n{dg}"
# 档位沉默：多级 `:low+high` 与 `:fast` 都不是可解析档位（validate 合法、判据不得报警）
ts = section(run(tier_silent, "tiersilent"))
assert "members at different effort" not in ts and TIER_DIFF not in ts, f"档位判据对多级/`:fast` 不沉默:\n{ts}"
# 主路由不参与：否则每个网关组都会被误报
mr = section(run(main_router, "router"))
assert SINGLE not in mr, f"主路由被当成单成员组:\n{mr}"
# 配对封顶：必须截断并报出未列出数（否则 600 组配置能打出一行 MB 级文本）
cap = section(run(many, "many"))
assert "more pairs not listed" in cap, f"漂移配对没有上限:\n{cap[:400]}"
assert cap.count("but not in") <= 6, f"配对未截断:\n{cap[:400]}"
# match 是字符串：按空处理，单成员判据照常报，组行不得打出字符长度
mstr = run(match_str, "matchstr")
assert SINGLE in section(mstr), f"字符串 match 抑制了真判据:\n{section(mstr)}"
assert "match=" not in mstr, f"字符串 match 被打成字符数:\n{mstr[:400]}"
# 重复 id 必须先声明
dupsec = section(run(dup_ids, "dups"))
assert "duplicate group ids" in dupsec, f"重复 id 没有声明，判据看起来自相矛盾:\n{dupsec}"
# 畸形枚举值：校验器给出 FAIL，不打 traceback，也不得打 `none` 冒充体检合格
be = run(bad_enum, "badenum")
assert "unknown mode" in be and "Traceback" not in be, f"畸形 routing 让校验器崩了:\n{be[:500]}"
assert "CRASHED" not in be, f"合法 FAIL 被当成校验器崩溃:\n{be[:400]}"
# 点分模型名：fail closed（真名不得回显），但 provider 前缀与档位要留着（否则判据读不出档位）
dt = run(dotted, "dotted")
assert "glm-5.1.flash" not in dt, f"三段点分模型名原样回显（与 endpoint host 同形，必须掩）:\n{dt[:400]}"
assert "acme/<model 13 chars>:high" in dt, f"遮蔽没留骨架（provider/档位），档位判据无从核对:\n{dt[:400]}"
# 单成员判据的射程 = 除 manual 外所有模式（`smart` 是 routing 缺省值，漏掉它 = 对默认配法谎报干净）
sm = section(run([{"id": "gx", "members": ["acme/code-standard:high"]},
                  {"id": "gy", "routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"]}], "smart"))
assert SINGLE in sm, f"缺省 smart 的单成员组没被判（默认配法是最大面）:\n{sm}"
mn = section(run([{"id": "gm", "routing": "manual", "pick": "acme/code-standard:high",
                   "members": ["acme/code-standard:high"]}], "manual"))
assert SINGLE not in mn, f"manual 被误报「无故障转移」（schema.md：manual 不做故障转移）:\n{mn}"
assert "members at different effort" not in mn, f"manual 被套上「顶班重付」话术（它没有顶班）:\n{mn}"
wt = section(run([{"id": "gw", "routing": "weight",
                   "weights": {"acme/code-standard:high": 1, "acme/code-backup:low": 2},
                   "members": ["acme/code-standard:high", "acme/code-backup:low"]}], "weight"))
assert "assumes interchangeable members" in wt, f"weight 混档没点出「成员可互换」前提（usage/rotate 有）:\n{wt}"
# 两个组都缺 id ≠ 重复 id（validate 已单独 FAIL，这里不得伪造一条重复）
noid = section(run([{"members": ["acme/code-standard:high", "acme/code-backup:high"]},
                    {"members": ["acme/lite-chat:low", "acme/code-backup:high"]}], "noid"))
assert "duplicate group ids" not in noid, f"缺 id 被判成重复 id:\n{noid}"
# 崩溃判据不得被值里的 `Traceback` 字样骗到（那是合法 FAIL，不是校验器崩）
tb = run([{"id": "gt", "routing": "Traceback", "members": ["acme/code-standard:high", "acme/code-backup:high"]}], "tb")
assert "CRASHED" not in tb and "not evaluated" not in tb, f"值里的 Traceback 字样被当成校验器崩溃，形状段被抹掉:\n{tb[:400]}"
# 真崩溃必须抓到：旁边放一份运行期必崩的 validate.py 副本——不这么造就永远走不到那条路径
crash_dir = tmp / "crashrepo"; (crash_dir / "scripts").mkdir(parents=True, exist_ok=True)
shutil.copy("scripts/doctor.py", crash_dir / "scripts" / "doctor.py")
vsrc = Path("scripts/validate.py").read_text()
i = vsrc.index("\n", vsrc.index("def main("))
(crash_dir / "scripts" / "validate.py").write_text(vsrc[:i] + "\n    raise RuntimeError('injected')\n" + vsrc[i + 1:])
cr = run(clean, "crash", str(crash_dir / "scripts" / "doctor.py"))
assert "the validator CRASHED" in cr and "not evaluated" in cr, f"真崩溃没被判出来:\n{cr[:400]}"
assert "\n  none" not in cr, f"校验器崩了却打 `none`（谎报体检合格）:\n{cr[:400]}"
# 降级路径必须明说「这行的 id/首位只是形态摘要」，否则合法组名被掩会被读成「藏了个值」
assert "SHAPE SUMMARIES" in dg, f"降级时没声明读数已被掩:\n{dg[:300]}"
# 档位解析要能剥 `#账号`（模式 4 的多通道写法是常态）：混档判据必须在带账号的成员上照报
acct = section(run([{"id": "ga", "routing": "order",
                     "members": ["acme/code-standard:high#chan-a", "acme/code-backup:low#chan-b"]}], "acct"))
assert "members at different effort" in acct, f"带 #账号 的成员解析不出档位，档位判据静默失明:\n{acct}"
# 漂移归因的两个分支都要走到：共享成员是【后者】的首位
attr = section(run([{"id": "px", "routing": "order", "members": ["acme/code-standard:high", "acme/lite-chat:low"]},
                    {"id": "py", "routing": "order", "members": ["acme/lite-chat:low", "acme/long-reader:low"]}], "attr"))

# ── 这一批钉的是**输出文案与哨兵本身**：这些句子被改回去不会让任何判据变错，只会让读者读错，
#     所以每条都要有自己的断言（六个编号点各钉一处）。
# 1) 缺 id / 空 id 的组：打空列会被读成「这一行属于上面那个组」，必须打 doctor 自己的哨兵
noid = head(run([{"routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"]},
                 {"id": "", "routing": "order", "members": ["acme/lite-chat:low", "acme/long-reader:low"]}], "noid"))
assert "<no id>" in noid, f"缺 id 的组没有哨兵:\n{noid[:300]}"
# 2) 混档行里解析不出的档位打 `-` 会和组行的 `classifier=-` 撞同一个符号（读成「没有档位」）
tq = section(run([{"id": "tq", "routing": "order",
                   "members": ["acme/code-standard:high", "acme/code-backup:low", "acme/lite-chat"]}], "tq"))
assert "['high', 'low', '?']" in tq and "(? = unparseable tier)" in tq, \
    f"解析不出的档位要打成 `?` 并写明说明（打 `-` 会与组行的 classifier=- 撞符号）:\n{tq}"
# 3) `weight` 也在「成员可互换」名单里（文档口径同）：只写 usage/rotate 的夹具抓不到它掉出去
wq = section(run([{"id": "wq", "routing": "weight",
                   "members": ["acme/code-standard:high", "acme/lite-chat:low"]}], "wq"))
assert "weight assumes interchangeable members" in wq, f"weight 的互换性判据没生效:\n{wq}"
# 4) 降级面的真实形状：id/首位/classifier 一律掩，模式名与档位只在枚举表里才原样出现。
#    这两句同时钉住「枚举放行」与「声明与输出一致」——反向漂（把枚举也掩掉）也会红。
assert "routing=order" in dg, f"降级时枚举词也被掩掉了（与 note 的口径不符）:\n{dg[:300]}"
assert "classifier column" in dg, f"降级声明漏了 classifier 列（它同样被掩）:\n{dg[:300]}"
assert "first-member, drift and tier" in dg and "duplicate-group-id advisories still run" in dg, \
    f"降级声明没说清哪些判据也没跑（哪些还跑）:\n{dg[:400]}"
# 文案说「重复 id 与单成员两条仍会跑」，那就得真跑：降级面里两条都要在
dupg = [{"id": "dupd", "routing": "order", "members": ["acme/code-standard:high"]},
        {"id": "dupd", "routing": "order", "members": ["acme/code-standard:medium"]}]
dgd = run(dupg, "degdup", str(iso))
assert "duplicate group ids" in dgd and SINGLE in section(dgd), f"降级时这两条判据其实没跑:\n{dgd[:400]}"
assert "share a member but do not start" not in dgd, f"降级时首位/漂移判据却跑了（比较的是被掩形态）:\n{dgd[:400]}"
# 5) 段末限定语要写全射程（含 match 豁免），否则只看输出的人会把 none 读成「没有单成员组」
assert "pattern-pooled" in section(c), f"射程限定语漏掉 match 豁免:\n{section(c)[:300]}"
# 6) 崩溃判据不能被「值」骗到：含换行的组 id 被原样回显时能凭空造出一行 Traceback 头。
#    真崩要抓到（上面已钉），**假崩不能抓**，且假崩时形状判据照常出结论。
fake_tb = [{"id": "ok\nTraceback (most recent call last): fake", "routing": "order",
            "members": ["acme/code-standard:high"]},
           {"id": "ok\nTraceback (most recent call last): fake", "routing": "order",
            "members": ["acme/code-standard:high", "acme/code-backup:high"]}]
ft = run(fake_tb, "faketb")
assert "the validator CRASHED" not in ft, f"含换行的组 id 被误判成校验器崩溃:\n{ft[:400]}"
assert SINGLE in section(ft), f"假崩溃判据连带把形状诊断一起吞了:\n{section(ft)[:300]}"
assert "not evaluated" not in ft, f"没崩却打了 not evaluated:\n{ft[:300]}"

# ── 降级面的「封闭枚举表」必须真的覆盖 validate 的每张表：漏一个合法取值，那一列就会被打成
#    形态摘要，而同一行已经声明「模式名与档位按枚举原样出现」——那是谎报。逐个取值跑降级面。
import importlib.util as _iu
_sp = _iu.spec_from_file_location("vv", "scripts/validate.py")
_vv = _iu.module_from_spec(_sp); _sp.loader.exec_module(_vv)
enum_groups = ([{"id": f"em{i}", "routing": m, "affinity": "session",
                 "members": ["acme/code-standard:high", "acme/code-backup:high"]}
                for i, m in enumerate(sorted(_vv.ROUTING_MODES))]
               + [{"id": f"ea{i}", "routing": "order", "affinity": a,
                   "members": ["acme/code-standard:high", "acme/code-backup:high"]}
                  for i, a in enumerate(sorted(_vv.AFFINITY))]
               + [{"id": "ez", "routing": "", "affinity": "",
                   "members": ["acme/code-standard:high", "acme/code-backup:high"]}])
de = run(enum_groups, "degenum", str(iso))
missing = [m for m in sorted(_vv.ROUTING_MODES) if f"routing={m}" not in de] \
    + [a for a in sorted(_vv.AFFINITY) if f"affinity={a}" not in de]
assert not missing, f"降级时这些合法枚举值被掩掉了（与声明矛盾）：{missing}\n{de[:400]}"
# 空串是「配了但配成空」，打成空列会被读成串行 → 哨兵 `(empty)`
assert "routing=(empty)" in de and "affinity=(empty)" in de, f"空串值打成了空列：\n{de[:400]}"
# 首位列的掩码碰撞：两条不同成员串掩完一模一样时，必须当场说破「形态不是身份」
coll = [{"id": "ca", "routing": "order", "members": ["acme/aaaaaaaaaaaaaaaaaaaaaa1:high", "acme/code-backup:high"]},
        {"id": "cb", "routing": "order", "members": ["acme/aaaaaaaaaaaaaaaaaaaaaa2:high", "acme/code-backup:high"]}]
co = run(coll, "collide")
assert "shapes, not identities" in co, f"首位列塌成同串却没说破：\n{co[:500]}"
clean_coll = [{"id": "sa", "routing": "order", "members": ["acme/code-standard:high", "acme/code-backup:high"]},
              {"id": "sb", "routing": "order", "members": ["acme/code-standard:high", "acme/lite-chat:low"]}]
cn = run(clean_coll, "collideclean")
assert "shapes, not identities" not in cn, f"同一个锚被误报成掩码碰撞：\n{cn[:400]}"
assert "acme/lite-chat:low is first in py but not in px" in attr, f"漂移归因只走 fa 分支:\n{attr}"
PY
ok "doctor shape findings catch every issue and stay silent on clean, match-pooled, shared-backup, single-group and demo exceptions"

# 68. magpie 事后重排的可见性：漂移要在 dry-run 里以 `members: order changed` 现形，
#     写后输出要告诉使用者怎么复跑。主用例照现实：磁盘那份被回写换序、草案保持原序；
#     反方向也断言一次（diff 对称），免得断言只在某一种注入方向上成立。
#     「写完立刻读回比对顺序」那种检查恒真（读回就在自己写入之后），所以脚本里不存在它，这里也不测它。
#     夹具密钥用明显虚构的字面量。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
disk = {"providers": [{"id": "acme", "models": ["code-standard", "strong-reasoner"],
                       "key": "FAKE-injected-secret-not-a-real-key"}],
        "groups": [{"id": "g-code", "routing": "order",
                    "members": ["acme/code-standard:high", "acme/strong-reasoner:high"]}]}
swapped = json.loads(json.dumps(disk))
swapped["groups"][0]["members"] = list(reversed(swapped["groups"][0]["members"]))  # 模拟 magpie 回写后的顺序
same = json.loads(json.dumps(disk))
def apply(draft_groups, name, on_disk=None, write=False):
    tgt = tmp / f"t68disk{name}.json"
    tgt.write_text(json.dumps(on_disk or disk, ensure_ascii=False))
    dp = tmp / f"t68draft{name}.json"
    dp.write_text(json.dumps({"groups": draft_groups}, ensure_ascii=False))
    cmd = [sys.executable, "-I", "scripts/apply.py", str(dp), str(tgt)] + (["--write"] if write else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout
# 主用例照现实：磁盘上那份被 magpie 回写换了序，草案仍是当初写进去的顺序
drift = apply(same["groups"], "drift", on_disk=swapped)
assert "members: order changed" in drift, f"存量被重排却没报:\n{drift}"
# 反方向同样要现形（diff 是对称的），否则这条断言只在某一种注入方向上有效
drift2 = apply(swapped["groups"], "drift2")
assert "members: order changed" in drift2, f"草案侧换序却没报:\n{drift2}"
ident = apply(same["groups"], "same")
assert "order changed" not in ident, f"顺序一致却误报:\n{ident}"
# 脱敏断言要有牙：假密钥放进【会被草案替换掉的存量组】字段里——合并结果里没有它，校验照过；
# 只放 providers 的话 apply 从不回显那一段，把脱敏代码整段删掉也照样绿——密钥必须落在会被替换的存量组字段上。
leak_disk = json.loads(json.dumps(disk))
KEY = "FAKE-" + "t2Qp" * 6
leak_disk["groups"][0]["members"] = [f"acme/code-standard:high#{KEY}", "acme/strong-reasoner:high"]
leak_disk["groups"][0]["note"] = "keep an eye on leak.example.com"
leak = apply(same["groups"], "leak", on_disk=leak_disk)
for tok in (KEY, "leak.example.com"):
    hits = [l for l in leak.splitlines() if tok in l]
    assert not hits, f"apply 回显了 {tok!r} 形态：{len(hits)} 行\n" + "\n".join(hits)[:300]
# diff 段实测走的是「整组降级」（secretish 命中 → 组内所有串变 `<text N chars>`），不是 shield 的
# `#<account N chars>`（那是 doctor 与 apply 写前校验那条路径，第 51 条已分别钉住）
assert "<text" in leak, f"diff 段的整组降级没生效（key 只被 secretish 判定挡住才算）:\n{leak[:400]}"
# 写后指引只属于 --write：dry-run 打它会让使用者以为还没写盘就要去复跑
assert "recheck drift later" not in ident, f"dry-run 打了写后指引:\n{ident}"
w = apply(same["groups"], "write", write=True)
assert "recheck drift later" in w and "post-write validation PASS" in w, w
# 指引里那句「需要两组 order 类组才有得比」也要钉住：它是使用者唯一知道「单组配置查不出漂移」的地方
assert "two or more such groups" in w, f"漂移指引缺「两组及以上」前提:\n{w}"
assert "FAKE-injected-secret-not-a-real-key" not in w, "apply 输出泄漏密钥字面量"
PY
ok "apply surfaces post-hoc member reorder (dry-run + recheck hint), no false positive"


# 69. 写盘失败必须干净退出：只读目标 → 无 traceback、不留孤儿备份、原文件不动
#     （上一版在这里抛 PermissionError，且已经把 .bak-* 写进了目录）
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = json.loads(Path("examples/demo/input.providers.json").read_text())
prov["groups"] = [{"id": "g-legacy", "routing": "order",
                   "members": ["acme/code-standard:high", "acme/code-backup:high"]}]
tgt = tmp / "ro69.json"; tgt.write_text(json.dumps(prov, ensure_ascii=False))
d = tmp / "ro69-draft.json"
d.write_text(json.dumps({"groups": [{"id": "g-new", "routing": "order",
                                     "members": ["acme/code-standard:high", "acme/code-backup:high"]}]}))
tgt.chmod(0o444)
try:
    r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(tgt), "--write"],
                       capture_output=True, text=True)
finally:
    tgt.chmod(0o644)
out = r.stdout + r.stderr
assert r.returncode == 1, f"只读目标写盘失败却没退 1:\n{out[:300]}"
assert "Traceback" not in out, f"只读目标 → 抛 traceback 而不是可读 FAIL:\n{out[-400:]}"
assert "could not write" in out, f"没有可读的失败原因:\n{out[:300]}"
assert not list(tmp.glob("ro69.json.bak-*")), f"留下了孤儿备份: {[p.name for p in tmp.glob('ro69.json.bak-*')]}"
assert json.loads(tgt.read_text())["groups"][0]["id"] == "g-legacy", "原文件被动过"
PY
ok "apply exits cleanly when the write itself fails (read-only target): no traceback, no orphan backup"

# 70. render 的入口类型闸：模板顶层不是对象（list / 字符串）、或 groups 不是 list —— 必须干净 FAIL。
#     原先顶层给 list 会 AttributeError，groups 给对象会在遍历时崩，两者都甩 traceback 给使用者。
python3 -I - "$TMP" <<'PY'
import subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
cases = [("top-level list", "[1, 2]", "template must be an object"),
         ("top-level string", '"acme/code-standard:high"', "template must be an object"),
         ("groups not a list", '{"groups": {"not": "a list"}}', "template groups must be a list")]
for label, body, needle in cases:
    p = tmp / ("tpl70-%s.json" % label.split()[0])
    p.write_text(body)
    r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(p),
                        "examples/demo/roles.mapped.json", str(tmp / "out70.json")],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert r.returncode != 0, f"{label} 的模板被接受了（退出码 0）：\n{out[:200]}"
    assert "Traceback" not in out, f"{label} 的模板 → traceback：\n{out[:300]}"
    assert needle in out, f"{label} 的模板缺可读诊断（要含 `{needle}`）：\n{out[:200]}"
PY
ok "render rejects a non-object template and a non-list groups key (clean FAIL, no traceback)"

# 71. 少了 validate.py（只拷走 apply.py / render.py）：脱敏与校验的表都在 validate.py，
#     这种安装坏了必须是可读 FAIL，不是 traceback；否则使用者以为是自己配置写错了。
python3 -I - "$TMP" <<'PY'
import shutil, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
bare = tmp / "no-validate-dir"; bare.mkdir(exist_ok=True)
for s in ("apply.py", "render.py"):
    shutil.copyfile(f"scripts/{s}", bare / s)
for s, args in (("apply.py", ["--help"]), ("render.py", ["--help"])):
    r = subprocess.run([sys.executable, "-I", str(bare / s), *args], capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert "Traceback" not in out, f"{s} 缺 validate.py 时甩 traceback：\n{out[:300]}"
    assert "cannot load validate.py" in out, \
        f"{s} 缺 validate.py 时没说破是安装坏了：\n{out[:300]}"
PY
ok "apply/render fail readably when validate.py is missing next to them"

# 72. apply 的 diff 行里的**字段名**同样是使用者写的串，也要过脱敏。
#     被替换组的**存量侧**不过校验（校验的是合并结果），所以「只存在于存量侧、草案删掉」的键会直接
#     进 diff——正是 AGENTS.md 承诺要让使用者看见的 `→ (unset)` 那几行。整组降级（echo=False）也拦不住，
#     因为漏的是键名不是值。合法字段名（name/pick/routing…）是短词，过 shield 原样通过。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
TOK = "zQ" * 10                                   # 20 位连续 alnum，运行时拼出来，源码里没有长串
base = json.loads(Path("examples/demo/input.providers.json").read_text())
cur = [{"id": "keyface", "routing": "order", "name": "kept",
        "members": ["acme/code-standard:high", "acme/code-backup:high"],
        TOK: "x",
        "rules": [{"use": "acme/code-standard:high", TOK + "rule": "z"}]}]
c = tmp / "keyface-cur.json"; c.write_text(json.dumps({**base, "groups": cur}, ensure_ascii=False))
# 两侧都要带 rules（同下标）才会进 rule_lines 的逐键分支；只有一侧有 rules 时打出的是
# `rules: 1 → 0`，那条路径碰不到规则键名。
d = [{"id": "keyface", "routing": "order", "members": ["acme/code-standard:high"],
      "rules": [{"use": "acme/code-standard:high"}]}]
dd = tmp / "keyface-drt.json"; dd.write_text(json.dumps({"groups": d}, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(dd), str(c)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"夹具本该合法（合并结果过校验才走得到 diff）：\n{out[:400]}"
# 反空跑：这条 diff 必须真的发生（否则「键被掩」是空断言）
gone = [l for l in out.splitlines() if "→ (unset)" in l]
assert len(gone) >= 3, f"夹具没打出「存量侧键被删掉」的 diff 行（组键 + 规则键 + name?）：\n{out[:400]}"
for tok in (TOK, TOK + "rule"):
    hits = [l for l in out.splitlines() if tok in l]
    assert not hits, "apply 的 diff 原样回显了存量侧的字段名：\n" + "\n".join(hits)[:300]
assert "<ref 20 chars>:" in out, f"被掩的字段名没给出形态摘要：\n{out[:400]}"
# 合法字段名不许被连坐掩掉（否则 diff 读不出改的是哪个字段）
assert any("name:" in l for l in out.splitlines()), f"合法字段名也被掩了：\n{out[:400]}"
PY
ok "apply's diff masks existing-side field names but keeps schema field names readable"

# 73. 高熵串落在 **provider 段**时也必须整串掩：`_redact_model` 只在骨架可信时才保留骨架
#     （`<20 位 alnum>/ops` 这种组 id 在 schema 上完全合法），整串熵判据是对整串算的、算完就丢。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
TOK = "xY" * 10
doc = {"groups": [{"id": f"{TOK}/ops", "routing": "order", "members": ["acme/code-standard:high"]}]}
f = tmp / "headent.json"; f.write_text(json.dumps(doc, ensure_ascii=False))
kn = tmp / "headent-known.json"; kn.write_text(json.dumps(["acme/code-standard:high"]))
drt = tmp / "headent-drt.json"; drt.write_text(json.dumps({"groups": []}))
faces = [("doctor", ["scripts/doctor.py", str(f)]),
         ("validate", ["scripts/validate.py", str(f), str(kn)])]
bad = []
for label, args in faces:
    r = subprocess.run([sys.executable, "-I", *args], capture_output=True, text=True)
    if TOK in (r.stdout + r.stderr):
        bad.append(label)
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(f)], capture_output=True, text=True)
if TOK in (r.stdout + r.stderr):
    bad.append("apply")
assert not bad, f"provider 段的高熵串在这几个面原样回显：{bad}"
# 对照组：同一个串不含 `/` 时本来就该掩（证明不是「熵判据整体没跑」）
doc2 = {"groups": [{"id": TOK, "routing": "order", "members": ["acme/code-standard:high"]}]}
f2 = tmp / "headent2.json"; f2.write_text(json.dumps(doc2, ensure_ascii=False))
r2 = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f2)], capture_output=True, text=True)
assert TOK not in (r2.stdout + r2.stderr) and "<ref 20 chars>" in (r2.stdout + r2.stderr), \
    f"不含 `/` 的同形串对照失败（判据本身没跑？）：\n{(r2.stdout + r2.stderr)[:300]}"
PY
ok "high-entropy refs are masked no matter which segment they sit in"

# 74. 含控制字符的串一律按 ascii 转义。这不是「像不像凭据」的问题——一个换行能把一行输出变成两行
#     （凭空造出工具自己的句子，包括崩溃报告），OSC/BEL 转义能改终端标题、响铃。四个输出面共用 shield() 这一道。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
ESC, BEL, NL = chr(27), chr(7), chr(10)
# 最强的一种：把**整帧**（头部行 + `File "…"` 帧）都塞进组 id。控制字符转义之后这条路也到不了
# （值造不出新行，而判崩据看的是行首），所以文档里那条「值伪造行首」的边界已经不存在。
weird = f"g{ESC}]0;pwn{BEL}{NL}Traceback (most recent call last):{NL}  File \"x.py\", line 1, in <module>"
doc = {"groups": [{"id": weird, "routing": "order", "members": ["acme/code-standard:high"]}]}
f = tmp / "ctrl.json"; f.write_text(json.dumps(doc, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/doctor.py", f], capture_output=True, text=True)
out = r.stdout + r.stderr
for ch, name in ((ESC, "ESC"), (BEL, "BEL")):
    assert ch not in out, f"doctor 把 {name} 转义原样打进终端"
assert NL + "Traceback" not in out, "被回显的值在行首造出了一行 Traceback"
assert not any(l.startswith("Traceback (most recent call last)") for l in out.splitlines()), \
    "值本身造出的 Traceback 行落在了行首"
assert "CRASHED" not in out, "把值当字符塞进来就被判成校验器崩溃"
assert "the validator CRASHED" not in out, "整帧都塞进值里仍被判成崩溃（控制字符转义没兜住最强的一种）"
# 身份还得读得到：转义是「显式化」，不是「不显示」
assert "g\\x1b]0;pwn\\x07" in out, f"控制字符没按转义形态显示：\n{out[:400]}"
PY
ok "control characters are escaped before reaching the terminal (no forged lines)"

# 崩溃夹具的**唯一造法**（75 与 118 共用）。不能再靠「把 where.value 嵌 1200 层」制造崩溃：
# 校验器的值遍历改成迭代以后，那种配置出**判决**（第 128 条钉的正是这件事）——继续拿它当崩溃夹具
# 就等于测一个不再存在的崩溃，而且真正的崩溃分支从此没人测。现在由**注入**造崩溃：三个脚本一起拷进
# 一个目录，副本 validate 的 main 一进去就抛/自杀。apply/doctor 按 __file__ 找同目录的 validate.py，
# 拷过去的那份才是它们真正跑起来的那份。
cat > "$TMP/crashkit.py" <<'PY'
import shutil
from pathlib import Path

RAISE = '\ndef main():\n    raise RuntimeError("boom: injected validator crash")'
KILL = '\ndef main():\n    import os, signal\n    os.kill(os.getpid(), signal.SIGKILL)'


def script_dir(tmp, name, inject=RAISE):
    d = Path(tmp) / name
    d.mkdir(parents=True, exist_ok=True)
    for f in ("apply.py", "doctor.py", "validate.py"):
        shutil.copy(Path("scripts") / f, d / f)
    v = d / "validate.py"
    src = v.read_text()
    assert "\ndef main():" in src, "注入点没了（validate.main 改名或改形）——崩溃夹具会静默失效"
    v.write_text(src.replace("\ndef main():", inject, 1))
    assert inject.strip() in v.read_text(), "注入没落地：崩溃夹具是空操作"
    return d
PY
# 75. **校验器崩了** ≠ **你的配置不合格**：这是两件事，两个脚本必须给同一个口径。
#     混成一句「merged result would not pass validation」等于一边甩 traceback 一边指使用者的配置写错了。
#     夹具用的是**一份本身合格**的配置（同一份配上真 validate 判 PASS，已钉），崩溃由副本注入。
#     这样测的才是「崩了」这个分支，而不是「本来就不合格、顺便崩了」。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
sys.path.insert(0, str(tmp))
import crashkit
crash_cfg = {"providers": [{"id": "acme", "models": ["x"]}], "groups": [
    {"id": "g1", "routing": "order", "members": ["acme/x:high"],
     "rules": [{"use": "acme/x:high", "where": [{"field": "tokens", "op": "lt", "value": [[[1]]]}]}]}]}
deep = tmp / "deep.json"; deep.write_text(json.dumps(crash_cfg, ensure_ascii=False))
# validate 单独跑时只收 `{"groups": …}`（providers 出现在顶层就是它的 FAIL），
# 所以「这份配置本身合格」要在**只含 groups 的那一份**上钉，别拿 apply 的目标文件格式喂它。
dponly = tmp / "deep-groups.json"; dponly.write_text(json.dumps({"groups": crash_cfg["groups"]}))
kn = tmp / "deep-known.json"; kn.write_text(json.dumps(["acme/x"]))
drt = tmp / "deep-drt.json"
drt.write_text(json.dumps({"groups": [{"id": "zz", "routing": "order", "members": ["acme/x:high"]}]}))
rp = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(dponly), str(kn)],
                    capture_output=True, text=True)
assert rp.stdout.startswith("PASS:"), f"夹具配置本身不合格，测不到崩溃分支：\n{rp.stdout[:300]}"
kit = crashkit.script_dir(tmp, "r75-kit")
ra = subprocess.run([sys.executable, "-I", str(kit / "apply.py"), str(drt), str(deep)],
                    capture_output=True, text=True)
oa = ra.stdout + ra.stderr
assert "boom: injected validator crash" in oa, f"夹具没能真的让校验器崩：\n{oa[:300]}"
assert "CRASHED" in oa, f"apply 没说破校验器崩了：\n{oa[:300]}"
assert "would not pass validation" not in oa, f"apply 把崩溃报成配置不合格：\n{oa[:300]}"
rd = subprocess.run([sys.executable, "-I", str(kit / "doctor.py"), str(deep)],
                    capture_output=True, text=True)
od = rd.stdout + rd.stderr
assert "boom: injected validator crash" in od, f"doctor 那侧的夹具没能真的让校验器崩：\n{od[:300]}"
assert "CRASHED" in od and "not evaluated" in od, f"doctor 对同一份配置没说破崩溃：\n{od[:300]}"
assert "single member" not in od, "崩溃时还在打形状结论"
# 反向：真的「不合格」（不是崩）时不许谎报崩溃
badcfg = tmp / "badcfg.json"
badcfg.write_text(json.dumps({"providers": [], "groups": [
    {"id": "b1", "routing": "order", "members": ["acme/nope:high"]}]}, ensure_ascii=False))
rb = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(badcfg)], capture_output=True, text=True)
ob = rb.stdout + rb.stderr
assert "would not pass validation" in ob and "CRASHED" not in ob, \
    f"普通不合格被判成崩溃（两个方向都得准）：\n{ob[:300]}"
PY
ok "apply and doctor both distinguish a validator crash from a config rejection"

# 76. `providers[].models` 的形状错误必须给可读 FAIL：写成标量会 TypeError；写成**字符串**更坏——被迭代成逐字符
#     集合，于是每个合法成员都被报 unknown model ref：把「配置写错」伪装成「模型清单里没有」。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
drt = tmp / "m2-drt.json"; drt.write_text(json.dumps({"groups": [{"id": "keep", "routing": "order",
                                                                 "members": ["acme/code-standard:high"]}]}))
for label, models in (("标量", 5), ("字符串", "code-standard"), ("元素非串", [5])):
    doc = {"providers": [{"id": "acme", "models": models}],
           "groups": [{"id": "g", "routing": "order", "members": ["acme/code-standard:high"]}]}
    f = tmp / f"m2-{len(label)}.json"; f.write_text(json.dumps(doc, ensure_ascii=False))
    for script, args in (("doctor.py", [str(f)]), ("apply.py", [str(drt), str(f)])):
        r = subprocess.run([sys.executable, "-I", f"scripts/{script}", *args], capture_output=True, text=True)
        out = r.stdout + r.stderr
        assert "Traceback" not in out, f"{label} 的 providers 让 {script} 甩 traceback：\n{out[:300]}"
        assert r.returncode != 0, f"{label} 的 providers 被 {script} 接受了：\n{out[:300]}"
        assert "models must be a list of strings" in out, \
            f"{label} 的 providers 在 {script} 上没有可读诊断（两个脚本文案要一致）：\n{out[:300]}"
# 再来一遍**降级**下的：validate.py 坏掉时 doctor 用的是自己那份逐条对齐的副本，守卫必须同样生效，
# 否则两份副本迟早漂（doctor 的降级路径不能依赖 validate.py，所以这份副本是刻意留的）。
broken = tmp / "m2-broken"; broken.mkdir(exist_ok=True)
(broken / "validate.py").write_text("import this is not python\n")
(broken / "doctor.py").write_text(Path("scripts/doctor.py").read_text())
ddoc = {"providers": [{"id": "acme", "models": 5}],
        "groups": [{"id": "g", "routing": "order", "members": ["acme/code-standard:high"]}]}
df = tmp / "m2-deg.json"; df.write_text(json.dumps(ddoc, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", str(broken / "doctor.py"), str(df)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert "Traceback" not in out and "models must be a list of strings" in out and r.returncode != 0, \
    f"降级副本对畸形 providers 的口径与主路径不一致：\n{out[:300]}"
PY
ok "malformed providers[].models fails readably and identically in doctor and apply"

# 77. 「validate.py 在，但坏了（语法错）」也要说破是安装问题：这种失败如果只剩一句 SyntaxError
#     traceback，使用者会以为是自己配置写错。
python3 -I - "$TMP" <<'PY'
import subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
broken = tmp / "broken-deps"; broken.mkdir(exist_ok=True)
for s in ("apply.py", "render.py", "validate.py", "doctor.py"):
    (broken / s).write_text("import this is not python\n" if s == "validate.py"
                            else Path(f"scripts/{s}").read_text())
for s in ("apply.py", "render.py"):
    r = subprocess.run([sys.executable, "-I", str(broken / s), "--help"], capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert "Traceback" not in out, f"{s} 遇到坏掉的 validate.py 时甩 traceback：\n{out[:300]}"
    assert "cannot load validate.py" in out, f"{s} 没说破是依赖坏了：\n{out[:300]}"
# doctor 在同样的坏依赖下必须**诚实降级**（它不崩、但要说清哪些检查没跑）
doc = tmp / "broken-doc.json"; doc.write_text('{"groups": [{"id": "g", "routing": "order", "members": ["acme/x:high"]}]}')
r = subprocess.run([sys.executable, "-I", str(broken / "doctor.py"), str(doc)], capture_output=True, text=True)
assert "Traceback" not in (r.stdout + r.stderr), f"doctor 遇到坏 validate.py 时甩 traceback：\n{(r.stdout + r.stderr)[:300]}"
assert "could not load validate.py" in (r.stdout + r.stderr), \
    f"doctor 对坏依赖的降级口径变了：\n{(r.stdout + r.stderr)[:300]}"
PY
ok "a syntactically broken validate.py yields a readable install error, not a traceback"

# 78. 值里伪造「校验器崩溃」：崩溃判据按行首匹配，而 python 的 `str.splitlines()` 除了 C0
#     还认 U+0085(NEL)/U+2028(LS)/U+2029(PS)。这三种字符原来不在转义表里 → 一份普通的
#     「未知字段」不合格会被报成「校验器崩了」，doctor 还会因此把形状诊断整段吞掉
#     （那段本来在给真结论）。现在两处都堵住：转义表覆盖全部断行字符；崩溃判定只看 stderr，
#     且头部行必须是第一条非空行。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
d = tmp / "fake-draft.json"
d.write_text(json.dumps({"groups": [{"id": "zz", "routing": "order", "members": ["acme/code-standard:high"]}]}))
for name, brk in (("NEL", "\u0085"), ("LS", "\u2028"), ("PS", "\u2029")):
    fake = ("not-a-field" + brk + "Traceback (most recent call last):" + brk
            + '  File "validate.py", line 999, in main' + brk + "RecursionError: boom")
    doc = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/code-standard:high"], fake: "x"}]}
    f = tmp / ("fake-" + name + ".json"); f.write_text(json.dumps(doc, ensure_ascii=False))
    r = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f)], capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert "CRASHED" not in out, f"{name} 让普通不合格被报成校验器崩溃：\n{out[:400]}"
    assert brk not in out, f"{name} 原样进了输出（能造出新行、改终端状态）：\n{out[:400]}"
    assert "not evaluated" not in out, f"{name} 把形状诊断整段吞了：\n{out[:400]}"
    assert "single member" in out, f"{name} 让真实的形状发现消失了：\n{out[:400]}"
    ra = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(f)], capture_output=True, text=True)
    oa = ra.stdout + ra.stderr
    assert "CRASHED" not in oa, f"apply 把 {name} 伪造的崩溃认成了真崩溃：\n{oa[:400]}"
    assert "would not pass validation" in oa, f"apply 对 {name} 既没说崩也没说不合格：\n{oa[:400]}"
PY
ok "a value forging a traceback with NEL/LS/PS is not mistaken for a validator crash"

# 79. 写盘前目标文件被别人改过 → 拒绝写。合并结果是按**读档时**的内容算的，拿旧结果盖上去
#     会静默丢掉对方的改动，而工具还会报 OK（实测：注入的组被抹掉，apply 全程毫无察觉）。
#     目标文件放大到几千个组，是为了让并发写者**必然**落在「读档→写盘」那个窗口里，
#     而不是靠 sleep 赌；同时用原子替换（os.replace）避免读到写了一半的文件。
python3 -I - "$TMP" <<'PY'
import json, os, subprocess, sys, threading, time
from pathlib import Path
tmp = Path(sys.argv[1])
prov = json.loads(Path("examples/demo/input.providers.json").read_text())["providers"]
groups = [{"id": f"g{i}", "routing": "order", "members": ["acme/code-standard:high"]} for i in range(5000)]
target = tmp / "race.json"
target.write_text(json.dumps({"providers": prov, "groups": groups}, ensure_ascii=False))
draft = tmp / "race-draft.json"
draft.write_text(json.dumps({"groups": [{"id": "g0", "routing": "order", "members": ["acme/code-standard:high"]}]}))
stop = threading.Event()

def writer():
    n = 0
    while not stop.is_set():
        n += 1
        doc = {"providers": prov, "groups": groups + [
            {"id": f"CONCURRENT-MARK-{n}", "routing": "order", "members": ["acme/code-standard:high"]}]}
        tmpf = tmp / f"race.tmp.{n}"
        tmpf.write_text(json.dumps(doc, ensure_ascii=False))
        os.replace(tmpf, target)          # 原子替换：读者只会看到完整的一版
        time.sleep(0.01)

th = threading.Thread(target=writer, daemon=True)
th.start()
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(draft), str(target), "--write"],
                   capture_output=True, text=True)
stop.set()
th.join(timeout=2)
out = r.stdout + r.stderr
assert "OK: merged" not in out, f"并发写者还在写，apply 却报了成功：\n{out[-400:]}"
assert "changed on disk" in out, f"apply 没说出目标文件在运行期间被改过：\n{out[-400:]}"
final = json.loads(target.read_text())
ids = [g.get("id") for g in final.get("groups", [])]
assert any(str(i).startswith("CONCURRENT-MARK-") for i in ids), "并发写者写进去的组被静默抹掉了"
PY
ok "apply refuses to write when the target file changed under it"

# 80. 容器型规则字段（time/folders…）的改动不许打两行一模一样的话：两侧塌成同一形状时，
#     必须说清「只有形状、差异在里面」——打「被掩那段」是撒谎（这里根本没有凭据）。
#     同一处也钉住 `diff_pair` 的「只对字符串打掩蔽标注」守卫：容器不许用那句措辞。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = json.loads(Path("examples/demo/input.providers.json").read_text())["providers"]
cur = {"providers": prov, "groups": [{"id": "g1", "routing": "order",
        "members": ["acme/code-standard:high"],
        "rules": [{"use": "acme/code-standard:high", "time": {"from": "08:00", "to": "09:00"}}]}]}
c = tmp / "cont-cur.json"; c.write_text(json.dumps(cur, ensure_ascii=False))
d = tmp / "cont-draft.json"
d.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": ["acme/code-standard:high"],
        "rules": [{"use": "acme/code-standard:high", "time": {"from": "09:30", "to": "10:30"}}]}]},
        ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(c)], capture_output=True, text=True)
out = r.stdout + r.stderr
line = next((l for l in out.splitlines() if "rules[0].time" in l), "")
assert line, f"规则级容器字段的改动没出现在 diff 里：\n{out[:400]}"
assert "shape only" in line, f"容器塌成同形时没说清差异在里面：\n{line}"
assert "masked segment" not in line, f"容器不许用「被掩那段」那句（这里没有凭据）：\n{line}"
PY
ok "container-shaped rule fields say 'shape only' instead of pretending to be masked"

# 81. `where` 的值被扣下只给形态时，两侧形状相同就等于「看不见改动」——必须标注。
#     反向也钉：形状不同时不许多打标注。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = json.loads(Path("examples/demo/input.providers.json").read_text())["providers"]
def run(cur_value, new_value):
    cur = {"providers": prov, "groups": [{"id": "g1", "routing": "order",
            "members": ["acme/code-standard:high"],
            "rules": [{"use": "acme/code-standard:high",
                       "where": [{"field": "tokens", "op": "lt", "value": cur_value}]}]}]}
    c = tmp / "w-cur.json"; c.write_text(json.dumps(cur, ensure_ascii=False))
    d = tmp / "w-draft.json"
    d.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
            "members": ["acme/code-standard:high"],
            "rules": [{"use": "acme/code-standard:high",
                       "where": [{"field": "tokens", "op": "lt", "value": new_value}]}]}]},
            ensure_ascii=False))
    r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(c)],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    return next((l for l in out.splitlines() if "rules[0].where" in l), ""), out
line, out = run("1000", "2000")            # 等长字符串值：两侧形状一样
assert line, f"where 的改动没出现在 diff 里：\n{out[:400]}"
assert "withheld" in line, f"where 的值被扣下时没说清两边确实不同：\n{line}"
assert "1000" not in out and "2000" not in out, f"where 的值原样回显了：\n{out[:400]}"
line2, out2 = run("1000", "20000")         # 长度不同：形状已经不同
assert line2 and "withheld" not in line2, f"形状不同就不该多打「被扣下」标注：\n{line2}"
PY
ok "where values are marked as differing when both sides collapse to the same shape"

# 82. 自由文本（note/name）与整组降级：整条值只是被扣下给形态，**没有任何一段被掩**——
#     说成「差别落在被掩的那段」是骗人（会让人去找凭据，而那里根本没有凭据）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = json.loads(Path("examples/demo/input.providers.json").read_text())["providers"]
cur = {"providers": prov, "groups": [{"id": "g1", "routing": "order",
        "members": ["acme/code-standard:high"], "note": "a" * 30}]}
c = tmp / "note-cur.json"; c.write_text(json.dumps(cur, ensure_ascii=False))
d = tmp / "note-draft.json"
d.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
        "members": ["acme/code-standard:high"], "note": "b" * 30}]}, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(c)], capture_output=True, text=True)
out = r.stdout + r.stderr
line = next((l for l in out.splitlines() if l.strip().startswith("note:")), "")
assert line, f"note 的改动没出现在 diff 里：\n{out[:400]}"
assert "masked segment" not in line, f"整条扣下的值被说成「差别在被掩那段」：\n{line}"
assert "withheld" in line, f"没说清值被扣下、两边确实不同：\n{line}"
PY
ok "withheld free text is not described as differing inside a masked segment"

# 83. NaN / Infinity 不是合法 JSON（RFC 8259 没有这两个字面量），但 python 的 json 收它们。
#     放过就等于把别的解析器读不回来的配置写进 providers.json——正是 validate 自己在文件头
#     警告的「类型写错 → 整份 providers.json 解析失败」。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = json.loads(Path("examples/demo/input.providers.json").read_text())["providers"]
for lit in ("NaN", "Infinity"):
    c = tmp / "nan-cur.json"
    c.write_text(json.dumps({"providers": prov, "groups": [
        {"id": "g1", "routing": "order", "members": ["acme/code-standard:high"], "context": 1000}]},
        ensure_ascii=False))
    d = tmp / "nan-draft.json"
    d.write_text('{"groups":[{"id":"g1","routing":"order","members":["acme/code-standard:high"],'
                 '"context":%s}]}' % lit)
    r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(c), "--write"],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert r.returncode != 0, f"{lit} 被接受了：\n{out[:300]}"
    assert "Traceback" not in out, f"{lit} 让 apply 甩 traceback：\n{out[:300]}"
    assert "finite" in out, f"{lit} 没有可读的诊断：\n{out[:300]}"
    assert lit not in c.read_text(), f"{lit} 被写进了 providers.json"
PY
ok "NaN and Infinity are rejected before anything is written"

# 84. render 自己写盘失败要说人话：apply 对「建不出备份」「写不进去」都有可读 FAIL，
#     render 这里原来只剩一句 PermissionError traceback——使用者会以为是自己模板写错了。
python3 -I - "$TMP" <<'PY'
import os, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
ro = tmp / "ro-out"
ro.mkdir(exist_ok=True)
os.chmod(ro, 0o500)
try:
    r = subprocess.run([sys.executable, "-I", "scripts/render.py", "examples/demo/output.groups.json",
                        "examples/demo/roles.mapped.json", str(ro / "out.json")],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert r.returncode != 0, f"写不进去却报了成功：\n{out[:300]}"
    assert "Traceback" not in out, f"render 写盘失败甩了 traceback：\n{out[:300]}"
    assert "could not write" in out, f"render 写盘失败没有可读诊断：\n{out[:300]}"
finally:
    os.chmod(ro, 0o700)
PY
ok "render reports a write failure readably instead of a traceback"

# 85. 超深组链要**判决**，不要崩：环检测与深度计算都改成迭代，超深链撞 RecursionError
#     的话「深度 ≤8」这条守卫对真正的深链根本不生效（1200 层实测：崩溃而非「太深了」）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
n = 1200
# (a) 无环的深链 → 该拿到「太深了」的判决（深度守卫真的生效）
acyclic = [{"id": f"a{i}", "routing": "order", "members": [f"group/a{i + 1}"]} for i in range(n)]
acyclic.append({"id": f"a{n}", "routing": "order", "members": ["acme/code-standard:high"]})
fa = tmp / "deepchain-acyclic.json"; fa.write_text(json.dumps({"groups": acyclic}, ensure_ascii=False))
ra = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(fa)], capture_output=True, text=True)
oa = ra.stdout + ra.stderr
assert "Traceback" not in oa, f"超深链让校验器崩了（深度守卫因此没生效）：\n{oa[:300]}"
assert "nesting depth" in oa, f"无环深链没有拿到「太深了」的判决：\n{oa[:300]}"
# (b) 有环的深链 → 该拿到「环」的判决
cyclic = [{"id": f"c{i}", "routing": "order", "members": [f"group/c{i + 1}"]} for i in range(n)]
cyclic.append({"id": f"c{n}", "routing": "order", "members": ["group/c1"]})
fc = tmp / "deepchain-cyclic.json"; fc.write_text(json.dumps({"groups": cyclic}, ensure_ascii=False))
rc = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(fc)], capture_output=True, text=True)
oc = rc.stdout + rc.stderr
assert "Traceback" not in oc, f"有环深链让校验器崩了：\n{oc[:300]}"
assert "cycle" in oc, f"有环深链没有拿到「环」的判决：\n{oc[:300]}"
PY
ok "a very deep group chain gets a verdict instead of a recursion crash"

# 86. `#账号` 段的熵阈值要钉住：12 位连续字母数字起判熵（掩成 `<account N chars>`），
#     11 位按「账号标签本来就是短词」的既定取舍原样显示。这条阈值以前**一个断言都没有**——
#     把它放宽到 16，整个套件照样全绿（没人守）。取值用运行时拼出来的字面量。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
for n, expect_masked in ((11, False), (12, True), (16, True)):
    acct = "zQ" * (n // 2) + ("z" if n % 2 else "")      # 运行时拼出来，源码里没有长串
    doc = {"groups": [{"id": "g1", "routing": "order", "members": [f"acme/code-standard:high#{acct}"]}]}
    f = tmp / f"acct{n}.json"; f.write_text(json.dumps(doc, ensure_ascii=False))
    r = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f)], capture_output=True, text=True)
    out = r.stdout + r.stderr
    line = next((l for l in out.splitlines() if "first=" in l), "")
    assert line, f"{n} 位账号段的组行没打出来：\n{out[:300]}"
    if expect_masked:
        assert f"<account {n} chars>" in line, f"{n} 位账号段没有被掩：\n{line}"
        assert acct not in line, f"{n} 位账号段原样进了输出：\n{line}"
    else:
        assert acct in line, f"{n} 位账号段不该被掩（既定取舍：账号标签是短词）：\n{line}"
PY
ok "the #account entropy threshold is pinned on both sides"


# 87. 带控制字符的串**仍然**要过脱敏判据：控制字符那层只是「不能造出新行」，
#     不是「带控制字符就整条原样打出来」。凭据形态 + 一个换行的组 id，
#     在几个输出面都不得出现原串——这一条曾经破口：控制字符分支在脱敏之前就 return 了。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
NL = chr(10)
TOK = "s" + "k" + "-" + "a" * 20          # 运行时拼出来：源码里不留凭据形态的字面量
doc = {"groups": [{"id": TOK + NL, "routing": "order", "members": ["acme/code-standard:high"]}]}
f = tmp / "ctrlcred.json"; f.write_text(json.dumps(doc, ensure_ascii=False))
kn = tmp / "ctrlcred-known.json"; kn.write_text(json.dumps(["acme/code-standard:high"]))
drt = tmp / "ctrlcred-drt.json"; drt.write_text(json.dumps({"groups": []}))
faces = [("doctor", ["scripts/doctor.py", str(f)]),
         ("validate", ["scripts/validate.py", str(f), str(kn)])]
bad = []
for label, args in faces:
    r = subprocess.run([sys.executable, "-I", *args], capture_output=True, text=True)
    out = r.stdout + r.stderr
    if TOK in out:
        bad.append(label)
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(f)], capture_output=True, text=True)
if TOK in (r.stdout + r.stderr):
    bad.append("apply")
assert not bad, f"带控制字符的凭据形态串在这些面原样回显了：{bad}"
# 对照：同一个串**不带**控制字符时本来就该掩（证明不是「脱敏整体没跑」）
plain = {"groups": [{"id": TOK, "routing": "order", "members": ["acme/code-standard:high"]}]}
f2 = tmp / "ctrlcred2.json"; f2.write_text(json.dumps(plain, ensure_ascii=False))
r2 = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f2)], capture_output=True, text=True)
assert TOK not in (r2.stdout + r2.stderr) and "<ref 23 chars>" in (r2.stdout + r2.stderr), \
    f"不含控制字符的同形串对照失败（判据本身没跑？）：\n{(r2.stdout + r2.stderr)[:300]}"
PY
ok "control characters do not bypass the redaction rules"

# 88. 成员列表里两种「看不见的改动」必须分开说：**换了模型**和**换了通道**不是一回事。
#     批准写入时最该看见的是前者，说成后者会让人以为只是换了个账号。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
A, B = "a" * 21, "b" * 21                     # 高熵模型名 → 两侧都掩成同一形态
prov = {"providers": [{"id": "acme", "models": [A, B, "code-standard"]}]}
tgt = dict(prov); tgt["groups"] = [{"id": "g1", "routing": "order", "members": [f"acme/{A}:high"]}]
f = tmp / "swap.json"; f.write_text(json.dumps(tgt, ensure_ascii=False))
drt = tmp / "swap-draft.json"
drt.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": [f"acme/{B}:high"]}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(f)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"dry-run 没过：\n{out[:400]}"
assert "the model reference was replaced" in out, \
    f"换模型没被单独说出来（会被读成只换了通道）：\n{out[:600]}"
assert "changed only inside a masked segment" not in out, \
    f"换模型被说成了「差别落在被掩那段」：\n{out[:600]}"
# 对照：只换 `#账号`（模型没变）时必须说「差别落在被掩的那段」，且**不许**说换了模型
acct1, acct2 = "p" * 12, "q" * 12
tgt2 = dict(prov); tgt2["groups"] = [{"id": "g2", "routing": "order",
                                      "members": [f"acme/code-standard:high#{acct1}"]}]
f2 = tmp / "chan.json"; f2.write_text(json.dumps(tgt2, ensure_ascii=False))
drt2 = tmp / "chan-draft.json"
drt2.write_text(json.dumps({"groups": [{"id": "g2", "routing": "order",
                                         "members": [f"acme/code-standard:high#{acct2}"]}]}))
r2 = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt2), str(f2)], capture_output=True, text=True)
out2 = r2.stdout + r2.stderr
assert r2.returncode == 0, f"dry-run 没过：\n{out2[:400]}"
assert "changed only inside a masked segment" in out2, \
    f"换通道没说「差别落在被掩那段」：\n{out2[:600]}"
assert "the model reference was replaced" not in out2, \
    f"换通道被说成了换模型：\n{out2[:600]}"
PY
ok "a swapped model and a switched channel are reported differently"

# 89. render 的输出会进终端也会进 providers.json：产物里有 secret-like 的串就**不打印、不写盘**。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
TOK = "s" + "k" + "-" + "b" * 20          # 运行时拼出来：源码里不留凭据形态的字面量
tpl = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/code-standard:high"],
                   "note": TOK}]}
tf = tmp / "secret-tpl.json"; tf.write_text(json.dumps(tpl, ensure_ascii=False))
mf = tmp / "secret-map.json"; mf.write_text(json.dumps({}))
outf = tmp / "secret-out.json"
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf), str(outf)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode != 0, f"含凭据形态的产物竟被渲染成功：\n{out[:300]}"
assert TOK not in out, f"凭据形态的串被原样打了出来：\n{out[:300]}"
assert not outf.exists(), "含凭据形态的产物竟被写盘了"
# 对照：干净模板照常渲染
ok_tpl = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/code-standard:high"]}]}
tf2 = tmp / "clean-tpl.json"; tf2.write_text(json.dumps(ok_tpl, ensure_ascii=False))
outf2 = tmp / "clean-out.json"
r2 = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf2), str(mf), str(outf2)],
                    capture_output=True, text=True)
assert r2.returncode == 0 and outf2.exists(), f"干净模板没渲染成功：\n{(r2.stdout + r2.stderr)[:300]}"
PY
ok "render refuses to print or write a config that contains a credential-shaped value"


# 90. 控制字符不能是**判据的刀**：它既不能让你跳过脱敏，也不能把一条连续凭据切成碎片
#     让「连续 16+ 位」判不出来。判据作用在**去掉控制字符后的串**上。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
NL = chr(10)
TOK = "s" + "k" + "-" + "a" * 10 + NL + "b" * 12      # 中间断了一行：两段都短于熵阈值
assert len(TOK) > 20
doc = {"groups": [{"id": TOK, "routing": "order", "members": ["acme/code-standard:high"]}]}
f = tmp / "frag.json"; f.write_text(json.dumps(doc, ensure_ascii=False))
kn = tmp / "frag-known.json"; kn.write_text(json.dumps(["acme/code-standard:high"]))
drt = tmp / "frag-draft.json"; drt.write_text(json.dumps({"groups": []}))
faces = [("doctor", ["scripts/doctor.py", str(f)]),
         ("validate", ["scripts/validate.py", str(f), str(kn)])]
bad = []
for label, args in faces:
    r = subprocess.run([sys.executable, "-I", *args], capture_output=True, text=True)
    out = r.stdout + r.stderr
    # 转义后的形态不止一种（\n / \x0a / 原样），所以按**碎片**判：凭据的任一段都不该出现
    if "a" * 10 in out or "b" * 12 in out:
        bad.append(label)
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(f)], capture_output=True, text=True)
if "a" * 10 in (r.stdout + r.stderr):
    bad.append("apply")
assert not bad, f"被控制字符切碎的凭据在这些面原样回显了：{bad}"
# 反过来：非 ASCII 不该被转义掉（转义的唯一目的是控制字符，可读性不该顺带牺牲）
r2 = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f)], capture_output=True, text=True)
out2 = r2.stdout + r2.stderr
assert "\\u7ec4" not in out2, "非 ASCII 的值被转义成了 \\uXXXX（可读性掉一大截）"
PY
ok "control characters cannot break the redaction judgements"

# 91. render 的产物：**键**也要查（键会原样落进 providers.json）；按熵可疑的串要给出警告。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
K = "s" + "k" + "-" + "c" * 24          # 运行时拼出来：源码里不留凭据形态的字面量
mf = tmp / "r91-map.json"; mf.write_text(json.dumps({}))
tpl = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/m1"], "levels": {K: 1}}]}
tf = tmp / "r91-tpl.json"; tf.write_text(json.dumps(tpl, ensure_ascii=False))
of = tmp / "r91-out.json"
if of.exists():
    of.unlink()
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf), str(of)],
                   capture_output=True, text=True)
assert r.returncode != 0, f"含凭据形态的**键**竟被渲染成功：\n{(r.stdout + r.stderr)[:300]}"
assert not of.exists(), "含凭据形态的键竟被写盘了"
assert K not in (r.stdout + r.stderr), "凭据形态的键被原样打了出来"
# 按熵可疑但无已知前缀的串：长模型名与 token 形态同形，硬拦会堵死好配置 → 只警告、仍然渲染
H = "z" * 32
tpl2 = {"groups": [{"id": "g1", "routing": "order", "members": [f"acme/{H}"]}]}
tf2 = tmp / "r91-tpl2.json"; tf2.write_text(json.dumps(tpl2, ensure_ascii=False))
of2 = tmp / "r91-out2.json"
r2 = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf2), str(mf), str(of2)],
                    capture_output=True, text=True)
assert r2.returncode == 0 and of2.exists(), f"干净渲染被误伤：\n{(r2.stdout + r2.stderr)[:300]}"
assert "look like a token or a host" in r2.stderr, f"按熵可疑的串没有警告：\n{r2.stderr[:300]}"
assert H not in r2.stderr, "警告里把原串打了出来"
PY
ok "render checks keys too and warns about entropy-suspicious strings"

# 92. 组的**键**也是使用者写的串：secret-like 的键不该被放行（它会原样落进 providers.json）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
K = "s" + "k" + "-" + "d" * 24          # 运行时拼出来：源码里不留凭据形态的字面量
doc = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/code-standard:high"],
                   "weights": {K: 1000}}]}
f = tmp / "keyval.json"; f.write_text(json.dumps(doc, ensure_ascii=False))
kn = tmp / "keyval-known.json"; kn.write_text(json.dumps(["acme/code-standard:high"]))
r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(f), str(kn)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode != 0, f"secret-like 的键被放行了：\n{out[:300]}"
assert K not in out, f"凭据形态的键被原样打了出来：\n{out[:300]}"
assert "secret-like" in out, f"报错没说是 secret-like：\n{out[:300]}"
PY
ok "a secret-like dict key is rejected"

# 93. 「换了模型」这句话只对 `members` 成立：别的列表字段换的是**条目**，说成模型引用就是撒谎。
python3 -I - "$TMP" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ap", "scripts/apply.py")
ap = importlib.util.module_from_spec(spec); spec.loader.exec_module(ap)
old = {"id": "g1", "levels": ["z" * 20]}
new = {"id": "g1", "levels": ["y" * 20]}
lines = ap.group_diff(old, new)
body = " ".join(lines)
assert "the entry was replaced" in body, f"非成员字段没说「条目被换掉」：\n{body}"
assert "model reference" not in body, f"非成员字段被说成了「模型引用被换掉」：\n{body}"
PY
ok "only the members field is described as a model reference"


# 94. 值里**写着**崩溃判据的原文也不算崩：判据要的是 stderr 的**第一条非空行**是那行头部
#     且**下一行**是 `File "…"` 帧——一行文字凑不出两行，值造不出这个形状（值里的控制字符
#     早就被转义，连新行都造不出来）。这条把「值伪造崩溃」的路彻底堵死：apply 即使回头去读
#     stdout 里的那段字，也判不出崩溃。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
d = tmp / "fake94-draft.json"
d.write_text(json.dumps({"groups": [{"id": "zz", "routing": "order", "members": ["acme/code-standard:high"]}]}))
fake = 'Traceback (most recent call last):  File "validate.py", line 999, in main'
doc = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/code-standard:high"], fake: "x"}]}
f = tmp / "fake94.json"; f.write_text(json.dumps(doc, ensure_ascii=False))
ra = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(f)], capture_output=True, text=True)
oa = ra.stdout + ra.stderr
assert "CRASHED" not in oa, f"apply 把值里写的崩溃判据当成了真崩溃：\n{oa[:400]}"
assert "would not pass validation" in oa, f"apply 对这份配置既没说崩也没说不合格：\n{oa[:400]}"
rd = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f)], capture_output=True, text=True)
od = rd.stdout + rd.stderr
assert "CRASHED" not in od, f"doctor 把值里写的崩溃判据当成了真崩溃：\n{od[:400]}"
assert "single member" in od, f"真实的形状发现消失了：\n{od[:400]}"
PY
ok "a value that merely spells the crash header is not a crash"


# 95. 文档里的**示例**也要与实际输出对得上：demo README 用等长的 `name` 改动当例子，
#     那条改动实际打的是「整条值被扣下」，不是「差别落在被掩那段」。文档失真同样是缺陷。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = {"providers": [{"id": "acme", "models": ["code-standard"]}]}
tgt = dict(prov); tgt["groups"] = [{"id": "g1", "routing": "order", "members": ["acme/code-standard:high"],
                                    "name": "aaaa1111"}]
f = tmp / "doc95.json"; f.write_text(json.dumps(tgt, ensure_ascii=False))
drt = tmp / "doc95-draft.json"
drt.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": ["acme/code-standard:high"],
                                        "name": "bbbb2222"}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(f)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"dry-run 没过：\n{out[:300]}"
assert "the value is withheld; the two values differ" in out, \
    f"等长的 name 改动没打出「整条值被扣下」：\n{out[:400]}"
assert "differ only inside a masked segment" not in out, \
    f"等长的 name 改动被说成了「差别落在被掩那段」：\n{out[:400]}"
readme = Path("examples/demo/README.md").read_text()
assert "<text 8 chars> → <text 8 chars> (the value is withheld; the two values differ)" in readme, \
    "demo README 里的 name 例子与实际输出不一致"
assert "<text 8 chars> → <text 8 chars> (differ only inside a masked segment)" not in readme, \
    "demo README 还把 name 例子挂在「差别落在被掩那段」那句下"
PY
ok "the documented diff example matches what the tool actually prints"

# 96. provider 的 id 也是使用者写的任意串（可能是内网网关域名）：报错里不得原样回显。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
HOST = "gw.internal.example.com"          # 虚构的内网主机名形态
bad = {"providers": [{"id": HOST, "models": "not-a-list"}], "groups": []}
f = tmp / "pid.json"; f.write_text(json.dumps(bad, ensure_ascii=False))
drt = tmp / "pid-draft.json"
drt.write_text(json.dumps({"groups": [{"id": "zz", "routing": "order",
                                      "members": ["acme/code-standard:high"]}]}))
for label, args in (("doctor", ["scripts/doctor.py", str(f)]),
                    ("apply", ["scripts/apply.py", str(drt), str(f)])):
    r = subprocess.run([sys.executable, "-I", *args], capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert HOST not in out, f"{label} 把 provider id 原样回显了：\n{out[:300]}"
    assert "<ref 23 chars>" in out, f"{label} 没给形态摘要：\n{out[:300]}"
PY
ok "a provider id is never echoed verbatim"

# 97. render 对**主机名/endpoint** 形态也要给警告（产物不被拦，但使用者得知道）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
mf = tmp / "r97-map.json"; mf.write_text(json.dumps({}))
tpl = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/m1"],
                   "note": "https://gw.internal.example/v1"}]}
tf = tmp / "r97-tpl.json"; tf.write_text(json.dumps(tpl, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf)], capture_output=True, text=True)
assert r.returncode == 0, f"render 失败了：\n{(r.stdout + r.stderr)[:300]}"
assert "look like a token or a host" in r.stderr, f"endpoint 形态没有警告：\n{r.stderr[:300]}"
assert "gw.internal.example" not in r.stderr, "警告里把原串回显了出来"
PY
ok "render warns about hostname-shaped strings in the product"

# 98. 长度口径只有一种：含控制字符的串若被判可疑，整串掩成 `<ref N chars>`，N = **原串**长度。
python3 -I - "$TMP" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("v", "scripts/validate.py")
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
for raw, expect in (("s" + "k" + "-" + "a" * 20 + "\x01", 24),
                    ("acme/api.internal.example\x01", 26),
                    ("acme/model#abcdefghijkl\x01", 24)):
    got = v.shield(raw)
    assert got == f"<ref {expect} chars>", f"长度口径不一致：{raw!r} → {got}（应为 <ref {expect} chars>）"
    assert len(raw) == expect
# 不含控制字符的串仍走原来的形态表（骨架还在）
assert v.shield("acme/api.internal.example") == "acme/<model 20 chars>", \
    f"不含控制字符的串不该被整串掩：{v.shield('acme/api.internal.example')}"
PY
ok "the length in a shape summary always refers to the original string"


# 99. **检测侧**也要先剥控制字符再判：判据单真源。凭据形态靠「前缀 + 连续 16 位」的连续性，
#     一个换行就把它切成碎片——回显侧（shield）已经堵住，检测侧（validate 拒收、render 的闸）
#     若还拿原串判，就会出现「脱敏表认为它是凭据、检测器认为它干净」这种自相矛盾。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
NL = chr(10)
TOK = "s" + "k" + "-" + "a" * 10 + NL + "b" * 12      # 中间断一行：两段都短于熵阈值
mf = tmp / "r99-map.json"; mf.write_text(json.dumps({}))
tpl = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/m1"], "note": TOK}]}
tf = tmp / "r99-tpl.json"; tf.write_text(json.dumps(tpl, ensure_ascii=False))
of = tmp / "r99-out.json"
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf), str(of)],
                   capture_output=True, text=True)
assert r.returncode != 0, f"render 把被换行切碎的凭据渲染了：\n{(r.stdout + r.stderr)[:300]}"
assert not of.exists(), "含被切碎凭据的产物竟被写盘了"
g = tmp / "r99-groups.json"
g.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": ["acme/m1"],
                                      "note": TOK}]}, ensure_ascii=False))
kn = tmp / "r99-known.json"; kn.write_text(json.dumps(["acme/m1"]))
rv = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(g), str(kn)],
                    capture_output=True, text=True)
assert rv.returncode != 0, f"validate 判这份配置合格：\n{(rv.stdout + rv.stderr)[:300]}"
assert "secret-like" in (rv.stdout + rv.stderr), \
    f"validate 没说清是 secret-like：\n{(rv.stdout + rv.stderr)[:300]}"
PY
ok "the detection side strips control characters before judging too"

# 100. 成员 diff 的配对：多条成员掩成同一形态时，必须优先配「核心引用相同」的那条。
#      否则「两个模型各换了通道」会被说成「模型引用被换掉」——那是**事实为假**的断言。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
A, B = "a" * 16, "b" * 16
x, q, p, y = "x" * 12, "q" * 12, "p" * 12, "y" * 12
prov = {"providers": [{"id": "acme", "models": [A, B]}]}
tgt = dict(prov); tgt["groups"] = [{"id": "g1", "routing": "order",
                                    "members": [f"acme/{A}:high#{x}", f"acme/{B}:high#{q}"]}]
f = tmp / "r100.json"; f.write_text(json.dumps(tgt, ensure_ascii=False))
drt = tmp / "r100-draft.json"
drt.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                        "members": [f"acme/{B}:high#{p}", f"acme/{A}:high#{y}"]}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(f)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"dry-run 没过：\n{out[:400]}"
assert "changed only inside a masked segment" in out, \
    f"两条都只换了通道，却没说「差别落在被掩那段」：\n{out[:600]}"
assert "model reference was replaced" not in out, \
    f"模型集合没变，却被说成换了模型：\n{out[:600]}"
PY
ok "members that only switched channel are not reported as a model swap"

# 101. 模型段也被掩时，工具**分不清**是换了模型还是换了通道——那就明说分不清，不许二选一。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
E, F = "e" * 16, "f" * 16
x, y = "x" * 12, "y" * 12
prov = {"providers": [{"id": "acme", "models": [E, F]}]}
tgt = dict(prov); tgt["groups"] = [{"id": "g1", "routing": "order",
                                    "members": [f"acme/{E}:high#{x}"]}]
f = tmp / "r101.json"; f.write_text(json.dumps(tgt, ensure_ascii=False))
drt = tmp / "r101-draft.json"
drt.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                        "members": [f"acme/{F}:high#{y}"]}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(drt), str(f)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, f"dry-run 没过：\n{out[:400]}"
assert "cannot be told apart" in out, \
    f"分不清时没有明说分不清：\n{out[:600]}"
assert "model reference was replaced" not in out, \
    f"分不清时却断言换了模型：\n{out[:600]}"
assert "changed only inside a masked segment" not in out, \
    f"分不清时却断言只换了通道：\n{out[:600]}"
PY
ok "an ambiguous change says it cannot tell model from channel"

# 102. provider 的 id 一律给长度摘要：它是内网主机名（两段式也算），不按全局表的射程放过。
#      validate 与 doctor 的降级副本必须**同一口径**。
python3 -I - "$TMP" <<'PY'
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
tmp = Path(sys.argv[1])
for host in ("gw.internal.example.com", "llm.internal"):
    bad = {"providers": [{"id": host, "models": "not-a-list"}], "groups": []}
    f = tmp / ("r102-" + host + ".json"); f.write_text(json.dumps(bad))
    r = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f)], capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert host not in out, f"provider id 原样回显了（{host}）：\n{out[:300]}"
    assert f"<ref {len(host)} chars>" in out, f"没给长度摘要（{host}）：\n{out[:300]}"
# 降级副本（旁边没有 validate.py）必须同一口径
work = Path(tempfile.mkdtemp())
shutil.copy("scripts/doctor.py", work / "doctor.py")
bad = {"providers": [{"id": "llm.internal", "models": "not-a-list"}], "groups": []}
f = work / "bad.json"; f.write_text(json.dumps(bad))
r = subprocess.run([sys.executable, "-I", str(work / "doctor.py"), str(f)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert "llm.internal" not in out, f"降级副本原样回显了 provider id：\n{out[:300]}"
assert "<ref 12 chars>" in out, f"降级副本与 validate 的口径不一致：\n{out[:300]}"
PY
ok "a provider id is always a length summary, in both paths"

# 103. 漂移扫描的预算不能造成漏报，也不能谎报 clean：
#      (a) 候选对按成员名字母序推进会让排序靠后的共享成员吃不到预算 → 漂移直接消失；
#      (b) 截断披露句若挂在「有匹配」分支里，搜索没走完却一条都没匹配上时就永远不执行，
#          输出直接是「none」——把「没查完」说成「查过且干净」。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
N = 250
def cfg(drift):
    groups = [{"id": f"g{i}", "routing": "order", "members": [f"acme/m{i}", "aaa/backup"]}
              for i in range(N)]
    if drift:
        groups += [{"id": "gX", "routing": "order", "members": ["zzz/shared", "acme/mX"]},
                   {"id": "gY", "routing": "order", "members": ["acme/mY", "zzz/shared"]}]
    models = [f"m{i}" for i in range(N)] + ["mX", "mY", "backup"]
    return {"providers": [{"id": "acme", "models": models}], "groups": groups}
def run(doc, name):
    f = tmp / f"r103-{name}.json"; f.write_text(json.dumps(doc))
    r = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f)], capture_output=True, text=True)
    return r.stdout + r.stderr
out = run(cfg(True), "drift")
assert "gX/gY" in out, f"排序靠后的共享成员的漂移被预算吃掉了（漏报）：\n{out[:900]}"
assert "stopped early" in out, f"预算耗尽却没明说计数是下界：\n{out[:900]}"
clean = run(cfg(False), "nodrift")
assert "stopped early" in clean, \
    f"搜索没走完却一条都没匹配上时，披露句不执行 → 输出「none」＝谎报 clean：\n{clean[:900]}"
assert "none" not in clean.split("stopped early")[0], \
    f"搜索被截断却报成了 none：\n{clean[:900]}"
PY
ok "the drift scan never hides a finding behind its budget, and never says 'none' when it stopped early"

# 104. render 的产物是要进 providers.json 的配置本体：写出 NaN/Infinity 等于让下游解析器
#      整份读不回来。两个出口（stdout / 文件）都得是严格 JSON。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tpl = {"groups": [{"id": "g1", "routing": "order", "members": ["<role:r>"],
                   "intentSure": float("nan"), "context": float("inf")}]}
tf = tmp / "r104-tpl.json"; tf.write_text(json.dumps(tpl))
mf = tmp / "r104-map.json"; mf.write_text(json.dumps({"r": ["acme/m1"]}))
of = tmp / "r104-out.json"
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf), str(of)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode != 0, f"含非有限数的模板竟然渲染成功：\n{out[:300]}"
assert not of.exists(), "非有限数被写进了产物文件"
assert "non-finite" in out or "NaN" in out, f"没给可读的失败原因：\n{out[:300]}"
r2 = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf)],
                    capture_output=True, text=True)
assert r2.returncode != 0, "含非有限数的模板竟然输出到 stdout"
assert ": NaN" not in r2.stdout and ": Infinity" not in r2.stdout, \
    f"stdout 上出现了非有限数：\n{r2.stdout[:300]}"
PY
ok "render refuses to emit a product that is not valid JSON"

# 105. 模型引用里的 provider 段也是主机形态的 id：内网网关名不能原样进报错
#      （不含点的短标识符照原样显示，否则每条报错都变成 <ref 4 chars>/…）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = {"providers": [{"id": "llm.internal", "models": ["m1"]}]}
pf = tmp / "r105-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r105-draft.json"
df.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                      "members": ["llm.internal/nope"]}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "llm.internal" not in out, f"模型引用里原样回显了内网主机名：\n{out[:400]}"
assert "<ref 12 chars>" in out, f"模型引用里的 provider 段没给长度摘要：\n{out[:400]}"
plain = {"providers": [{"id": "acme", "models": ["m1"]}]}
pf2 = tmp / "r105-prov2.json"; pf2.write_text(json.dumps(plain))
df2 = tmp / "r105-draft2.json"
df2.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                       "members": ["acme/nope"]}]}))
r2 = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df2), str(pf2)],
                    capture_output=True, text=True)
out2 = r2.stdout + r2.stderr
assert "acme/nope" in out2, f"不含点的 provider 标识符被无脑掩掉，报错没法读了：\n{out2[:400]}"
PY
ok "a hostname-shaped provider id is not echoed back through a model reference"


# 106. provider 段是主机形态时，**所有回显面**都得给长度摘要：validate 报错、doctor 组行、
#      apply 的 diff 段共用同一张表（口径写在单真源里，不是某个报错点打补丁）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
HOST = "llm.internal"          # 虚构的两段主机名（内网网关形态）
prov = {"providers": [{"id": HOST, "models": ["m", "model"]}],
        "groups": [{"id": "g1", "routing": "order", "members": [f"{HOST}/m"],
                    "classifier": f"{HOST}/m"}]}
pf = tmp / "r106-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r106-draft.json"
df.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                      "members": [f"{HOST}/m2"],
                                      "classifier": f"{HOST}/m"}]}))
pf2 = tmp / "r106-prov2.json"
pf2.write_text(json.dumps({"providers": [{"id": HOST, "models": ["m", "m2"]}],
                           "groups": [{"id": "g1", "routing": "order",
                                       "members": [f"{HOST}/m"]}]}))
(tmp / "r106-known.json").write_text(json.dumps(["m", "m2"]))
for cmd in (["scripts/doctor.py", str(pf)],
            ["scripts/validate.py", str(pf), str(tmp / "r106-known.json")],
            ["scripts/apply.py", str(df), str(pf2)]):
    r = subprocess.run([sys.executable, "-I"] + cmd, capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert HOST not in out, f"{cmd[0]} 原样回显了 provider 段（{HOST}）：\n{out[:500]}"
    assert "<ref 12 chars>" in out, f"{cmd[0]} 没给长度摘要：\n{out[:500]}"
PY
ok "a hostname-shaped provider id is masked on every output face"

# 107. 标量路径（规则的 use）不得把「换了模型」说成「只换了通道」：措辞与 members 路径同义。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
A = "a" * 20
B = "b" * 20
prov = {"providers": [{"id": "acme", "models": [A, B]}],
        "groups": [{"id": "g1", "routing": "order",
                    "members": [f"acme/{A}", f"acme/{B}"],
                    "rules": [{"use": f"acme/{A}"}]}]}
pf = tmp / "r107-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r107-draft.json"
df.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                      "members": [f"acme/{A}", f"acme/{B}"],
                                      "rules": [{"use": f"acme/{B}"}]}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, out[:500]
assert "the reference itself was replaced" in out, \
    f"换了模型却没说是换了模型：\n{out[:600]}"
assert "differ only inside a masked segment" not in out, \
    f"换了模型却被说成「只换了通道」：\n{out[:600]}"
PY
ok "a swapped model is never reported as a channel-only change"

# 108. 检测侧必须与回显侧同口径：控制字符不能切断凭据形态（换行切断的凭据仍要整组降级）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
# 凭据前缀用字符码在运行时拼出来：源码里不留任何凭据形态的字面量（扫不到 ≠ 没写）
prefix = "".join(chr(c) for c in (115, 107, 45))
broken = prefix + "t2Qp" * 2 + "\n" + "w9Ks" * 2   # 换行把一条连续形态切成两段
# 存量组不经校验：切断形态的串放进存量组的成员里（草案侧是干净配置，合并结果也干净）
prov = {"providers": [{"id": "acme", "models": ["m", "m2"]}],
        "groups": [{"id": "g1", "routing": "order", "members": ["acme/m", broken]}]}
pf = tmp / "r108-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r108-draft.json"
df.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                      "members": ["acme/m2"]}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "sk-" not in out, f"换行切断的凭据形态原样进了输出：\n{out[:500]}"
# 整组降级（echo=False）时成员给自由文本形态 `<text N chars>`；没降级时走逐串 shield，
# 给的是 `<ref N chars>`——两者形态不同，正好把「检测侧有没有剥控制字符」区分出来。
assert "<text 20 chars>" in out, \
    f"换行切断的凭据形态没触发整组降级（检测侧没剥控制字符）：\n{out[:500]}"
PY
ok "the detection side cannot be bypassed by a control character"

# 109. render 的警告要说清还剩几条：只列 3 条却不提「还有更多」，读者会把 3 条当成全部。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
groups = [{"id": f"g{i}", "routing": "order", "members": ["<role:r>"],
           "note": "z" * 18 + str(i)} for i in range(6)]
tf = tmp / "r109-tpl.json"; tf.write_text(json.dumps({"groups": groups}))
mf = tmp / "r109-map.json"; mf.write_text(json.dumps({"r": ["acme/m1"]}))
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf)],
                   capture_output=True, text=True)
err = r.stderr
assert "more location(s) not listed" in err, \
    f"警告只列了 3 条却没说还剩几条：\n{err[:400]}"
PY
ok "render says how many suspicious locations it did not list"


# 110. provider 段的掩码不能只在「model 段很短」时生效：model 段点分或高熵时会先走
#      `_redact_model`，那条路径原先不管 provider 段——同一个 provider 在两种 model 段下
#      一边被掩一边原样，同一张表在同一张输出面里自相矛盾。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
HOST = "llm.internal"
for model in ("model.v2.pro", "a" * 20):
    bad = {"providers": [{"id": "acme", "models": ["m"]}],
           "groups": [{"id": "g1", "routing": "order",
                       "members": [f"{HOST}/{model}"]}]}
    f = tmp / "r110.json"; f.write_text(json.dumps(bad))
    known = tmp / "r110-known.json"; known.write_text(json.dumps(["m"]))
    r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(f), str(known)],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert HOST not in out, f"model 段为 {model[:12]}… 时 provider 段原样回显了：\n{out[:400]}"
    assert "<ref 12 chars>" in out, f"没给长度摘要：\n{out[:400]}"
# 不含点的 provider 标识符照旧可读（否则报错没法读）
ok2 = {"providers": [{"id": "acme", "models": ["m"]}],
       "groups": [{"id": "g1", "routing": "order", "members": ["acme/nope"]}]}
f = tmp / "r110-ok.json"; f.write_text(json.dumps(ok2))
known = tmp / "r110-known.json"; known.write_text(json.dumps(["m"]))
r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(f), str(known)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "acme/nope" in out, f"不含点的 provider 标识符被无脑掩掉：\n{out[:400]}"
PY
ok "the provider id is masked no matter what the model segment looks like"

# 111. `more` 列表与成员列表共用三态判据，而且**每个桶都要披露**：用 if/elif 只报第一个桶，
#      会把「分不清」的那部分整个吞掉——同一批改动放进 members 时三句都在。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
A, B, C = "a" * 20, "b" * 20, "c" * 20
D, E = "d" * 20, "e" * 20
# 账号段一律 13 位连续 alnum：短标签（`#team-a`）按判据**不掩**，掩后形态两侧就不同、配不成对，
# 那一桶会整个从输出里消失——那不是「没披露」，是夹具根本没造出这一桶。
AC = [c * 12 + str(i) for i, c in enumerate("wxyz")]
members = [f"acme/{A}", f"acme/{B}", f"acme/{C}", f"acme/{D}", f"acme/{E}",
           f"acme/{A}#{AC[0]}", f"acme/{A}#{AC[1]}",
           f"acme/{D}#{AC[2]}", f"acme/{E}#{AC[3]}"]
# 三桶各一条（两侧掩完同形，位置一一对应）：
#   acme/B → acme/C        核心变、两侧都没有账号段        → model
#   acme/D#w… → acme/E#y…  核心变**且**账号段也不同        → unsure（这才真的分不清）
#   acme/A#w… → acme/A#x…  核心没变、只换账号段            → chan
prov = {"providers": [{"id": "acme", "models": [A, B, C, D, E]}],
        "groups": [{"id": "g1", "routing": "order", "members": members,
                    "rules": [{"use": f"acme/{A}",
                               "more": [f"acme/{B}", f"acme/{D}#{AC[2]}", f"acme/{A}#{AC[0]}"]}]}]}
pf = tmp / "r111-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r111-draft.json"
df.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": members,
                                      "rules": [{"use": f"acme/{A}",
                                                 "more": [f"acme/{C}", f"acme/{E}#{AC[3]}",
                                                          f"acme/{A}#{AC[1]}"]}]}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode == 0, out[:500]
mline = next((l for l in out.splitlines() if ".more:" in l), "")
assert mline, f"more 行没打出来：\n{out[:500]}"
assert "1 entry/entries: the reference itself was replaced" in mline, \
    f"换模型的那一条没披露：\n{mline[:300]}"
assert "1 entry/entries: the model and the channel cannot be told apart" in mline, \
    f"分不清的那一条被吞掉了（只报了第一个桶）：\n{mline[:300]}"
assert "1 entry/entries differ only inside a masked segment" in mline, \
    f"只换通道的那一条被吞掉了：\n{mline[:300]}"
PY
ok "every change kind in a 'more' list is disclosed, not just the first"

# 112. 两段主机形态（`llm.internal`）也要进 render 的警告：三段形态在 ENDPOINT_SHAPE 里，
#      两段不在——但两段的内网网关名同样是拓扑信息，产物原样含它却一声不吭不行。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
groups = [{"id": "g1", "routing": "order", "members": ["<role:r>"],
           "note": "llm.internal"}]
tf = tmp / "r112-tpl.json"; tf.write_text(json.dumps({"groups": groups}))
mf = tmp / "r112-map.json"; mf.write_text(json.dumps({"r": ["acme/m1"]}))
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf)],
                   capture_output=True, text=True)
assert "look like a token or a host" in r.stderr, \
    f"两段主机形态没进警告：\n{r.stderr[:400]}"
PY
ok "render warns about a two-part hostname shape too"


# 113. 自由文本里写着模型引用时，措辞仍按**自由文本**走：三态表只属于「这一面真的按段掩过」。
#      判据必须看本面的 echo，不能只看值的形态——note 里贴一条模型引用太常见了。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = [{"id": "acme", "models": ["m"]}]
def run(old_note, new_note, tag):
    assert len(old_note) == len(new_note), "夹具两侧不等长，掩完不会同形"
    cur = {"providers": prov, "groups": [{"id": "g1", "routing": "order",
                                          "members": ["acme/m:high"], "note": old_note}]}
    f = tmp / f"r113-{tag}.json"; f.write_text(json.dumps(cur, ensure_ascii=False))
    d = tmp / f"r113-d{tag}.json"
    d.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                         "members": ["acme/m:high"], "note": new_note}]},
                            ensure_ascii=False))
    r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(f)],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    line = next((l for l in out.splitlines() if l.strip().startswith("note:")), "")
    assert line, f"note 的改动没进 diff：\n{out[:400]}"
    assert "withheld" in line, f"整条扣下的自由文本没说「值被扣下」：\n{line}"
    for bad in ("masked segment", "reference itself was replaced", "cannot be told apart"):
        assert bad not in line, f"自由文本被说成了模型引用/被掩那段（{bad}）：\n{line}"
run("route acme/m:high#team-a", "route acme/m:high#team-b", "chan")
run("swap acme/aaaa:high#team-a", "swap acme/bbbb:high#team-a", "model")
# 反向：echo 面（pick 是成员引用字段）真的按段掩时，三态措辞必须还在——
# 否则这条修复就成了「把三态全关掉」的假绿。
# 账号段必须 >=12 位连续 alnum 才会被按段掩（阈值 12），且两侧等长——否则掩完就不同形，
# 差异本来就该显示出来，测不到三态措辞。
same = "acme/aaaaaaaaaaaaaaaaaaaa#" + "aQ3t" * 3
moved = "acme/aaaaaaaaaaaaaaaaaaaa#" + "bR4u" * 3
cur = {"providers": [{"id": "acme", "models": ["a" * 20]}],
       "groups": [{"id": "g1", "routing": "usage", "members": [same], "pick": same}]}
f = tmp / "r113-echo.json"; f.write_text(json.dumps(cur, ensure_ascii=False))
d = tmp / "r113-decho.json"
d.write_text(json.dumps({"groups": [{"id": "g1", "routing": "usage",
                                     "members": [moved], "pick": moved}]}, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(f)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "differ only inside a masked segment" in out, \
    f"echo 面上按段掩的改动不再有三态措辞（修过头了）：\n{out[:500]}"
PY
ok "free text that happens to contain a model ref is described as free text"

# 114. `intent` 是自由文本，两侧都只给形态。「草案侧已过校验」不是回显理由：
#      校验只拒已知前缀的凭据，两段内网主机名与连字符分隔的长 token 都能过校验。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
HOSTISH = "route-via-gw.internal"      # 两段主机形态，schema 合法、校验放行
LONGTOK = "a1b2-c3d4-e5f6-g7h8-i9j0-k1l2-m3n4"   # 连字符分隔，熵判据刻意不认
for val in (HOSTISH, LONGTOK):
    prov = {"providers": [{"id": "acme", "models": ["m", "judge"]}],
            "groups": [{"id": "g1", "routing": "order", "members": ["acme/m:high"],
                        "classifier": "acme/judge",
                        "rules": [{"use": "acme/m:high", "intent": "some-earlier-value"}]}]}
    f = tmp / "r114-prov.json"; f.write_text(json.dumps(prov, ensure_ascii=False))
    d = tmp / "r114-draft.json"
    d.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order",
                                         "members": ["acme/m:high"], "classifier": "acme/judge",
                                         "rules": [{"use": "acme/m:high", "intent": val}]}]},
                            ensure_ascii=False))
    r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(f)],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert val not in out, f"intent 的草案侧原样回显了 {len(val)} 位的串：\n{out[:400]}"
    line = next((l for l in out.splitlines() if ".intent:" in l), "")
    assert "<text" in line, f"intent 没按自由文本给形态：\n{line}"
PY
ok "a rule's intent text is withheld on both sides"

# 115. 校验器对畸形 `levels` 要**出判决而不是抛异常**：崩了以后 doctor 会整段抑制形状诊断，
#      apply 也只能回「这是崩溃报告」，使用者拿不到任何可行动结论。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
known = tmp / "r115-known.json"; known.write_text(json.dumps(["m"]))
for i, bad in enumerate(([], {}, [["high"]], [{"a": 1}], ["high", []], [None], [1])):
    doc = {"groups": [{"id": "g1", "routing": "order", "members": ["acme/m:high"],
                       "levels": [bad]}]}
    f = tmp / f"r115-{i}.json"; f.write_text(json.dumps(doc))
    r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(f), str(known)],
                       capture_output=True, text=True)
    assert "Traceback" not in r.stderr, f"levels={[bad]!r} 让校验器抛异常了：\n{r.stderr[-300:]}"
    assert "levels" in (r.stdout + r.stderr), f"levels={[bad]!r} 没出判决：\n{r.stdout[:200]}"
# 一个**未被替换**的存量组里有坏 levels 时，doctor 的形状段不能整段失明
prov = {"providers": [{"id": "acme", "models": ["m"]}],
        "groups": [{"id": "g-old", "routing": "order", "members": ["acme/m:high"],
                    "levels": [[]]},
                   {"id": "g-solo", "routing": "order", "members": ["acme/m:high"]}]}
f = tmp / "r115-doctor.json"; f.write_text(json.dumps(prov))
r = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "CRASHED" not in out, f"坏 levels 让 doctor 判校验器崩了：\n{out[-400:]}"
assert "single member" in out, f"形状段被抑制了（单成员那条判据该还在）：\n{out[-500:]}"
PY
ok "a malformed levels list yields a verdict, not a crash"

# 116. validate.py **在但载不进**（半成品拷贝、语法坏）时，doctor 的 validation 段要明说
#      「没跑」——它与「文件缺失」是两种故障，但都不能留下一个空段让人读成「没查出问题」。
python3 -I - "$TMP" <<'PY'
import json, shutil, subprocess, sys, tempfile
from pathlib import Path
tmp = Path(sys.argv[1])
work = Path(tempfile.mkdtemp())
shutil.copy("scripts/doctor.py", work / "doctor.py")
(work / "validate.py").write_text("def broken(:\n")        # 语法坏的 validate.py
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = json.loads(Path("examples/demo/output.groups.json").read_text())["groups"]
f = work / "p.json"; f.write_text(json.dumps(base, ensure_ascii=False))
r = subprocess.run([sys.executable, "-I", str(work / "doctor.py"), str(f)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "not run" in out, f"载不进的 validate.py 没被说破（空段会被读成「没查出问题」）：\n{out[:400]}"
assert "present but not loadable" in out, f"没说清是「在但载不进」：\n{out[:400]}"
PY
ok "a validate.py that exists but cannot be loaded says 'validation not run'"

# 117. 拒绝写盘的**每个**分支都要提醒「目标路径上还有上一次的陈旧文件」；
#      而「它们会原样打出来」这句警告不得出现在一次什么都没打的运行里。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tpl = {"groups": [{"id": "g1", "routing": "order", "members": ["<role:r>"],
                   "context": float("inf")}]}
tf = tmp / "r117-tpl.json"; tf.write_text(json.dumps(tpl))
mf = tmp / "r117-map.json"; mf.write_text(json.dumps({"r": ["acme/m1"]}))
of = tmp / "r117-out.json"; of.write_text("STALE")
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf), str(of)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode != 0, "含非有限数的模板竟然成功"
assert "not updated by this one" in out, f"NaN 拒绝分支没提醒目标路径上的陈旧文件：\n{out[:300]}"
assert of.read_text() == "STALE", "陈旧文件被改了"
assert "printed as-is" not in out, \
    f"一次什么都没打的运行里却打了「会原样打出来」：\n{out[:300]}"
PY
ok "every refusal branch says the old file is still there"

# 118. 「findings 来自存量组」这条指引只属于**不合格**分支：崩溃分支里没有 findings，
#      跟在 traceback 后面打它等于凭空造出一个不存在的对象。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
sys.path.insert(0, str(tmp))
import crashkit        # 崩溃由副本注入（造法见第 75 条上方），不再靠 1200 层深值
kit = crashkit.script_dir(tmp, "r118-kit")
crash = {"providers": [], "groups": [{"id": "g1", "routing": "order", "members": ["acme/x:high"],
          "rules": [{"use": "acme/x:high",
                     "where": [{"field": "tokens", "op": "lt", "value": [[[1]]]}]}]}]}
f = tmp / "r118-crash.json"; f.write_text(json.dumps(crash))
d = tmp / "r118-d.json"
d.write_text(json.dumps({"groups": [{"id": "zz", "routing": "order",
                                     "members": ["acme/x:high"]}]}))
r = subprocess.run([sys.executable, "-I", str(kit / "apply.py"), str(d), str(f)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "boom: injected validator crash" in out, f"夹具没能真的让校验器崩：\n{out[:300]}"
assert "CRASHED" in out, f"夹具没能真的让校验器崩：\n{out[:300]}"
assert "hint: findings" not in out, f"崩溃分支里凭空打了「findings 来自存量组」：\n{out[-400:]}"
# 反向：普通不合格分支必须照打
bad = {"providers": [], "groups": [{"id": "b1", "routing": "order",
                                    "members": ["acme/nope:high"]}]}
f2 = tmp / "r118-bad.json"; f2.write_text(json.dumps(bad))
r2 = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(d), str(f2)],
                    capture_output=True, text=True)
assert "hint: findings" in r2.stdout + r2.stderr, \
    "普通不合格分支把指引也删掉了：\n" + (r2.stdout + r2.stderr)[:300]
PY
ok "the 'existing config' hint belongs to the rejection branch only"

# 119. 可疑形态警告要按**位置**数：同一个串落在 6 处时报「1 个串、1 条位置」等于让
#      另外 5 处根本定位不到。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tok = "zqxj" * 5
groups = [{"id": f"g{i}", "routing": "order", "members": ["<role:r>"],
           "note": tok, "name": tok, "family": tok} for i in range(2)]
tf = tmp / "r119-tpl.json"; tf.write_text(json.dumps({"groups": groups}))
mf = tmp / "r119-map.json"; mf.write_text(json.dumps({"r": ["acme/m1"]}))
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf)],
                   capture_output=True, text=True)
err = r.stderr
assert "6 location(s)" in err, f"没按位置数（同一个串 6 处）：\n{err[:300]}"
assert "more location(s) not listed" in err, f"没说还剩几条：\n{err[:300]}"
PY
ok "suspicious-shape warnings count locations, not deduplicated strings"

# 120. 账号段**逐字相同**而核心被掩时，这是一次确定的换条目，不许说「分不清」：
#      通道没变，差异只可能落在被掩的那一段（provider / 模型 / 档位）。
#      「分不清」只能留给账号段**也不同**的那种。判据在 pair_kind 一处，members 与 more 共用。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
A, B = "a" * 20, "b" * 20
SAME, OTHER = "c" * 13, "d" * 13          # 都会被掩成 <account 13 chars>
def run(more_old, more_new, tag):
    mem_old = [f"acme/{A}#{more_old[0]}"]
    mem_new = [f"acme/{B}#{more_new[0]}"]
    pf = tmp / f"r120-{tag}-prov.json"
    pf.write_text(json.dumps({"providers": [{"id": "acme", "models": [A, B]}],
                              "groups": [{"id": "g1", "routing": "order", "members": mem_old,
                                          "rules": [{"use": mem_old[0], "more": mem_old}]}]}))
    df = tmp / f"r120-{tag}-draft.json"
    df.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": mem_new,
                                          "rules": [{"use": mem_new[0], "more": mem_new}]}]}))
    r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                       capture_output=True, text=True)
    return r.stdout + r.stderr
out = run([SAME], [SAME], "same-acct")     # 核心变、账号段一模一样
assert "the model reference was replaced" in out, \
    f"账号段没变、核心被掩，仍被说成分不清：\n{out[:600]}"
assert "cannot be told apart" not in out, \
    f"通道明明没变，却宣称分不清模型与通道：\n{out[:600]}"
assert B not in out, f"判成换条目时把被掩的新值泄出来了：\n{out[:600]}"
# 反向钉：账号段也不同 → 「分不清」必须还在（不许把这条判据改成「一律算换模型」蒙过去）
out2 = run([SAME], [OTHER], "diff-acct")
assert "cannot be told apart" in out2, \
    f"账号段也不同时不再说分不清（判据被改成一边倒）：\n{out2[:600]}"
assert "the model reference was replaced" not in out2, \
    f"同一行里既说分不清又说换模型：\n{out2[:600]}"
PY
ok "an identical account segment with a masked core is a definite entry change, not ambiguity"

# 121. 整组降级（echo=False）碰上 `more` 等长改动：**不能 KeyError 崩溃**。
#      三态桶在那一面一句都不该说，但实现不能靠「取一个空桶再去按 key 索引」——
#      那会让 dry-run 与 --write 一起走不下去，而崩的正是「存量侧不过校验、必须降级」这条路径。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
A, B = "a" * 20, "b" * 20
g_old = {"id": "g1", "routing": "order", "members": ["acme/m:high"], "classifier": "acme/judge",
         "note": "see docs.acme.example.io",                       # 三段点分 → 整组降级
         "rules": [{"use": "acme/m:high", "more": [f"acme/m:high#{A}"]}]}
g_new = dict(g_old, note="plain note",
             rules=[{"use": "acme/m:high", "more": [f"acme/m:high#" + B]}])
pf = tmp / "r121-prov.json"; pf.write_text(json.dumps(
    {"providers": [{"id": "acme", "models": ["m", "judge"]}], "groups": [g_old]}))
df = tmp / "r121-draft.json"; df.write_text(json.dumps({"groups": [g_new]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "Traceback" not in out and "KeyError" not in out, f"整组降级 + more 崩了：\n{out[-500:]}"
line = next((l for l in out.splitlines() if ".more:" in l), "")
assert "the values are withheld; the two differ" in line, \
    f"降级面上没说「值被扣下、两侧确实不同」：\n{line}"
for bad in ("cannot be told apart", "masked segment", "reference itself was replaced"):
    assert bad not in line, f"降级面上冒出三态措辞（{bad}）：\n{line}"
# 反向钉：echo 面上的 chan 桶必须还在（防止「把桶全关掉」冒充修好）
pf2 = tmp / "r121b-prov.json"; pf2.write_text(json.dumps(
    {"providers": [{"id": "acme", "models": ["m"]}],
     "groups": [{"id": "g1", "routing": "order", "members": ["acme/m:high"],
                 "rules": [{"use": "acme/m:high", "more": [f"acme/m:high#{A}"]}]}]}))
df2 = tmp / "r121b-draft.json"; df2.write_text(json.dumps(
    {"groups": [{"id": "g1", "routing": "order", "members": ["acme/m:high"],
                 "rules": [{"use": "acme/m:high", "more": [f"acme/m:high#" + B]}]}]}))
r2 = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df2), str(pf2)],
                    capture_output=True, text=True)
out2 = r2.stdout + r2.stderr
assert "differ only inside a masked segment" in out2, \
    f"echo 面上的 chan 桶被顺手关掉了：\n{out2[:500]}"
PY
ok "a downgraded group with an equal-length 'more' change yields a plan, not a KeyError"

# 122. 规则的 `intent` 与 `note` 同属「整条被扣下的自由文本」：等长改动必须带上同一句披露。
#      少那一句，`<text 6 chars> → <text 6 chars>` 读起来就是「没改」——而 intent 是意图分发的判据。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
def group(intent, note):
    return {"id": "g1", "routing": "order", "members": ["acme/m:high"], "classifier": "acme/judge",
            "note": note, "rules": [{"use": "acme/m:high", "intent": intent}]}
pf = tmp / "r122-prov.json"; pf.write_text(json.dumps(
    {"providers": [{"id": "acme", "models": ["m", "judge"]}], "groups": [group("old-v1", "AAAAAAAAAAAAA")]}))
df = tmp / "r122-draft.json"; df.write_text(json.dumps(
    {"groups": [group("new-v2", "BBBBBBBBBBBBB")]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
iline = next((l for l in out.splitlines() if ".intent:" in l), "")
nline = next((l for l in out.splitlines() if l.strip().startswith("note:")), "")
assert "withheld" in iline and "differ" in iline, f"intent 的等长改动没说「值被扣下、两侧不同」：\n{iline}"
assert ("withheld" in nline) == ("withheld" in iline), \
    f"同一份改动落在 note 与 intent 上说法不同：\nnote: {nline}\nintent: {iline}"
assert "old-v1" not in out and "new-v2" not in out, f"intent 被原样回显：\n{out[:400]}"
# 反向钉：不等长时两侧长度本来就不同，不许硬塞那句披露
df2 = tmp / "r122b-draft.json"; df2.write_text(json.dumps(
    {"groups": [group("longer-new-value", "BBBBBBBBBBBBB")]}))
out2 = "".join(subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df2), str(pf)],
                              capture_output=True, text=True).stdout for _ in [0])
line2 = next((l for l in out2.splitlines() if ".intent:" in l), "")
assert "<text 16 chars>" in line2 and "withheld" not in line2, \
    f"不等长时只该给形态：\n{line2}"
PY
ok "an equal-length intent change carries the same withheld-value disclosure as note"

# 123. 校验器**跑得起来却什么都没打**（rc=0、stdout 全空）是第三种状态：不是合格，也不是崩溃。
#      validate 的每个出口都必打印判决，所以这条判据可靠；判据住在 validate.no_verdict（单真源）。
python3 -I - "$TMP" <<'PY'
import json, shutil, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
work = tmp / "r123-repo"; (work / "scripts").mkdir(parents=True, exist_ok=True)
src = Path("scripts/validate.py").read_text()
(work / "scripts/validate.py").write_text(src[:src.index("def main(")])   # 截断，但仍能 import
for f in ("apply.py", "doctor.py"):
    shutil.copy(f"scripts/{f}", work / "scripts" / f)
prov = {"providers": [{"id": "acme", "models": ["m", "judge"]}],
        "groups": [{"id": "keep", "routing": "order", "members": ["acme/m:high"]}]}
pf = work / "p.json"; pf.write_text(json.dumps(prov))
target = work / "t.json"; target.write_text(json.dumps(prov))
df = work / "d.json"; df.write_text(json.dumps({"groups": [{"id": "gz", "routing": "order",
                                                            "members": ["acme/nope:high"]}]}))
before = target.read_text()
r = subprocess.run([sys.executable, "-I", str(work / "scripts/apply.py"), str(df), str(target),
                    "--write"], capture_output=True, text=True)
out = r.stdout + r.stderr
assert "no verdict" in out, f"没跑出判决却被当成通过：\n{out[:500]}"
assert "validation PASS" not in out, f"宣布 PASS：\n{out[:500]}"
assert "would not pass validation" not in out, \
    f"掉进「你的配置不合格」那句假结论：\n{out[:400]}"
assert target.read_text() == before, "校验没跑出判决却把文件写了"
assert not list(work.glob("t.json.bak*")), "留下了孤儿备份"
r2 = subprocess.run([sys.executable, "-I", str(work / "scripts/doctor.py"), str(pf)],
                    capture_output=True, text=True)
lines = r2.stdout.splitlines()
i = lines.index("validation:") if "validation:" in lines else -1
assert i >= 0 and "not run" in lines[i + 1], \
    f"doctor 的 validation 段留了个空行（会被读成没查出问题）：\n{chr(10).join(lines[i:i+3])}"
# 反向钉：真校验器照旧打印 PASS（防止把判据改成「一律说 not run」）
r3 = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(pf)],
                    capture_output=True, text=True)
assert "PASS: 1 group(s) valid" in r3.stdout, f"真校验器的 PASS 没了：\n{r3.stdout[:300]}"
PY
ok "a validator that exits 0 without a verdict is refused, not reported as a pass"

# 124. 产物编不成 UTF-8 时**一个字节都不碰**目标路径（write_text 先截断再写，会顺手清掉上次的产物）；
#      「它们会原样打出来」的警告只在真的产出了东西之后才打；每条拒绝分支都提陈旧文件。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tok = "zqxj" * 5
tf = tmp / "r124-tpl.json"
tf.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": ["<role:r>"],
                                      "note": tok, "name": "x" + chr(0xD800)}]}))
mf = tmp / "r124-map.json"; mf.write_text(json.dumps({"r": ["acme/m1"]}))
of = tmp / "r124-out.json"; of.write_text("Y" * 200)
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf), str(of)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "Traceback" not in out, f"编码失败只剩 traceback：\n{out[-400:]}"
assert "cannot be written as UTF-8" in out, f"没有可读 FAIL：\n{out[-300:]}"
assert of.stat().st_size == 200, f"上一次的产物被清成 {of.stat().st_size} 字节"
assert "not updated by this one" in out, f"没说目标路径上还留着陈旧产物：\n{out[-300:]}"
assert "printed as-is" not in out, "一次什么都没产出的运行里却打了「会原样打出来」"
# 写盘失败分支同样要提陈旧文件。**夹具用只读目录，不用只读文件**：落盘是原子的（同目录临时文件
# + rename），只读的目标文件挡不住它——目录可写就能把它换掉。拿 `chmod 0444` 的文件当
# 「写不进去」的夹具，在原子写面前根本不触发失败，那条断言会静默变成空跑。
rod = tmp / "r124-rodir"; rod.mkdir(exist_ok=True); rod.chmod(0o700)   # 上一次运行可能留下只读目录
ro = rod / "out.json"; ro.write_text("STALE"); rod.chmod(0o500)
import atexit
# 断言中途失败时也要把目录解锁，否则 e2e 的 trap 删不掉这堆临时目录（探针会反复复用同一个 $TMP）
atexit.register(lambda: rod.chmod(0o700))
tf2 = tmp / "r124-tpl2.json"; tf2.write_text(json.dumps(
    {"groups": [{"id": "g1", "routing": "order", "members": ["<role:r>"], "name": "zzzz"}]}))
r2 = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf2), str(mf), str(ro)],
                    capture_output=True, text=True)
assert "not updated by this one" in r2.stdout + r2.stderr, \
    f"写盘失败分支没提陈旧文件：\n{(r2.stdout + r2.stderr)[:300]}"
rod.chmod(0o700)
assert ro.read_text() == "STALE", f"写失败后目标文件不是完整的旧内容：{ro.read_text()[:80]!r}"
# 原子写的另一半：失败时**不留残片**。残片同样是垃圾，而且名字看着像产物的一半
debris = [p.name for p in rod.iterdir() if p.name != "out.json"]
assert not debris, f"写失败后目录里留下半份产物：{debris}"
# 反向钉：真产出了就得警告（按位置数），且写盘成功也有
tf3 = tmp / "r124-tpl3.json"; tf3.write_text(json.dumps(
    {"groups": [{"id": f"g{i}", "routing": "order", "members": ["<role:r>"],
                 "note": tok, "name": tok, "family": tok} for i in range(2)]}))
(tmp / "r124-map3.json").write_text(json.dumps({"r": ["acme/m1"]}))
r3 = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf3),
                     str(tmp / "r124-map3.json"), str(tmp / "r124-out3.json")],
                    capture_output=True, text=True)
assert r3.returncode == 0 and "6 location(s)" in r3.stderr, \
    f"写盘成功时的按位置警告没了：\n{r3.stderr[:300]}"
PY
ok "render never truncates the target and only warns once it really produces a product"

# 125. 「合法 JSON、但 UTF-8 存不下」的字符（孤立代理对）：校验器**指到位置出判决**，
#      apply / doctor 都不得在写临时文件时抛 traceback（那连判决都没开始）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
prov = {"providers": [{"id": "acme", "models": ["m"]}],
        "groups": [{"id": "g1", "routing": "order", "members": ["acme/m:high"], "note": "old"}]}
pf = tmp / "r125-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r125-draft.json"
df.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": ["acme/m:high"],
                                      "note": "new " + chr(0xD800)}]}))   # 转义写法，运行时才解出代理对
before = pf.read_text()
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf), "--write"],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "Traceback" not in out, f"判决还没开始就崩了：\n{out[-400:]}"
assert "cannot be stored as UTF-8" in out, f"没有指到位置的判决：\n{out[-400:]}"
assert "groups[0].note" in out, f"判决没说落在哪：\n{out[-400:]}"
assert pf.read_text() == before, "被拒的草案被写进了目标"
assert not list(tmp.glob("r125-prov.json.bak*")), "留下了孤儿备份"
pf2 = tmp / "r125-live.json"
pf2.write_text(json.dumps({"providers": prov["providers"],
                           "groups": [{"id": "g1", "routing": "order", "members": ["acme/m:high"],
                                       "note": "x " + chr(0xD800)}]}))
r2 = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(pf2)],
                    capture_output=True, text=True)
assert "Traceback" not in r2.stderr, f"doctor 被同一类输入打崩：\n{r2.stderr[-300:]}"
assert "cannot be stored as UTF-8" in r2.stdout, f"doctor 的 validate 段没这条判决：\n{r2.stdout[:400]}"
PY
ok "a character that cannot be stored as UTF-8 gets a located verdict, not a traceback"


# 126. 「没跑出判决」不能只看退出码：被信号杀死（OOM、SIGKILL）的校验器退出码是**负的**，
#      「rc==0 且输出为空」这条判据在最该报警的场合先放行——apply 会照着「不合格」的分支走，
#      doctor 则在 validation 段留一个空行，配上下面的 none 读起来像体检合格。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
sys.path.insert(0, str(tmp))
import crashkit
kit = crashkit.script_dir(tmp, "r126-kit", crashkit.KILL)   # main 一进去就 SIGKILL 自己
prov = {"providers": [{"id": "acme", "models": ["m"]}],
        "groups": [{"id": "keep", "routing": "order", "members": ["acme/m:high"]}]}
pf = tmp / "r126-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r126-d.json"; df.write_text(json.dumps(
    {"groups": [{"id": "gz", "routing": "order", "members": ["acme/m:high"]}]}))
before = pf.read_text()
r = subprocess.run([sys.executable, "-I", str(kit / "apply.py"), str(df), str(pf), "--write"],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode != 0, "校验器被杀死了，apply 还当没事发生"
assert "produced no verdict" in out, f"没判决被当成合格或不合格：\n{out[:400]}"
assert "would not pass validation" not in out, f"掉进「你的配置不合格」：\n{out[:300]}"
assert "validation PASS" not in out, "没判决还宣布 PASS"
assert pf.read_text() == before, "没判决还写盘了"
assert not list(tmp.glob("r126-prov.json.bak*")), "留下了孤儿备份"
rd = subprocess.run([sys.executable, "-I", str(kit / "doctor.py"), str(pf)],
                    capture_output=True, text=True)
lines = rd.stdout.splitlines()
i = lines.index("validation:")
assert lines[i + 1].strip(), f"validation 段还是空行（读起来像没查出问题）：\n{chr(10).join(lines[i:i+3])}"
assert "not run" in lines[i + 1], f"没说校验没跑成：\n{lines[i+1]}"
# 反向钉：正常判决时不许出现「没判决」措辞
rn = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(pf)], capture_output=True, text=True)
assert "not run" not in rn.stdout.split("validation:")[1].split("shape findings:")[0], \
    f"跑成了还报「没跑」：\n{rn.stdout[:400]}"
PY
ok "a validator killed by a signal is reported as no-verdict, not as a pass or a fail"

# 127. classifier 指向的组链**嵌 1200 层**也要出判决：解析 classifier 模型集合的那段是递归的，
#      深链上会 RecursionError——那是崩溃不是结论，「classifier 只能判意图」这条守卫对深链
#      根本不生效，而 apply 会把这次失败算成「你的配置不合格」。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
n = 1200
gs = [{"id": "top", "routing": "order", "members": ["acme/m:high"], "classifier": "group/k0"}]
gs += [{"id": f"k{i}", "routing": "order",
        "members": ([f"group/k{i + 1}"] if i < n else ["acme/m:high"])} for i in range(n + 1)]
f = tmp / "r127-chain.json"; f.write_text(json.dumps({"groups": gs}))
r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(f)], capture_output=True, text=True)
out = r.stdout + r.stderr
assert "Traceback" not in out and "RecursionError" not in out, \
    f"深 classifier 链让校验器崩了：\n{out[:300]}"
assert "nesting depth" in out, f"没拿到「太深了」的判决（守卫没跑完）：\n{out[:300]}"
# 反向钉：浅链（同形状、3 层）不该报深度，说明上面那条不是「一律说太深」
shallow = gs[:4] + [{"id": "k3", "routing": "order", "members": ["acme/m:high"]}]
fs = tmp / "r127-shallow.json"; fs.write_text(json.dumps({"groups": shallow}))
rs = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(fs)], capture_output=True, text=True)
assert "nesting depth" not in rs.stdout + rs.stderr, \
    f"3 层链被判成太深：\n{(rs.stdout + rs.stderr)[:300]}"
PY
ok "a 1200-deep classifier group chain gets a verdict instead of a recursion crash"

# 128. `where` 的 value 嵌 1000 层同样只该出判决（自由值没有结构上限，MAX_DEPTH 管不到它）；
#      并且改成显式栈以后，**报错顺序必须仍是文档顺序**——坐标和顺序都是使用者对着 JSON 找问题的依据。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
deep = []
for _ in range(1000):
    deep = [deep]
cfg = {"groups": [
    {"id": "g1", "routing": "order", "members": ["acme/m:high"],
     "rules": [{"use": "acme/m:high",
                "where": [{"field": "tokens", "op": "lt", "value": deep}]}]}]}
f = tmp / "r128-deep.json"; f.write_text(json.dumps(cfg))
k128 = tmp / "r128-known.json"; k128.write_text(json.dumps(["acme/m"]))
r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(f), str(k128)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "Traceback" not in out and "RecursionError" not in out, \
    f"1000 层自由值让校验器崩了：\n{out[:300]}"
assert out.startswith("PASS:") or out.startswith("FAIL:"), f"没有判决：\n{out[:300]}"
# 顺序钉：同一条值链里先出现的坏值先报（`a` 在 `b` 前面）
cfg2 = {"groups": [
    {"id": "g1", "routing": "order", "members": ["acme/m:high"],
     "weights": {"a": ["<role:oops>"], "b": ["<role:oops2>"]}}]}
f2 = tmp / "r128-order.json"; f2.write_text(json.dumps(cfg2))
r2 = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(f2)],
                    capture_output=True, text=True)
la = [i for i, l in enumerate(r2.stdout.splitlines()) if "groups[0].weights.a" in l]
lb = [i for i, l in enumerate(r2.stdout.splitlines()) if "groups[0].weights.b" in l]
assert la and lb and la[0] < lb[0], \
    f"显式栈把报错顺序打乱了（文档顺序应 a 在前）：\n{r2.stdout[:400]}"
PY
ok "a 1000-deep free value gets a verdict, and findings stay in document order"

# 129. 写前重读目标文件时，**解码失败**也是失败：只接 OSError 会让 apply 在校验已过后甩
#      UnicodeDecodeError traceback，使用者不知道配置到底动没动。
python3 -I - "$TMP" <<'PY'
import contextlib, importlib.util, io, json, pathlib, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tgt = tmp / "r129-target.json"
prov = {"providers": [{"id": "acme", "models": ["m"]}],
        "groups": [{"id": "keep", "routing": "order", "members": ["acme/m:high"]}]}
tgt.write_text(json.dumps(prov))
df = tmp / "r129-d.json"; df.write_text(json.dumps(
    {"groups": [{"id": "gz", "routing": "order", "members": ["acme/m:high"]}]}))
real, seen = pathlib.Path.read_text, []
def patched(self, *a, **k):
    hit = str(self) == str(tgt)
    seen.append(hit)
    if hit and seen.count(True) == 2:      # 第 2 次读目标 = 写前重读那一次
        raise __import__("builtins").UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte")
    return real(self, *a, **k)
pathlib.Path.read_text = patched
sys.argv = ["apply.py", str(df), str(tgt), "--write"]
spec = importlib.util.spec_from_file_location("r129apply", "scripts/apply.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        rc = m.main()
except Exception:
    import traceback
    print(traceback.format_exc())
    rc = 99
finally:
    pathlib.Path.read_text = real
out = buf.getvalue()
assert seen.count(True) >= 2, "夹具没打到写前重读那一次，这条等于空跑"
assert rc != 0 and rc != 99, f"要么当成功，要么抛了 traceback：rc={rc}\n{out[:400]}"
assert "cannot re-read" in out, f"没有可读 FAIL：\n{out[:400]}"
assert "Traceback" not in out, f"甩 traceback：\n{out[-300:]}"
assert "Traceback" not in buf.getvalue(), "甩 traceback"
assert tgt.read_text() == json.dumps(prov), "解码失败那次还是动了目标文件"
assert not list(tmp.glob("r129-target.json.bak*")), "留下了孤儿备份"
PY
ok "an undecodable target file at the pre-write re-read gets a readable FAIL, not a traceback"

# 130. 连临时文件都建不出来（磁盘满 / 临时目录不可用）＝校验器根本没开跑：
#      甩 traceback 的场合 stdout 是 0 字节，使用者拿到「什么都没输出」而不是「校验没跑成」。
#      注入而不是设 TMPDIR：`tempfile` 对**不可用的 TMPDIR 会静默回退到 /tmp**（实测设成不存在的
#      目录后照样跑通），那种夹具永远不会走到这条分支。
python3 -I - "$TMP" <<'PY'
import contextlib, importlib.util, io, json, subprocess, sys, tempfile
from pathlib import Path
tmp = Path(sys.argv[1])
prov = {"providers": [{"id": "acme", "models": ["m"]}],
        "groups": [{"id": "keep", "routing": "order", "members": ["acme/m:high"]}]}
pf = tmp / "r130-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r130-d.json"; df.write_text(json.dumps(
    {"groups": [{"id": "gz", "routing": "order", "members": ["acme/m:high"]}]}))
def boom(*a, **k):
    raise OSError(28, "No space left on device (injected)")
tempfile.TemporaryDirectory = boom
def run(script, *args):
    sys.argv = [script] + [str(a) for a in args]
    spec = importlib.util.spec_from_file_location("r130_" + script, "scripts/" + script)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = m.main()
    return rc, buf.getvalue()
before = pf.read_text()
rc, out = run("apply.py", df, pf, "--write")
assert out.strip(), "stdout 一个字节都没有"
assert "Traceback" not in out, f"只剩 traceback：\n{out[-400:]}"
assert "could not run the validator" in out and "injected" in out, f"没说校验没跑成：\n{out[:400]}"
assert "validation PASS" not in out and rc != 0, "没跑成还写盘"
assert pf.read_text() == before, "校验没开跑却改了文件"
assert not list(tmp.glob("r130-prov.json.bak*")), "留下了孤儿备份"
rc2, out2 = run("doctor.py", pf)
assert "could not be started" in out2, f"doctor 那侧只剩 traceback：\n{out2[-400:]}"
PY
# 反向钉：临时目录正常时不许出现这些措辞
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
rn = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(tmp / "r130-d.json"),
                     str(tmp / "r130-prov.json")], capture_output=True, text=True)
assert "could not run the validator" not in rn.stdout + rn.stderr, "跑得成却报跑不成"
assert "could not be started" not in subprocess.run(
    [sys.executable, "-I", "scripts/doctor.py", str(tmp / "r130-prov.json")],
    capture_output=True, text=True).stdout, "doctor 跑得成却报跑不成"
PY
ok "a validator that never starts is reported as not-run, with the reason"

# 131. 「载得进来」不等于「判据齐」：缺函数的 validate 副本会在**跑到一半**才 AttributeError，
#      那时 apply 可能已经写完盘、doctor 的输出停在半句上。启动时按 validate 自带的名字表逐名核。
python3 -I - "$TMP" <<'PY'
import json, shutil, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
work = tmp / "r131-repo"; (work / "scripts").mkdir(parents=True, exist_ok=True)
src = Path("scripts/validate.py").read_text()
assert "def derive_known(" in src, "注入点没了：这条夹具会静默失效"
(work / "scripts/validate.py").write_text(src.replace("def derive_known(", "def _gone_derive_known(", 1))
assert "def derive_known(" not in (work / "scripts/validate.py").read_text(), "注入没落地"
for f in ("apply.py", "doctor.py"):
    shutil.copy(f"scripts/{f}", work / "scripts" / f)
prov = {"providers": [{"id": "acme", "models": ["m"]}],
        "groups": [{"id": "keep", "routing": "order", "members": ["acme/m:high"]}]}
pf = work / "p.json"; pf.write_text(json.dumps(prov))
target = work / "t.json"; target.write_text(json.dumps(prov))
df = work / "d.json"; df.write_text(json.dumps(
    {"groups": [{"id": "gz", "routing": "order", "members": ["acme/m:high"]}]}))
before = target.read_text()
r = subprocess.run([sys.executable, "-I", str(work / "scripts/apply.py"), str(df), str(target),
                    "--write"], capture_output=True, text=True)
out = r.stdout + r.stderr
assert r.returncode != 0 and "is missing derive_known" in out, \
    f"没在启动时停下：\n{out[:400]}"
assert "AttributeError" not in out and "Traceback" not in out, f"甩 AttributeError：\n{out[:400]}"
assert target.read_text() == before, "判据不全还动了目标文件"
assert not list(work.glob("t.json.bak*")), "留下了孤儿备份"
r2 = subprocess.run([sys.executable, "-I", str(work / "scripts/doctor.py"), str(pf)],
                    capture_output=True, text=True)
assert "missing derive_known" in r2.stdout, f"doctor 没说缺哪条判据：\n{r2.stdout[:400]}"
assert "SHAPE SUMMARIES" in r2.stdout, "降级没披露：读者会把形态摘要读成名字"
assert "AttributeError" not in r2.stdout + r2.stderr, "doctor 跑到一半崩了"
PY
ok "a validate copy with a missing judgment stops at startup, naming what is missing"

# 132. 「账号段逐字相同 → 确定换了条目」这条**只在配对可信时用**。两条成员各自换通道时，
#      掩后同形的配对会把它们**交叉**配上（模型段都被掩，账号段是可见短标签，形态跟着账号变），
#      于是打出一条事实为假的「模型引用被换掉」。配不准就是分不清，退回那句分不清。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
# 名字**运行时拼**，不写字面量：21 位连续字母数字与 13 位纯数字都是凭据形态，写成字面量会被
# 运行前的替换层当成占位符填成真值（夹具变形，测的就不是这条判据）。
mq, mr = "Zk9" + "q" * 18, "Zk9" + "r" * 18      # 过熵阈值 → 模型段被掩成 <model 21 chars>
ac1, ac2 = "8" * 13, "9" * 13                    # 账号段过熵阈值（阈值 12）→ 账号段也被掩
prov = {"providers": [{"id": "acme", "models": [mq, mr]}],
        "groups": [{"id": "c", "routing": "order",
                    "members": [f"acme/{mq}:high#cA", f"acme/{mr}:high#cB"]}]}
pf = tmp / "r132-prov.json"; pf.write_text(json.dumps(prov))
# 草案：两个模型**各换通道**（模型没变）。模型段被掩、账号段可见 → 掩后形态交叉相等
df = tmp / "r132-d.json"; df.write_text(json.dumps({"groups": [
    {"id": "c", "routing": "order", "members": [f"acme/{mq}:high#cB", f"acme/{mr}:high#cA"]}]}))
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
assert "cannot be told apart" in out, f"没说分不清：\n{out[:500]}"
assert "the model reference was replaced" not in out, \
    f"配对配错了还断言「模型引用被换掉」（事实为假）：\n{out[:500]}"
# 对照组：账号段本身也被掩（13 位数字，过熵阈值）→ 配对按核心引用配，说「只换了被掩那段」
pf2 = tmp / "r132b-prov.json"; pf2.write_text(json.dumps({
    "providers": prov["providers"],
    "groups": [{"id": "c", "routing": "order",
                "members": [f"acme/{mq}:high#{ac1}", f"acme/{mr}:high#{ac2}"]}]}))
df2 = tmp / "r132b-d.json"; df2.write_text(json.dumps({"groups": [
    {"id": "c", "routing": "order",
     "members": [f"acme/{mq}:high#{ac2}", f"acme/{mr}:high#{ac1}"]}]}))
r2 = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df2), str(pf2)],
                    capture_output=True, text=True)
out2 = r2.stdout + r2.stderr
assert "2 entry/entries changed only inside a masked segment" in out2, \
    f"账号段被掩的同模型换通道没说清：\n{out2[:500]}"
assert "cannot be told apart" not in out2, f"配得准时反而说分不清：\n{out2[:500]}"
PY
ok "a crossed masked pairing falls back to 'cannot be told apart' instead of a false assertion"

# 133. 首位类判据是**组间**判据：只有一组 order 类叶子组时它永远「干净」，而那份干净没有证据含量。
#      不说破，读者会把它当成「锚还在首位」。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
one = {"providers": [{"id": "acme", "models": ["m1", "m2"]}],
       "groups": [{"id": "g1", "routing": "order", "members": ["acme/m1:high", "acme/m2:high"]}]}
f1 = tmp / "r133-one.json"; f1.write_text(json.dumps(one))
r = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f1)], capture_output=True, text=True)
sec = r.stdout.split("shape findings:")[1]
assert "first-member checks: nothing to compare here" in sec, f"单组配置没说首位判据没得比：\n{sec[:500]}"
assert "\n  none\n" not in "\n" + sec, f"没得比还打 none（读起来像查过且干净）：\n{sec[:300]}"
# 对照组：两组 order 类共享成员 → 有得比，披露句不该出现
two = {"providers": one["providers"],
       "groups": [{"id": "g1", "routing": "order", "members": ["acme/m1:high", "acme/m2:high"]},
                  {"id": "g2", "routing": "order", "members": ["acme/m1:high", "acme/m2:low"]}]}
f2 = tmp / "r133-two.json"; f2.write_text(json.dumps(two))
r2 = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f2)], capture_output=True, text=True)
sec2 = r2.stdout.split("shape findings:")[1]
assert "first-member checks: nothing to compare here" not in sec2, \
    f"两组也有得比时还打没得比：\n{sec2[:300]}"
PY
ok "a single order-like group discloses that the first-member checks had nothing to compare"

# 134. 列表两侧的差集用集合而不是 `any(same(...))`：n=1500 时那段是 4.4 秒（每次比较都重新
#      dumps 一整棵子树）。换规范形态进集合以后必须**同义**——± 名单一字不差。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys, time
from pathlib import Path
tmp = Path(sys.argv[1])
n = 1500
old = [f"acme/m{i}:high" for i in range(n)]
new = [m if i not in (7, 500, 1499) else f"acme/other{i}:high" for i, m in enumerate(old)]
new.reverse()          # 同时钉住「换序 + 换条目」的差集不受集合化影响
prov = {"providers": [{"id": "acme", "models": [f"m{i}" for i in range(n)]
                                   + [f"other{i}" for i in (7, 500, 1499)]}],
        "groups": [{"id": "big", "routing": "order", "members": old}]}
pf = tmp / "r134-prov.json"; pf.write_text(json.dumps(prov))
df = tmp / "r134-d.json"; df.write_text(json.dumps({"groups": [
    {"id": "big", "routing": "order", "members": new}]}))
t0 = time.time()
r = subprocess.run([sys.executable, "-I", "scripts/apply.py", str(df), str(pf)],
                   capture_output=True, text=True)
el = time.time() - t0
out = r.stdout + r.stderr
assert el < 10, f"1500 成员的 dry-run 花了 {el:.1f} 秒（差集又退回平方级了？）"
for i in (7, 500, 1499):
    assert f"-acme/m{i}:high" in out and f"+acme/other{i}:high" in out, \
        f"第 {i} 条的 ± 没了：{(out[:400] if i == 7 else '')}"
assert out.count("-acme/m") == 3 and out.count("+acme/other") == 3, \
    f"± 名单多打/少打：\n{out[:600]}"
PY
ok "the member diff stays exact at 1500 entries and stops costing O(n²)"

# 135. 「备份删掉了」与「备份删不掉」是两句话：unlink 失败时打印「no backup was kept」就是
#      把读者手里唯一的好副本报没了。
python3 -I - "$TMP" <<'PY'
import contextlib, importlib.util, io, json, pathlib, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tgt = tmp / "r135-target.json"
prov = {"providers": [{"id": "acme", "models": ["m"]}],
        "groups": [{"id": "keep", "routing": "order", "members": ["acme/m:high"]}]}
if tgt.exists():
    tgt.chmod(0o600)                   # 上一次运行（或某次变异测试）可能留下只读目标
tgt.write_text(json.dumps(prov))
tgt.chmod(0o444)                       # 写不进去 → 走「没动过 → 删备份」那条分支
df = tmp / "r135-d.json"; df.write_text(json.dumps(
    {"groups": [{"id": "gz", "routing": "order", "members": ["acme/m:high"]}]}))
real_unlink = pathlib.Path.unlink
def raising(self, *a, **k):
    raise OSError(1, "Operation not permitted (injected)")
pathlib.Path.unlink = raising
sys.argv = ["apply.py", str(df), str(tgt), "--write"]
spec = importlib.util.spec_from_file_location("r135apply", "scripts/apply.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        rc = m.main()
finally:
    pathlib.Path.unlink = real_unlink
tgt.chmod(0o644)
out = buf.getvalue()
assert rc != 0, "写不进去还回 0"
assert "could not be removed" in out, f"删不掉备份却说「no backup was kept」：\n{out[-500:]}"
baks = list(tmp.glob("r135-target.json.bak*"))
assert baks, "夹具没建出备份，这条等于空跑"
assert str(baks[0]) in out, f"没把留着的备份路径打出来：\n{out[-400:]}"
PY
ok "a backup that could not be removed is reported as still there, with its path"

# 136. 下游提前关掉管道（`| head`）不是渲染失败：默认行为是甩 BrokenPipeError traceback
#      并把退出码变非零——调用方拿 `$?` 判成败，会把一次成功的渲染读成失败。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
# 产物要超过管道缓冲（64K），否则写完了都没人读，EPIPE 不会发生，夹具就是空跑
tpl = {"groups": [{"id": f"g{i}", "routing": "order", "members": ["<role:r>:high"],
                   "note": "n" * 90} for i in range(400)]}
tf = tmp / "r136-tpl.json"; tf.write_text(json.dumps(tpl))
mf = tmp / "r136-map.json"; mf.write_text(json.dumps({"r": ["acme/m1"]}))
pr = subprocess.Popen([sys.executable, "-I", "scripts/render.py", str(tf), str(mf)],
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
pr.stdout.read(40)
pr.stdout.close()                      # 下游收够就关，剩下的写入必然 EPIPE
err = pr.stderr.read().decode()
rc = pr.wait()
assert rc != 0, "管道断了却回 0（惯例是回非零）"
assert "BrokenPipeError" not in err and "Traceback" not in err, f"甩 traceback：\n{err[-400:]}"
assert "stdout was closed by the reader" in err, f"没说清是谁关的管道：\n{err[-400:]}"
assert "render itself succeeded" in err, f"被读断的渲染被说成失败：\n{err[-400:]}"
# 反向钉：写文件（不经管道）时不该出现这句话，且回 0
r2 = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf),
                     str(tmp / "r136-out.json")], capture_output=True, text=True)
assert r2.returncode == 0 and "stdout was closed by the reader" not in r2.stderr, \
    f"写文件的场合也来一句管道披露：\n{(r2.stdout + r2.stderr)[:300]}"
PY
ok "a closed stdout is reported as a closed pipe, not as a broken render"

# 137. 落盘必须**原子**：`write_bytes` 是先截断再写，写到一半失败（单文件大小上限、磁盘满、
#      被打断）就在目标路径上留下半份产物——旧配置读不回来，新配置也解析不出。
#      夹具用 RLIMIT_FSIZE 让写入**在截断之后**失败（实测：截到 2000 字节，Python 抛
#      OSError 27，不会先被信号打死），这正是原子写与截断写的分界。
python3 -I - "$TMP" <<'PY'
import json, resource, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tpl = {"groups": [{"id": f"g{i}", "routing": "order", "members": ["<role:r>:high"],
                   "note": "n" * 90} for i in range(60)]}          # 产物远超 2000 字节
tf = tmp / "r137-tpl.json"; tf.write_text(json.dumps(tpl))
mf = tmp / "r137-map.json"; mf.write_text(json.dumps({"r": ["acme/m1"]}))
out = tmp / "r137-out.json"
old = "O" * 5000
out.write_text(old)
# 变异测试会对同一个 $TMP 反复跑各个块：上一次运行（或某个变异体）留下的残片会让「没有残片」这条假红，
# 所以先看一眼再清掉，清的就是这次运行负责的范围（`.render-*`）
for p in tmp.glob(".render-*"):
    p.chmod(0o600); p.unlink(missing_ok=True)
def cap_fsize():
    resource.setrlimit(resource.RLIMIT_FSIZE, (2000, 2000))
# 限额只加在**子进程**上：driver 自己的 stdout 是 e2e 的日志文件（早就超过 2000 字节），
# 给自己设限会让它的输出整段写不出去，夹具变成「静默失败」而不是测原子写。
r = subprocess.run([sys.executable, "-I", "scripts/render.py", str(tf), str(mf), str(out)],
                   capture_output=True, text=True, preexec_fn=cap_fsize)
text = r.stdout + r.stderr
assert r.returncode != 0, f"写到一半失败却回 0：\n{text[:300]}"
assert "could not write" in text, f"没有可读 FAIL：\n{text[:300]}"
assert "not updated by this one" in text, f"没说目标路径上还是上一次的产物：\n{text[:400]}"
assert out.read_text() == old, \
    f"目标路径上留下半份产物（{len(out.read_text())} 字节，旧的是 {len(old)}）——落盘不原子"
assert not [p.name for p in tmp.iterdir() if p.name.startswith(".render-")], "失败后留了临时残片"
PY
ok "a write that fails halfway leaves the previous product intact (atomic replace)"

# 138. 存量侧的**类型**畸形不得把 dry-run / --write 打崩。列表元素里混进非字符串（手写或别的
#      工具落的盘），合并结果里那个字段的值是**草案侧**的，validate 根本看不见旧值长什么样——
#      所以类型闸只能立在 diff 面上。实测过：存量 `match: [5]` 配草案 `match: ["5"]` →
#      `pair_kind` 里 `"#" not in 5` → TypeError，dry-run 与 --write 都只剩一段 traceback，
#      使用者一行判决都拿不到（这正是「出判决，不抛异常」要防的那一类）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tgt = tmp / "r138-target.json"; dra = tmp / "r138-draft.json"
tgt.write_text(json.dumps({"providers": [{"id": "acme", "models": ["m"]}],
                           "groups": [{"id": "g1", "name": "x", "match": [5],
                                       "members": ["acme/m:high"], "routing": "order"}]}))
dra.write_text(json.dumps({"groups": [{"id": "g1", "name": "x", "match": ["5"],
                                       "members": ["acme/m:high"], "routing": "order"}]}))
for flag in ([], ["--write"]):
    r = subprocess.run([sys.executable, "-I", "scripts/apply.py"] + flag + [str(dra), str(tgt)],
                       capture_output=True, text=True)
    t = r.stdout + r.stderr
    assert "Traceback" not in t, f"{'--write ' if flag else 'dry-run '}被存量侧的类型畸形打崩：\n{t[:400]}"
    assert "match: -5 +5" in t, f"条目变化没打出来（读起来像没改）：\n{t[:400]}"
PY
ok "a non-string element on the existing side yields a verdict, not a traceback"

# 139. dict 的**键**也要过「这条配置存不存得进」与占位判据，不能只过 secret-like。
#      键会原样落进 providers.json（render 的产物、apply 的写入都是）。实测漏判的后果：
#      孤立代理对当键 → `PASS: 1 group(s) valid` → apply --write 走到「写失败」分支，
#      报的是「write failed part-way」而不是「你的键存不进去」；`<role:p>` 当键同样 PASS，
#      未展开的占位符就进了配置（render 只展开成员与 classifier，键永远不会被展开）。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
base = ('{"groups":[{"id":"g1","name":"x","members":["acme/m:high"],"routing":"order",'
        '"rules":[{"use":"acme/m:high","where":[{"field":"tokens","op":"contains","value":%s}]}]}]}')
known = tmp / "r139-known.json"; known.write_text(json.dumps(["acme/m"]))
cases = {}
for name, value in (("ok", '{"plain":"v"}'),
                    # 文件里写 JSON 转义写法，不要在 python 字面量里放代理对（那样连夹具都写不出来）
                    ("surrogate", '{"k\\ud800":"v"}'),
                    ("placeholder", '{"<role:p>":"v"}')):
    f = tmp / f"r139-{name}.json"; f.write_text(base % value)
    r = subprocess.run([sys.executable, "-I", "scripts/validate.py", str(f), str(known)],
                       capture_output=True, text=True)
    cases[name] = (r.returncode, r.stdout + r.stderr)
assert cases["ok"][0] == 0, f"干净输入被拒（判据过宽）：\n{cases['ok'][1][:300]}"
assert cases["surrogate"][0] != 0 and "cannot be stored as UTF-8" in cases["surrogate"][1], \
    f"键里的孤立代理对被判 PASS：\n{cases['surrogate'][1][:300]}"
assert cases["placeholder"][0] != 0 and "unresolved placeholder in a key" in cases["placeholder"][1], \
    f"键里的占位写法被判 PASS：\n{cases['placeholder'][1][:300]}"
PY
ok "dict keys are checked for placeholders and un-storable characters, not just secrets"

# 140. apply 写**活配置**也必须原子（render 已原子，写 providers.json 的这一侧不能例外）：
#      `write_text` 先 O_TRUNC 再写，中途失败（磁盘满 / 单文件大小上限 / 进程被杀）就在活配置的
#      位置留下半份文件，而 apply 的「读回比对 + 写回原文」根本不会跑——跑它的进程已经死了。
#      夹具用**进程内注入**而不是 RLIMIT_FSIZE：apply 在正式写入之前还要把合并结果写进一个临时
#      文件喂校验器，那份临时文件与产物是同一个量级——限额必然先打断校验那一步（实测：报的是
#      `could not run the validator: OSError 27`，根本走不到写盘）。所以这里注入 `os.replace` 失败，
#      并在被打断的那一刻断言两件事：**目标仍是完整的旧内容**、**新内容已经完整地写进临时文件**。
#      这两条就是「原子」与「先截断再写」的分界。
python3 -I - "$TMP" <<'PY'
import contextlib, importlib.util, io, json, os, sys
from pathlib import Path
tmp = Path(sys.argv[1])
tgt = tmp / "r140-target.json"; dra = tmp / "r140-draft.json"
original = {"providers": [{"id": "acme", "models": ["m"]}],
            "groups": [{"id": "g1", "name": "x", "members": ["acme/m:high"], "routing": "order"}]}
tgt.write_text(json.dumps(original, indent=2) + "\n")
dra.write_text(json.dumps({"groups": [{"id": "g1", "name": "x", "members": ["acme/m:high"],
                                       "routing": "order", "note": "n" * 4000}]}))
for p in list(tmp.glob(".apply-*")) + list(tmp.glob("r140-target.json.bak-*")):
    p.chmod(0o600); p.unlink(missing_ok=True)
before = tgt.read_bytes()
observed, real_replace = {}, os.replace
def failing(src, dst):          # os.replace(src=临时文件, dst=目标)——参数名反了就会去读目标
    # 打断的那一刻：旧内容必须在原位，新内容必须在临时文件里完整成型
    observed["target_intact"] = tgt.read_bytes() == before
    text = Path(src).read_text()
    observed["temp_has_new"] = "n" * 4000 in text and "g1" in text
    raise OSError(28, "No space left on device (injected)")
os.replace = failing
sys.argv = ["apply.py", str(dra), str(tgt), "--write"]
spec = importlib.util.spec_from_file_location("r140apply", "scripts/apply.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        rc = m.main()
finally:
    os.replace = real_replace
out = buf.getvalue()
assert observed, "注入没落地：这条等于空跑（正式写入根本没走到 replace）"
assert observed["target_intact"], "replace 那一刻目标已被改动——不是原子落盘"
assert observed["temp_has_new"], "新内容没在临时文件里完整成型（写一半才发现放不下）"
assert rc != 0, f"写到一半失败却回 0：\n{out[-300:]}"
assert "could not write" in out, f"没有可读 FAIL：\n{out[-300:]}"
assert tgt.read_bytes() == before, \
    f"活配置被写成半份（{len(tgt.read_bytes())} 字节，原 {len(before)}）——落盘不原子"
assert not [p.name for p in tmp.iterdir() if p.name.startswith(".apply-")], "失败后留了临时残片"
assert not [p.name for p in tmp.iterdir() if p.name.startswith("r140-target.json.bak-")], \
    "目标原样未动却把孤儿备份留在盘上"
PY
ok "a half-failed write leaves the live config intact (atomic replace, no orphan leftovers)"

# 141. 组行的 routing 列：空串＝`(empty)`，**非字符串**＝`(invalid)`。把畸形值说成「配了但配成空」
#      是一句事实为假的话（它配了，只是配得不成样子）；两种哨兵都在降级面的封闭表里。
python3 -I - "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
def rows(routing_json):
    f = tmp / f"r141-{routing_json.strip('[]\" ') or 'empty'}.json"
    f.write_text(json.dumps({"providers": [{"id": "acme", "models": ["m"]}],
                             "groups": [{"id": "g1", "name": "x", "members": ["acme/m:high"],
                                         "routing": json.loads(routing_json)}]}))
    r = subprocess.run([sys.executable, "-I", "scripts/doctor.py", str(f)],
                       capture_output=True, text=True)
    return r.stdout
bad = rows('["order"]')
assert "routing=(invalid)" in bad, f"非字符串 routing 没打成 (invalid)：\n{bad[:400]}"
assert "routing=(empty)" not in bad, f"畸形值被套上「配了但配成空」的说法：\n{bad[:400]}"
emp = rows('""')
assert "routing=(empty)" in emp and "routing=(invalid)" not in emp, \
    f"空串那档被改坏了：\n{emp[:400]}"
PY
ok "a malformed routing value is labelled (invalid), an empty string stays (empty)"

# 142. 「目标路径上还留着上一次的产物」这条披露不得取决于使用者怎么写路径：写盘走的是
#      expanduser() 之后的路径，提醒若拿原始 argv 去 exists()，`~/out.json` 这种写法下
#      探测的是当前目录里一个叫 `~/out.json` 的文件——旧产物明明在，提醒静默丢掉。
python3 -I - "$TMP" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
tmp = Path(sys.argv[1])
SCRIPT = str(Path("scripts/render.py").resolve())   # 下面要换 cwd，脚本路径必须先算成绝对路径
home = tmp / "r142-home"; home.mkdir(exist_ok=True)
tpl = tmp / "r142-tpl.json"; mf = tmp / "r142-map.json"
tpl.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": ["<role:r>:high"]}]}))
mf.write_text(json.dumps({"r": ["acme/m1"]}))
env = dict(os.environ, HOME=str(home))
r = subprocess.run([sys.executable, "-I", SCRIPT, str(tpl), str(mf), "~/r142-out.json"],
                   capture_output=True, text=True, env=env, cwd=str(tmp))
assert r.returncode == 0 and (home / "r142-out.json").exists(), f"tilde 路径写不成：\n{r.stderr[:300]}"
# 现在让**拒绝写盘**那条分支跑起来（模板里放非有限数），旧产物还在那儿
tpl.write_text(json.dumps({"groups": [{"id": "g1", "routing": "order", "members": ["<role:r>:high"],
                                      "levels": {"a": float("nan")}}]}))
r2 = subprocess.run([sys.executable, "-I", SCRIPT, str(tpl), str(mf), "~/r142-out.json"],
                    capture_output=True, text=True, env=env, cwd=str(tmp))
t = r2.stdout + r2.stderr
assert r2.returncode != 0 and "non-finite" in t, f"没走到拒绝写盘分支：\n{t[:300]}"
assert "still holds the file from an earlier run" in t, \
    f"tilde 路径下陈旧文件提醒丢了（绝对路径的场合有，这里没有）：\n{t[:400]}"
PY
ok "the stale-product notice is given for ~-paths too (same path the write would use)"

# 143. 降级面的封闭字面量表**必须覆盖 validate 的四张枚举表**：漏一个取值，降级时那个合法值
#      就会被打成 `<ref N chars>`，而同一行已经声明「模式名与档位按枚举原样出现」——那是谎报。
#      这张表是手抄的（降级时 validate 根本载不进来，不可能运行时取），所以漂移只能这样钉。
python3 -I - "$TMP" <<'PY'
import importlib.util, sys
from pathlib import Path
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
v = load("v", "scripts/validate.py")
d = load("d", "scripts/doctor.py")
need = set(v.ROUTING_MODES) | set(v.AFFINITY) | set(v.MEMBER_EFFORT) | set(v.GROUP_EFFORT)
missing = sorted(need - d.NO_COMPARATOR_LITERALS)
assert not missing, f"降级表漏了 validate 的取值 {missing}：降级时它们会被掩成 <ref N chars>"
for sent in ("(unset)", "(empty)", "(invalid)", "-", "<no id>", ""):
    assert sent in d.NO_COMPARATOR_LITERALS, f"doctor 自己的哨兵 {sent!r} 不在封闭表里"
PY
ok "doctor's degraded-face literal table still covers every enum value validate can print"

echo "E2E PASS: ${CHECKS} checks"
