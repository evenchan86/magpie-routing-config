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
# 具体同构断言：g-code 三模型有序链（code/general 2 个 + fast/cheap 1 个）
assert rendered["g-code"]["members"] == ["acme/code-standard:high", "acme/code-backup:high", "acme/lite-chat:medium"], rendered["g-code"]["members"]
assert rendered["auto"]["classifier"] == "acme/judge"
PY
ok "multi-model expansion invariant (count = sum of list lengths; classifier = first)"

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

# 41. 正例：多元素 intent/judge 列表 → classifier 取首元素（变异 ms[-1] 会被此断言抓住）
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
ok "apply/doctor output contains no secrets or endpoints"

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
WRITE = '    target_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\\n")'
MUT = {
  "corrupt-json": '    target_path.write_text("{ this is not json")',
  "providers-tampered": '    bad = dict(result); bad["providers"] = [{"id": "evil"}]\n'
                        '    target_path.write_text(json.dumps(bad, ensure_ascii=False, indent=2) + "\\n")',
  "groups-corrupted": '    bad = json.loads(json.dumps(result))\n'
                      '    bad["groups"][0]["members"] = ["acme/ghost-model"]\n'
                      '    target_path.write_text(json.dumps(bad, ensure_ascii=False, indent=2) + "\\n")',
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

# 58. 真实 magpie 形态：自建空组的 members/rules 为 null，doctor/apply 不得崩溃
#     （本机实测踩到：len(None) 让 doctor 在真实配置上 traceback）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
base = json.loads(Path("examples/demo/input.providers.json").read_text())
base["groups"] = [{"id": "auto-legacy", "routing": "order", "members": None, "rules": None}]
(tmp/"null-members.json").write_text(json.dumps(base))
PY
OUT="$(python3 -I scripts/doctor.py "$TMP/null-members.json" 2>&1)"
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: doctor crashed on null members: $OUT"; exit 1; fi
grep -q "members=0" <<< "$OUT"
grep -q "must be list" <<< "$OUT"
OUT="$(python3 -I scripts/apply.py "$TMP/ref-draft.json" "$TMP/null-members.json" 2>&1)" && { echo "FAIL: null-members group passed validation"; exit 1; }
if grep -q "Traceback" <<< "$OUT"; then echo "FAIL: apply crashed on null members: $OUT"; exit 1; fi
grep -q "nothing merged" <<< "$OUT"
ok "doctor/apply tolerate real magpie null members/rules (no crash, honest findings)"

echo "E2E PASS: ${CHECKS} checks"
