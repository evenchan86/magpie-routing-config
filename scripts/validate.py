#!/usr/bin/env python3
"""校验 magpie 路由层草案（groups/rules）。只读，退出码 0=PASS。"""
import json
import re
import sys
from pathlib import Path

TOP_FIELDS = {"groups"}
GROUP_FIELDS = {"id", "name", "members", "rules", "classifier", "disabled", "note"}
RULE_FIELDS = {"use", "more", "intent", "effort", "compact"}
SECRET_FIELD = re.compile(r"key|token|secret", re.I)
SECRET_VALUE = re.compile(r"sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|FAKE-")
EFFORT_SUFFIX = {"none", "low", "medium", "high", "xhigh", "max", "ultra"}


def fail(errors, msg):
    errors.append(msg)


def strip_effort(ref):
    base, _, suffix = ref.rpartition(":")
    if base and suffix in EFFORT_SUFFIX:
        return base
    return ref


def check_value(value, path, errors):
    if isinstance(value, str):
        if "<role:" in value:
            fail(errors, f"{path}: unresolved placeholder")
        if SECRET_VALUE.search(value):
            fail(errors, f"{path}: secret-like value")
    elif isinstance(value, list):
        for i, item in enumerate(value):
            check_value(item, f"{path}[{i}]", errors)
    elif isinstance(value, dict):
        for k, v in value.items():
            check_value(v, f"{path}.{k}", errors)


def main():
    if len(sys.argv) < 2:
        print("usage: validate.py <groups.json> [known-models.json]")
        return 2
    errors = []
    try:
        doc = json.loads(Path(sys.argv[1]).read_text())
    except Exception as exc:
        print(f"FAIL: invalid JSON: {exc}")
        return 1
    known = None
    if len(sys.argv) > 2:
        try:
            raw = json.loads(Path(sys.argv[2]).read_text())
        except Exception as exc:
            print(f"FAIL: invalid known-models JSON: {exc}")
            return 1
        if not isinstance(raw, list) or not all(isinstance(x, str) for x in raw):
            print("FAIL: known-models must be a JSON array of strings")
            return 1
        known = set(raw)

    def check_ref(ref, path):
        if not isinstance(ref, str) or not ref:
            fail(errors, f"{path}: model ref must be non-empty string")
        elif known is not None and strip_effort(ref) not in known:
            fail(errors, f"{path}: unknown model ref {ref!r}")

    if not isinstance(doc, dict):
        print("FAIL: top level must be an object with a groups list")
        return 1
    for key in doc:
        if key not in TOP_FIELDS:
            fail(errors, f"top-level: unknown field {key!r} (only groups allowed; providers must not appear)")
        if SECRET_FIELD.search(key):
            fail(errors, f"top-level: secret-like field {key!r}")

    groups = doc.get("groups")
    if not isinstance(groups, list) or not groups:
        fail(errors, "top-level groups must be a non-empty list")
        groups = groups if isinstance(groups, list) else []
    seen_ids = set()
    for gi, group in enumerate(groups):
        gp = f"groups[{gi}]"
        if not isinstance(group, dict):
            fail(errors, f"{gp}: must be object")
            continue
        for key in group:
            if key not in GROUP_FIELDS:
                fail(errors, f"{gp}: unknown field {key!r}")
            if SECRET_FIELD.search(key):
                fail(errors, f"{gp}: secret-like field {key!r}")
        if not isinstance(group.get("id"), str) or not group.get("id"):
            fail(errors, f"{gp}.id: required non-empty string")
        else:
            gid = group["id"]
            if gid in seen_ids:
                fail(errors, f"{gp}: duplicate group id {gid!r}")
            seen_ids.add(gid)
        if "disabled" in group and not isinstance(group["disabled"], bool):
            fail(errors, f"{gp}.disabled: must be bool")
        for fld in ("name", "note"):
            if fld in group and not isinstance(group[fld], str):
                fail(errors, f"{gp}.{fld}: must be string")
        if "classifier" in group:
            check_ref(group["classifier"], f"{gp}.classifier")
        members = group.get("members", [])
        if not isinstance(members, list):
            fail(errors, f"{gp}.members: must be list")
            members = []
        for mi, member in enumerate(members):
            check_ref(member, f"{gp}.members[{mi}]")
        rules = group.get("rules", [])
        if not isinstance(rules, list):
            fail(errors, f"{gp}.rules: must be list")
            rules = []
        for ri, rule in enumerate(rules):
            rp = f"{gp}.rules[{ri}]"
            if not isinstance(rule, dict):
                fail(errors, f"{rp}: must be object")
                continue
            for key in rule:
                if key not in RULE_FIELDS:
                    fail(errors, f"{rp}: unknown field {key!r}")
                if SECRET_FIELD.search(key):
                    fail(errors, f"{rp}: secret-like field {key!r}")
            if "use" not in rule:
                fail(errors, f"{rp}: use is required")
            else:
                check_ref(rule["use"], f"{rp}.use")
            if "more" in rule:
                if not isinstance(rule["more"], list):
                    fail(errors, f"{rp}.more: must be list")
                else:
                    for mi, ref in enumerate(rule["more"]):
                        check_ref(ref, f"{rp}.more[{mi}]")
            if "effort" in rule and rule["effort"] != "on":
                fail(errors, f"{rp}.effort: only \"on\" allowed")
            if "compact" in rule and rule["compact"] is not True:
                fail(errors, f"{rp}.compact: only true allowed")
            if "intent" in rule and not isinstance(rule["intent"], str):
                fail(errors, f"{rp}.intent: must be string")
        if rules and not any(isinstance(r, dict) and r.get("compact") is True for r in rules):
            fail(errors, f"{gp}: a compact:true fallback rule is required")
    check_value(doc, "$", errors)
    if errors:
        print("FAIL:")
        for err in errors:
            print(f"  {err}")
        return 1
    print(f"PASS: {len(groups)} group(s) valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
