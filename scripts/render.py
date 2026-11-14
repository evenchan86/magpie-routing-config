#!/usr/bin/env python3
"""渲染两层路由模板：角色 → 有序模型列表展开。只读模板，退出码 0=OK。

用法: render.py <template.json> <mapping.json> [output.json]
mapping: {role: [model, ...]}（有序，主模型在前；元素为 base 引用 provider/model，
可含 #account 通道，不含 :effort；可用 model@effort 覆写该模型的强度，组合写法
provider/model#account@effort）。仅当最后一个 @ 后恰为合法 effort 才视为覆写，否则
整串按 base 引用（模型 id / 账号名本身可含 @，如 gpt-4o@2024-08-06、#user@example.com）。模板成员
`<role:X>:effort` 展开为该角色所有模型——带 @effort 的模型用覆写强度，其余用槽位
:effort（多模型故障转移/池，可同组混强度）；classifier `<role:intent/judge>` 取列表
首元素的 base 引用（裸 provider/model，不带强度）。
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


def split_override(entry):
    """拆成 (base_ref, effort_override)。仅在【最后一个 @ 之后恰为合法 effort（支持 + 多级）】
    时视为覆写；否则整串按 base 引用处理——因为 magpie 的模型 id 与账号名本身可含 @
    （实测：acme/gpt-4o@2024-08-06 可入组落盘；#user@example.com 被解析为账号名）。
    写错强度（如 model@hig）不会被当成覆写而静默改义，而是留作模型名，交给 validate 的
    unknown-model 检查兜底。"""
    base, at, override = entry.rpartition("@")
    if at and override and all(p in EFFORT_SUFFIXES for p in override.split("+")):
        return base, override
    return entry, None


def apply_effort(base_ref, effort_suffix):
    """把 :effort 后缀施加到 base_ref，正确放在 #account 之前。
    magpie member 语法是 model:effort#account，不是 model#acc:effort。"""
    if not effort_suffix:
        return base_ref
    core, hash_sep, account = base_ref.partition("#")
    return core + effort_suffix + (hash_sep + account if hash_sep else "")


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
            for entry in models:
                base, _ = split_override(entry)
                if not base:
                    errors.append(f"mapping[{role!r}]: {entry!r} 模型名为空；mapping 元素须为 base 引用 provider/model（可加 @effort 覆写）")
                elif has_effort_suffix(base):
                    errors.append(f"mapping[{role!r}]: {entry!r} 的模型部分含强度后缀；mapping 元素须为 base 引用（强度由模板后缀或 @effort 覆写施加）")
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
        out = []
        for entry in models_for(role):
            base, override = split_override(entry)
            eff = ":" + override if override else suffix
            out.append(apply_effort(base, eff))
        return out

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
                ms = models_for(m.group(1))
                if ms:
                    # classifier 恒为裸 provider/model：剥 @effort 覆写，不加任何强度后缀
                    base, _ = split_override(ms[0])
                    group["classifier"] = base
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
