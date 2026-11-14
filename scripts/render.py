#!/usr/bin/env python3
"""渲染两层路由模板：角色 → 有序模型列表展开。只读模板，退出码 0=OK。

用法: render.py <template.json> <mapping.json> [output.json]
mapping: {role: [model, ...]}（有序，主模型在前；元素为 base 引用 provider/model，
可含 #account 通道，不含 :effort）。模板成员 `<role:X>:effort` 展开为该角色所有模型
各带 :effort（多模型故障转移/池）；classifier `<role:intent/judge>` 取列表首元素。
规则 use/more 在模板里是 group/<id>，不展开。组内成员精确去重（保序，避免角色列表重叠产生重复成员）。
渲染产物交 validate.py 校验。
"""
import json
import re
import sys
from pathlib import Path

ROLE_RE = re.compile(r"<role:([^>]+)>(.*)", re.S)
EFFORT_SUFFIXES = {"none", "minimal", "low", "medium", "high", "xhigh", "max"}  # 同 validate.py MEMBER_EFFORT


def has_effort_suffix(ref):
    """base 引用是否带可剥的 :effort 后缀。镜像 validate.py base_model 的判定：
    只把「后缀全是已知强度」当强度，避免误伤 cn:glm-5.3 这类含冒号的真实模型名。"""
    core = ref.split("#", 1)[0]
    if core.endswith(":fast"):
        core = core[:-5]
    _, sep, suffix = core.rpartition(":")
    return bool(sep and suffix and all(p in EFFORT_SUFFIXES for p in suffix.split("+")))


def main():
    if len(sys.argv) < 3:
        print("usage: render.py <template.json> <mapping.json> [output.json]")
        return 2
    try:
        tpl = json.loads(Path(sys.argv[1]).read_text())
        mapping = json.loads(Path(sys.argv[2]).read_text())
    except Exception as exc:
        print(f"FAIL: invalid JSON: {exc}")
        return 1
    if not isinstance(mapping, dict):
        print("FAIL: mapping must be an object role->list")
        return 1
    errors = []
    for role, models in mapping.items():
        if models is None:
            continue
        if not isinstance(models, list) or not models:
            errors.append(f"mapping[{role!r}]: must be a non-empty list of model strings")
        elif not all(isinstance(m, str) and m for m in models):
            errors.append(f"mapping[{role!r}]: every element must be a non-empty model string")
        else:
            for m in models:
                if has_effort_suffix(m):
                    errors.append(f"mapping[{role!r}]: {m!r} 含强度后缀；mapping 元素须为 base 引用 provider/model（强度由模板成员后缀施加）")
    # 预校验失败先返回，避免展开阶段对非法元素崩溃（干净 FAIL 契约）
    if errors:
        print("FAIL:")
        for err in errors:
            print(f"  {err}")
        return 1

    def models_for(role):
        ms = mapping.get(role)
        if not isinstance(ms, list) or not ms:
            errors.append(f"role {role!r} used in template but not mapped to a non-empty list")
            return []
        return ms

    def expand_member(member):
        m = ROLE_RE.fullmatch(member)
        if not m:
            return [member]
        role, suffix = m.group(1), m.group(2)
        return [model + suffix for model in models_for(role)]

    groups = tpl.get("groups", [])
    if not isinstance(groups, list):
        print("FAIL: template groups must be a list")
        return 1
    for group in groups:
        if not isinstance(group, dict):
            continue
        cls = group.get("classifier")
        if isinstance(cls, str):
            m = ROLE_RE.fullmatch(cls)
            if m:
                role, suffix = m.group(1), m.group(2)
                ms = models_for(role)
                if ms:
                    group["classifier"] = ms[0] + suffix
        members = group.get("members")
        if isinstance(members, list):
            new, seen = [], set()
            for member in members:
                for item in (expand_member(member) if isinstance(member, str) else [member]):
                    # 组内精确去重（保序）：两个角色映射到重叠模型时避免重复成员
                    if isinstance(item, str):
                        if item in seen:
                            continue
                        seen.add(item)
                    new.append(item)
            group["members"] = new

    if errors:
        print("FAIL:")
        for err in errors:
            print(f"  {err}")
        return 1
    out = json.dumps(tpl, ensure_ascii=False, indent=2) + "\n"
    if len(sys.argv) > 3:
        Path(sys.argv[3]).write_text(out)
        print(f"OK: rendered {len(groups)} group(s) -> {sys.argv[3]}")
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
