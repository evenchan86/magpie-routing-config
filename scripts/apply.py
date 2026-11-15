#!/usr/bin/env python3
"""把路由层草案按 group id upsert 合并进本机 magpie 配置。只动 groups，不碰 providers。

用法: apply.py <draft-groups.json> <providers.json> [--write]
默认 dry-run：只校验**合并结果** + 展示组级与组内字段级 diff，不写文件。--write 才写入
（先备份并保留原权限、写后读回磁盘校验，任何一步失败自动从备份恢复）。
输出脱敏：只含组结构/id/模型名/诊断，绝不打印密钥或 endpoint。退出码 0=OK 1=失败 2=用法。
"""
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

VALIDATE = Path(__file__).resolve().parent / "validate.py"
# 复用 validate.py 的密钥判定（单真源）。-I 模式下脚本目录不在 sys.path，故按路径加载。
_spec = importlib.util.spec_from_file_location("magpie_validate", VALIDATE)
_validate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_validate)
# endpoint 不在 validate 的密钥形态里，但同样承诺不回显
ENDPOINT = re.compile(r"(?i)(?:https?|wss?)://|[\w.-]+\.[a-z]{2,}:\d{2,5}")


def secretish(v):
    """存量组【不经校验】（校验的是合并结果），回显前先自查密钥/endpoint 形态。
    命中就把整组的 diff 降级成形态摘要——宁可少显示，不可把凭据打进上下文。"""
    if isinstance(v, str):
        return bool(_validate.SECRET_VALUE.search(v) or ENDPOINT.search(v))
    if isinstance(v, list):
        return any(secretish(x) for x in v)
    if isinstance(v, dict):
        return any(secretish(k) or secretish(x) for k, x in v.items())
    return False


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


def check_ids(groups, label):
    """元素须为对象、id 须为非空字符串、id 不得重复。重复 id 会让 upsert 静默丢组
    （last wins），而合并计划还把它算进 keep——必须拒绝，不能默默合并。"""
    seen = set()
    for i, g in enumerate(groups):
        if not isinstance(g, dict):
            return f"{label} groups[{i}] must be an object"
        gid = g.get("id")
        if not isinstance(gid, str) or not gid:
            return f"{label} groups[{i}] needs a non-empty string id"
        if gid in seen:
            return f"{label} groups[{i}] duplicates group id {gid!r} (upsert would silently drop one)"
        seen.add(gid)
    return None


DIFF_LIST_FIELDS = ("members", "match", "fast", "ultra", "levels")
# 回显字符串要过两道闸：①字段是【模型引用/枚举】白名单（note/name 等自由文本一律只给形态）；
# ②整组过 secretish() 自查——存量组不经校验（校验的是合并结果），任何字段都可能夹带凭据。
ECHO_GROUP_FIELDS = {"classifier", "pick", "routing", "affinity", "effort", "id"}
ECHO_RULE_FIELDS = {"use", "effort", "useEffort"}


def brief(v, echo=False):
    """脱敏摘要。字符串默认【不】回显内容，只给 `<text N chars>`；
    调用点确认是模型引用/枚举时才传 echo=True。数字/布尔照实，容器只给规模。"""
    if v is None:
        return "(unset)"
    if isinstance(v, str):
        if not v:
            return "(empty)"
        return v if echo else f"<text {len(v)} chars>"
    if isinstance(v, (bool, int, float)):
        return str(v)
    if isinstance(v, list):
        return f"[{len(v)} items]"
    if isinstance(v, dict):
        return f"{{{len(v)} keys}}"
    return f"<{type(v).__name__}>"


def same(a, b):
    """类型敏感比较：Python 的 1 == True == 1.0 会把真实改动判成没变。"""
    return json.dumps(a, sort_keys=True, ensure_ascii=False) == json.dumps(b, sort_keys=True, ensure_ascii=False)


def seq(v):
    """列表字段归一：magpie 会落盘 null（纯模式组 / 自动发现组），与 [] 语义相同。"""
    return [] if v is None else v


def refs(v, echo=True):
    return [x if isinstance(x, str) and echo else brief(x) for x in v]


def conds(w, echo=True):
    """where 条件摘要：field/op 是枚举可回显，value 可能是路径等自由文本 → 只给形态。"""
    if not isinstance(w, list):
        return brief(w)
    parts = []
    for c in w:
        if not isinstance(c, dict):
            parts.append(brief(c))
            continue
        s = f"{brief(c.get('field'), echo=echo)} {brief(c.get('op'), echo=echo)}"
        if "value" in c:
            s += " " + brief(c["value"])
        parts.append(s)
    return "[" + ", ".join(parts) + "]"


def rule_lines(old, new, echo=True):
    """逐条规则的变化：改向（use/more）、条件、强度都要看得见，不能只报条数。"""
    out = []
    for i in range(max(len(old), len(new))):
        o = old[i] if i < len(old) else None
        n = new[i] if i < len(new) else None
        tag = f"rules[{i}]"
        if o is None or n is None:
            side, verb = (n, "added") if o is None else (o, "removed")
            target = brief(side.get("use"), echo=echo) if isinstance(side, dict) else brief(side)
            out.append(f"{tag}: {verb} (use {target})")
            continue
        if same(o, n):
            continue
        if not isinstance(o, dict) or not isinstance(n, dict):
            out.append(f"{tag}: {brief(o)} → {brief(n)}")
            continue
        for k in sorted(set(o) | set(n)):
            a, b = o.get(k), n.get(k)
            if same(a, b):
                continue
            if k == "where":
                out.append(f"{tag}.where: {conds(a, echo)} → {conds(b, echo)}")
            elif k == "more":
                aa = refs(seq(a), echo) if isinstance(a, list) or a is None else [brief(a)]
                bb = refs(seq(b), echo) if isinstance(b, list) or b is None else [brief(b)]
                out.append(f"{tag}.more: {' '.join(aa) or '(unset)'} → {' '.join(bb) or '(unset)'}")
            elif k == "intent":
                # 草案侧已过校验可回显；存量侧未校验，只给形态
                out.append(f"{tag}.intent: {brief(a)} → {brief(b, echo=echo)}")
            else:
                e = echo and k in ECHO_RULE_FIELDS
                out.append(f"{tag}.{k}: {brief(a, echo=e)} → {brief(b, echo=e)}")
    return out


def group_diff(old, new, echo=True):
    """被替换组的字段级变化（脱敏）。无变化返回 []。覆盖两侧全部键，不漏改动。"""
    lines = []
    for key in DIFF_LIST_FIELDS:
        a, b = seq(old.get(key)), seq(new.get(key))
        if same(a, b):
            continue
        if not isinstance(a, list) or not isinstance(b, list):
            lines.append(f"{key}: {brief(a)} → {brief(b)}")
            continue
        a, b = refs(a, echo), refs(b, echo)
        gone, came = [x for x in a if x not in b], [x for x in b if x not in a]
        if gone or came:
            lines.append(f"{key}: " + " ".join(["-" + x for x in gone] + ["+" + x for x in came]))
        elif len(a) != len(b):
            lines.append(f"{key}: duplicate count changed ({len(a)} → {len(b)} entries)")
        else:
            lines.append(f"{key}: order changed")
    a, b = seq(old.get("rules")), seq(new.get("rules"))
    if not same(a, b):
        if isinstance(a, list) and isinstance(b, list):
            if sorted(json.dumps(r, sort_keys=True) for r in a) == sorted(json.dumps(r, sort_keys=True) for r in b):
                lines.append("rules: reordered")
            else:
                lines.append(f"rules: {len(a)} → {len(b)}")
                lines.extend(rule_lines(a, b, echo))
        else:
            lines.append(f"rules: {brief(a)} → {brief(b)}")
    a, b = old.get("weights"), new.get("weights")
    if not same(a, b):
        if isinstance(a, dict) and isinstance(b, dict):
            parts = [f"{brief(k, echo=echo)} {brief(a.get(k))} → {brief(b.get(k))}"
                     for k in sorted(set(a) | set(b)) if not same(a.get(k), b.get(k))]
            lines.append("weights: " + "; ".join(parts))
        else:
            lines.append(f"weights: {brief(a)} → {brief(b)}")
    handled = set(DIFF_LIST_FIELDS) | {"rules", "weights", "id"}
    for key in sorted((set(old) | set(new)) - handled):
        a, b = old.get(key), new.get(key)
        if not same(a, b):
            e = echo and key in ECHO_GROUP_FIELDS
            lines.append(f"{key}: {brief(a, echo=e)} → {brief(b, echo=e)}")
    return lines


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
    err = check_ids(existing, "existing")
    if err:
        print(f"FAIL: {err}; fix the config first (see doctor.py)")
        return 1
    err = check_ids(draft_groups, "draft")
    if err:
        print(f"FAIL: {err}")
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
    def label(gid):
        """组 id 同样过闸门：凭据形态会被 validate 先拒，但 endpoint 形态不会，
        而 keep/add 列表里的 id 不经 group_diff，故这里必须自查。"""
        return f"<id {len(gid)} chars>" if secretish(gid) else gid
    print("merge plan (groups only; providers untouched):")
    print(f"  add     ({len(added)}): " + (", ".join(f"{label(g)}[{n_members(g)}]" for g in added) or "-"))
    print(f"  replace ({len(replaced)}): " + (", ".join(f"{label(g)}[{n_members(g)}]" for g in replaced) or "-"))
    print(f"  keep    ({len(kept)}): " + (", ".join(label(g) for g in kept) or "-"))
    # 被替换的组：显示组内字段级变化，让使用者能知情确认（不是只看计数）
    if replaced:
        old_by_id = {g.get("id"): g for g in existing}
        new_by_id = {g.get("id"): g for g in draft_groups}
        for gid in replaced:
            o, n = old_by_id.get(gid, {}), new_by_id.get(gid, {})
            lines = group_diff(o, n, echo=not (secretish(o) or secretish(n)))
            if not lines:
                print(f"    {label(gid)}: identical (replaced with the same content)")
            else:
                print(f"    {label(gid)}:")
                for line in lines:
                    print(f"      {line}")

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
