#!/usr/bin/env bash
# 隔离 E2E（两层路由）：不碰真实本机 magpie 配置。用法：bash scripts/e2e.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CHECKS=0
ok() { CHECKS=$((CHECKS+1)); echo "ok ${CHECKS} - $1"; }

# 1. 假 HOME 夹具（虚构 acme 供应商）
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.config/magpie"
cp examples/demo/input.providers.json "$FAKE_HOME/.config/magpie/providers.json"
[ -f "$FAKE_HOME/.config/magpie/providers.json" ] && ok "isolated fake HOME fixture"

# 2. 渲染：模板 + 映射 -> 产物（模拟 agent 占位替换，含 :effort 后缀）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
root = Path.cwd(); tmp = Path(sys.argv[1])
tpl = (root/"templates/groups.template.json").read_text()
mapping = json.loads((root/"examples/demo/roles.mapped.json").read_text())
for role, model in mapping.items():
    tpl = tpl.replace(f"<role:{role}>", model)
(tmp/"rendered.json").write_text(tpl)
PY
ok "template renders with role mapping"

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
python3 -I <<'PY'
import re
from pathlib import Path
root = Path.cwd()
real = re.compile(
    r"sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}"
    r"|AIza[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----")
for f in root.rglob("*"):
    if not f.is_file() or ".git" in f.parts:
        continue
    rel = str(f.relative_to(root))
    raw = f.read_bytes()
    cands = [raw.decode("latin-1")]
    for enc in ("utf-16-le", "utf-16-be"):
        try:
            cands.append(raw.decode(enc))
        except Exception:
            pass
    text = "\n".join(cands)
    assert not real.search(text), f"real secret pattern in {rel}"
    if "FAKE-" in text:
        assert rel.startswith("scripts/") or "docs/superpowers/" in rel or rel.startswith("examples/demo/") or (rel.startswith("tasks/e2e-") and rel.endswith(".log")), f"FAKE- leaked into {rel}"
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

echo "E2E PASS: ${CHECKS} checks"
