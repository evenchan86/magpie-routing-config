#!/usr/bin/env python3
"""只读诊断本机 magpie 路由配置：提取 groups、派生已知模型、跑校验、给接线冒烟步骤（步骤本身含对活实例的 CLI 写操作）。

用法: doctor.py <providers.json>
不写任何文件。输出脱敏：只含组结构/id/模型名/诊断，绝不打印密钥或 endpoint。
退出码 0=诊断完成（含发现问题）1=文件/JSON 错误 2=用法。
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

VALIDATE = Path(__file__).resolve().parent / "validate.py"


def derive_known(providers_doc):
    """providers 段畸形时抛 ValueError，由调用方转成可读 FAIL（不 traceback）。"""
    providers = providers_doc.get("providers", [])
    if not isinstance(providers, list) or not all(isinstance(p, dict) for p in providers):
        raise ValueError("providers section must be a list of objects")
    return sorted({(m if "/" in m else f"{p.get('id', '')}/{m}")
                   for p in providers for m in (p.get("models") or [])})


def run_validate(groups_doc, known):
    with tempfile.TemporaryDirectory() as td:
        gp = Path(td) / "groups.json"
        kp = Path(td) / "known.json"
        gp.write_text(json.dumps(groups_doc, ensure_ascii=False))
        kp.write_text(json.dumps(known, ensure_ascii=False))
        p = subprocess.run([sys.executable, "-I", str(VALIDATE), str(gp), str(kp)],
                           capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


SMOKE = """wiring smoke test. Check the wiring BEFORE judging the groups: while an agent's entry is
a concrete model, nothing at group level runs at all (classifier, intent rules, group members and
failover chains are skipped; that request logs group and rule as null).
  0. read the wiring, single-argument form only: `magpie ls`, `magpie <agent>`.
  1. point the entry at a group: `magpie <agent> group/<id>` (or the UI). Wiring changes only
     affect NEW sessions; running processes keep the env they started with.
  2. send one request from a NEW session. `magpie claude run [args...]` starts one for Claude
     Code; other agents have no run subcommand — restart that agent instead. Never assume the
     launcher is generic: when the second word is not one of that agent's fields, magpie sets the
     agent's main model to that word, so `magpie codex run` really writes model = "run" and
     `magpie claude opus` really writes "model": "opus".
  3. prove the group was consulted: in ~/.config/magpie/routing/<date>.jsonl that request must
     carry group.id (the time field is `time`). One row with a null group does NOT prove the entry
     is a model — see docs/concepts.md. `applied.json` is a stale ledger, not current state.
  isolation: reading/writing wiring targets the LIVE instance. Only schema probes are isolated,
  and that needs all three legs — a fake HOME, MAGPIE_ADDR=127.0.0.1:1, and asserting
  `magpie status --json` reports running=false. The dead port alone still reads the real
  ~/.config/magpie, so it can hand you a false sense of isolation."""


def main():
    if len(sys.argv) != 2:
        print("usage: doctor.py <providers.json>")
        return 2
    try:
        doc = json.loads(Path(sys.argv[1]).read_text())
    except Exception as exc:
        print(f"FAIL: invalid JSON or unreadable file: {exc}")
        return 1
    if not isinstance(doc, dict):
        print("FAIL: providers.json top level must be an object")
        return 1
    try:
        known = derive_known(doc)
    except ValueError as exc:
        print(f"FAIL: {exc}")
        return 1
    groups = doc.get("groups", [])
    # groups 键存在但不是 list ⇒ 配置损坏，不能谎报「尚未配置」
    if "groups" in doc and not isinstance(groups, list):
        print("FAIL: groups must be a list; the config looks malformed (fix it before applying a draft)")
        return 1
    print(f"providers: {len(doc.get('providers', []))}; routing groups: {len(groups)}")
    if not groups:
        print("no routing layer configured yet. Use the AGENTS.md workflow to generate one, then apply.py to merge.")
        return 0
    bad = [i for i, g in enumerate(groups) if not isinstance(g, dict)]
    if bad:
        print(f"FAIL: groups entries at index {bad} are not objects; the config looks malformed")
        return 1
    for g in groups:
        cls = g.get("classifier", "-")
        # members/rules 可能是 null（magpie 自建的空组、pattern-only 组就是这样），不能 len(None)
        pat = len(g.get("match") or [])
        extra = f" match={pat}" if pat else ""
        print(f"  {g.get('id', '?'):<14} routing={g.get('routing', 'smart'):<8} members={len(g.get('members') or [])}{extra} classifier={cls}")
    rc, out = run_validate({"groups": groups}, known)
    print("validation:")
    print(out)
    if rc != 0:
        # 退出码契约是「0=诊断完成（含发现问题）」，别让调用方拿 && 当闸门
        print("note: doctor still exits 0 with findings — read the validation section above;"
              " do not use `doctor.py && ...` as a gate.")
    print()
    print(SMOKE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
