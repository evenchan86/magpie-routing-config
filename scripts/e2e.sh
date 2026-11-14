#!/usr/bin/env bash
# 隔离 E2E：不碰真实本机 magpie 配置。用法：bash scripts/e2e.sh
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

# 2. 渲染：模板 + 映射 -> 产物（模拟 agent 占位替换）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
root = Path.cwd()
tmp = Path(sys.argv[1])
tpl = (root / "templates/groups.template.json").read_text()
mapping = json.loads((root / "examples/demo/roles.mapped.json").read_text())
for role, model in mapping.items():
    tpl = tpl.replace(f"<role:{role}>", model)
(tmp / "rendered.json").write_text(tpl)
PY
ok "template renders with role mapping"

# 3. 渲染产物与 demo 输出一致
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
a = json.loads((tmp / "rendered.json").read_text())
b = json.loads(Path("examples/demo/output.groups.json").read_text())
assert a == b, "rendered output diverges from demo"
PY
ok "rendered output matches demo"

# 4. 已知模型集合来自虚构本机配置（脱敏：只取模型名）
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads(Path("examples/demo/input.providers.json").read_text())
models = sorted({m for p in doc["providers"] for m in p.get("models", [])})
(tmp / "known.json").write_text(json.dumps(models))
PY
ok "known model set derived from fixture"

# 5. validate 对 demo 产物 PASS
python3 -I scripts/validate.py "$TMP/rendered.json" "$TMP/known.json" >/dev/null
ok "validate PASS on demo output"

# 6. 反向断言：占位残留必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads((tmp / "rendered.json").read_text())
doc["groups"][0]["rules"][0]["use"] = "<role:fast/cheap>"
(tmp / "bad-placeholder.json").write_text(json.dumps(doc))
PY
if python3 -I scripts/validate.py "$TMP/bad-placeholder.json" >/dev/null 2>&1; then
  echo "FAIL: placeholder draft accepted"; exit 1
fi
ok "placeholder draft rejected"

# 7. 反向断言：非法字段（日志 when 语法）必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads((tmp / "rendered.json").read_text())
doc["groups"][0]["rules"][0]["when"] = ["reasoning"]
(tmp / "bad-field.json").write_text(json.dumps(doc))
PY
if python3 -I scripts/validate.py "$TMP/bad-field.json" >/dev/null 2>&1; then
  echo "FAIL: unknown-field draft accepted"; exit 1
fi
ok "unknown-field draft rejected"

# 8. 反向断言：规则内密钥必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads((tmp / "rendered.json").read_text())
doc["groups"][0]["rules"][0]["use"] = "FAKE-injected-secret"
(tmp / "bad-secret.json").write_text(json.dumps(doc))
PY
if python3 -I scripts/validate.py "$TMP/bad-secret.json" >/dev/null 2>&1; then
  echo "FAIL: secret draft accepted"; exit 1
fi
ok "secret-like draft rejected"

# 9. 反向断言：classifier 未知模型必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads((tmp / "rendered.json").read_text())
doc["groups"][0]["classifier"] = "acme/does-not-exist"
(tmp / "bad-classifier.json").write_text(json.dumps(doc))
PY
if python3 -I scripts/validate.py "$TMP/bad-classifier.json" "$TMP/known.json" >/dev/null 2>&1; then
  echo "FAIL: unknown classifier accepted"; exit 1
fi
ok "unknown classifier rejected"

# 10. 反向断言：顶层 providers 段（含密钥）必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads((tmp / "rendered.json").read_text())
doc["providers"] = [{"id": "acme", "key": "FAKE-top-level-key"}]
(tmp / "bad-top.json").write_text(json.dumps(doc))
PY
if python3 -I scripts/validate.py "$TMP/bad-top.json" >/dev/null 2>&1; then
  echo "FAIL: top-level providers accepted"; exit 1
fi
ok "top-level providers section rejected"

# 11. 反向断言：缺 use 的规则必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads((tmp / "rendered.json").read_text())
del doc["groups"][0]["rules"][0]["use"]
(tmp / "bad-nouse.json").write_text(json.dumps(doc))
PY
if python3 -I scripts/validate.py "$TMP/bad-nouse.json" >/dev/null 2>&1; then
  echo "FAIL: missing-use rule accepted"; exit 1
fi
ok "missing-use rule rejected"

# 12. 反向断言：缺 compact 兜底的组必须 FAIL
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads((tmp / "rendered.json").read_text())
doc["groups"][0]["rules"] = [r for r in doc["groups"][0]["rules"] if not r.get("compact")]
(tmp / "bad-nofallback.json").write_text(json.dumps(doc))
PY
if python3 -I scripts/validate.py "$TMP/bad-nofallback.json" >/dev/null 2>&1; then
  echo "FAIL: missing-fallback group accepted"; exit 1
fi
ok "missing-fallback group rejected"

# 13. 正例：members 的 :effort 后缀在 known 校验下必须 PASS
python3 -I - "$TMP" <<'PY'
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
doc = json.loads((tmp / "rendered.json").read_text())
doc["groups"][0]["members"][0] = "acme/lite-chat:low"
(tmp / "good-effort.json").write_text(json.dumps(doc))
PY
python3 -I scripts/validate.py "$TMP/good-effort.json" "$TMP/known.json" >/dev/null
ok "effort-suffixed member accepted"

# 14. 仓库密钥扫描（全量逐字节、多编码，无文件豁免）
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

# 15. 文档围栏与 README 链接
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
readme = (root / "README.md").read_text()
for link in re.findall(r"\]\(([^)]+)\)", readme):
    if "://" in link or link.startswith("#"):
        continue
    assert (root / link).exists(), f"broken README link: {link}"
print("docs fences and README links ok")
PY
ok "docs fences and README links"

echo "E2E PASS: ${CHECKS} checks"
