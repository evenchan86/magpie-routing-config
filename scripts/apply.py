#!/usr/bin/env python3
"""把路由层草案按 group id upsert 合并进本机 magpie 配置。只动 groups，不碰 providers。

用法: apply.py <draft-groups.json> <providers.json> [--write]
默认 dry-run：只校验**合并结果** + 展示组级 diff，不写文件。--write 才写入
（先备份并保留原权限、写后读回磁盘校验，任何一步失败自动从备份恢复）。
输出脱敏：只含组结构/id/模型名/诊断，绝不打印密钥或 endpoint。退出码 0=OK 1=失败 2=用法。
"""
import json
import os
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

VALIDATE = Path(__file__).resolve().parent / "validate.py"


def derive_known(providers_doc):
    """从 providers 派生已知模型清单（provider/model 拼前缀；已含 / 的保持）。
    providers 段畸形时抛 ValueError，由调用方转成可读 FAIL（不 traceback）。"""
    providers = providers_doc.get("providers", [])
    if not isinstance(providers, list) or not all(isinstance(p, dict) for p in providers):
        raise ValueError("providers section must be a list of objects")
    return sorted({(m if "/" in m else f"{p.get('id', '')}/{m}")
                   for p in providers for m in (p.get("models") or [])})


def run_validate(groups_doc, known):
    """黑盒复用 validate.py：提取 groups + known 写临时文件，subprocess 校验。"""
    with tempfile.TemporaryDirectory() as td:
        gp = Path(td) / "groups.json"
        kp = Path(td) / "known.json"
        gp.write_text(json.dumps(groups_doc, ensure_ascii=False))
        kp.write_text(json.dumps(known, ensure_ascii=False))
        p = subprocess.run([sys.executable, "-I", str(VALIDATE), str(gp), str(kp)],
                           capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def upsert(existing, draft):
    """按 id upsert：同 id 替换该组对象，新 id 追加末尾，其余原样保留。"""
    by_id, order = {}, []
    for g in existing:
        gid = g.get("id")
        if gid not in by_id:
            order.append(gid)
        by_id[gid] = g
    added, replaced = [], []
    for g in draft:
        gid = g.get("id")
        (replaced if gid in by_id else added).append(gid)
        if gid not in by_id:
            order.append(gid)
        by_id[gid] = g
    merged = [by_id[gid] for gid in order]
    kept = [gid for gid in order if gid not in added and gid not in replaced]
    return merged, added, replaced, kept


def non_groups(doc):
    return {k: v for k, v in doc.items() if k != "groups"}


def backup_path(target_path):
    """备份名带 UTC 时间戳；同秒重跑加序号，避免覆盖上一份备份。"""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    base = target_path.with_name(target_path.name + f".bak-{stamp}")
    if not base.exists():
        return base
    n = 2
    while True:
        cand = target_path.with_name(base.name + f"-{n}")
        if not cand.exists():
            return cand
        n += 1


def main():
    args = [a for a in sys.argv[1:] if a != "--write"]
    write = "--write" in sys.argv[1:]
    if len(args) != 2:
        print("usage: apply.py <draft-groups.json> <providers.json> [--write]")
        return 2
    draft_path, target_path = Path(args[0]), Path(args[1])
    try:
        draft_doc = json.loads(draft_path.read_text())
        target = json.loads(target_path.read_text())
    except Exception as exc:
        print(f"FAIL: invalid JSON or unreadable file: {exc}")
        return 1
    if not isinstance(target, dict):
        print("FAIL: providers.json top level must be an object")
        return 1
    draft_groups = draft_doc.get("groups") if isinstance(draft_doc, dict) else draft_doc
    if not isinstance(draft_groups, list) or not draft_groups:
        print("FAIL: draft must contain a non-empty groups list")
        return 1
    if isinstance(draft_doc, dict) and "providers" in draft_doc:
        print("note: the draft's providers section is ignored; only groups are merged")

    try:
        known = derive_known(target)
    except ValueError as exc:
        print(f"FAIL: {exc}")
        return 1
    existing = target.get("groups", [])
    if not isinstance(existing, list):
        print("FAIL: existing providers.json groups must be a list")
        return 1
    for i, g in enumerate(existing):
        if not isinstance(g, dict):
            print(f"FAIL: existing groups[{i}] must be an object; fix the config first (see doctor.py)")
            return 1

    # 1. 先 upsert，再校验【合并结果】——跨组守卫（classifier 分离、组引用存在）只有
    #    在合并后的全量 groups 上才成立；只校验草案孤岛会既漏判又误拒。
    merged, added, replaced, kept = upsert(existing, draft_groups)
    rc, out = run_validate({"groups": merged}, known)
    if rc != 0:
        print("FAIL: merged result would not pass validation; nothing merged")
        print(out)
        print("hint: findings in groups you are not replacing come from the existing config;"
              " inspect it with doctor.py")
        return 1
    result = dict(target)
    result["groups"] = merged

    # 2. 组级 diff 摘要（脱敏）
    def n_members(gid):
        g = next((x for x in merged if x.get("id") == gid), {})
        return len(g.get("members") or [])
    print("merge plan (groups only; providers untouched):")
    print(f"  add     ({len(added)}): " + (", ".join(f"{g}[{n_members(g)}]" for g in added) or "-"))
    print(f"  replace ({len(replaced)}): " + (", ".join(f"{g}[{n_members(g)}]" for g in replaced) or "-"))
    print(f"  keep    ({len(kept)}): " + (", ".join(kept) or "-"))

    if not write:
        print("dry-run: nothing written. Re-run with --write to apply (a backup is made first).")
        return 0

    # 3. --write：备份（保留原权限）→ 写入 → 读回磁盘校验，失败自动恢复
    original = target_path.read_text()
    backup = backup_path(target_path)
    backup.write_text(original)
    os.chmod(backup, stat.S_IMODE(target_path.stat().st_mode))

    def restore(reason):
        target_path.write_text(original)
        print(f"FAIL: {reason}")
        print(f"restored the original config from the backup; backup kept at: {backup}")
        return 1

    target_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"backup: {backup}")
    try:
        on_disk = json.loads(target_path.read_text())
    except Exception as exc:
        return restore(f"written file is not readable JSON: {exc}")
    if not isinstance(on_disk, dict) or non_groups(on_disk) != non_groups(target):
        return restore("providers section changed on disk; only groups may be merged")
    rc, out = run_validate({"groups": on_disk.get("groups", [])}, known)
    if rc != 0:
        print(out)
        return restore("post-write validation of the on-disk config FAILED")
    print(f"OK: merged {len(merged)} group(s); post-write validation PASS")
    print("next: point your agent at group/auto in magpie, send a test request, and check the log (see doctor.py).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
