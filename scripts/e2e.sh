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
# 具体同构断言：g-code 三模型有序链（code/general 2 个 + fast/cheap 1 个），备用与主力同档
assert rendered["g-code"]["members"] == ["acme/code-standard:high", "acme/code-backup:high", "acme/lite-chat:high"], rendered["g-code"]["members"]
assert rendered["auto"]["classifier"] == "acme/judge"
# 模板形状守卫（防退化）。docgate 对 templates/*.json 只取顶层键集合，组内改动没有任何机器闸兜底
# ——上一轮「策略已改、模板没跟上」就是这么漂过去的。所以策略本身进断言，不只留在文档里。
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
# g-test 是 usage（首位没有「默认成员」语义，见坑 3），但它唯一的成员就是锚：切到测试意图也不换模型
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
SEC = "sk-" + "a" * 26
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
assert rc == 0 and EP not in out and "<id " in out, out

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
    互相抵消，集合相等就假绿（实测可复现）。
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
    #（「集合 none/low/…（…且缺 minimal，已修正）」实测假绿）。分隔符不限 / 、 , 空格，
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

echo "E2E PASS: ${CHECKS} checks"
