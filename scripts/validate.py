#!/usr/bin/env python3
"""校验 magpie 路由层草案（groups/rules，支持两层组引用）。只读，退出码 0=PASS。

权威来源：usemagpie.ai/docs/zh + magpie CLI（group help / group rule add --help）
+ 建临时组读回 magpie 实际写入的 JSON（rule 字段名以 JSON 为准，非 CLI 旗标名）。
全面白名单（官方字段全集，避免误拒）+ 聚焦两层语义校验。

关键 JSON 形态（实测，区别于 CLI 旗标）：
- rule `where`（CLI when=）= [{field, op, value}]；`time`（CLI time=/days=/tz=）= {from,to,days,zone} 对象。
- `exceptFolders`（CLI except-folders=）驼峰；`pause`（CLI pause=<model>）= true 布尔，模型在 use。
- `at`/rule 级 `classifier=` 是 CLI 便利写法（插入位置/设组级 classifier），非 rule JSON 字段。
- 组级 `weight=`/`listed=` 同样是 CLI 旗标：JSON 真键名是 `weights`（成员引用→整数 1..1000 的映射，
  键含 `:effort`）与 `unlists`（布尔 true）。写单数 `weight`/`listed` 进 JSON 会被静默忽略。
- glob/`re:` 模式放在**独立的 `match` 数组**，不在 `members`；pattern-only 组的 `members` 落盘为 null。
  手写模式进 `members` 会被当字面模型 id 跳过（实测 magpie 0.1.4130）。
- 键名写错→静默忽略；**类型写错→整份 providers.json 解析失败**（magpie 报 doesn't parse，退出码仍 0），
  故本校验器对字段类型从严。
"""
import json
import re
import sys
from pathlib import Path

TOP_FIELDS = {"groups"}
GROUP_FIELDS = {
    "id", "name", "members", "match", "rules", "classifier", "routing", "affinity",
    "intentSure", "context", "compact", "levels", "effort", "disabled",
    "hidden", "unlists", "note", "weights", "fast", "ultra", "pick", "family",
}
# CLI 旗标名 → JSON 真键名（实测：写左边的名字进 JSON 会被 magpie 静默忽略）
GROUP_CLI_ONLY = {"weight": "weights", "listed": "unlists"}
# rule JSON 字段（实测）：不含 CLI 旗标名 when/tz/days/except-folders/at/classifier
RULE_FIELDS = {
    "use", "more", "intent", "effort", "compact", "useEffort", "tokens",
    "images", "agents", "time", "folders", "exceptFolders", "where", "pause",
}
MEMBER_EFFORT = {"none", "minimal", "low", "medium", "high", "xhigh", "max"}
USE_EFFORT = {"low", "medium", "high", "xhigh", "max"}
RULE_EFFORT = {"on", "low", "medium", "high", "xhigh", "max"}
ROUTING_MODES = {
    "smart", "order", "drain", "rotate", "usage", "pace", "weight",
    "free", "fast", "cheap", "expiring", "manual",
}
AFFINITY = {"auto", "session", "turn", "off", "strict"}
GROUP_EFFORT = {"auto", "agent"}
MAX_DEPTH = 8
# 凭据字段名：按 _/- 边界匹配 key/token/secret 等，排除合法的 tokens（计数）字段
SECRET_FIELD = re.compile(r"(?i)(?:^|[_\-])(?:key|token|secret|password|passwd|credential)(?:$|[_\-])")
SECRET_VALUE = re.compile(r"sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|FAKE-")


def fail(errors, msg):
    errors.append(msg)


def is_group_ref(ref):
    return isinstance(ref, str) and ref.startswith("group/")


def is_pattern(ref):
    return isinstance(ref, str) and ("*" in ref or ref.startswith("re:"))


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def base_model(ref):
    """剥 #account / :fast / :effort(含 :low+high 多级)，得到 provider/model 基名。"""
    ref = ref.split("#", 1)[0]
    if ref.endswith(":fast"):
        ref = ref[:-5]
    base, sep, suffix = ref.rpartition(":")
    if sep and suffix and all(p in MEMBER_EFFORT for p in suffix.split("+")):
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

    def check_ref(ref, path, errors):
        """模型引用须已知；组引用/模式单独处理（此处只查模型）。"""
        if not isinstance(ref, str) or not ref:
            fail(errors, f"{path}: ref must be non-empty string")
            return
        if is_group_ref(ref) or is_pattern(ref):
            return
        if known is not None and base_model(ref) not in known:
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
    nest_adj = {}      # gid -> 成员里的组引用（嵌套图，用于自包含/深度）
    all_refs = {}      # gid -> 所有组引用（成员/规则/classifier，用于存在性）
    gdata = {}         # gid -> {member_models, member_groups, has_pattern, rule_models, classifier}
    for gi, group in enumerate(groups):
        gp = f"groups[{gi}]"
        if not isinstance(group, dict):
            fail(errors, f"{gp}: must be object")
            continue
        for key in group:
            if key in GROUP_CLI_ONLY:
                fail(errors, f"{gp}: {key!r} is a CLI flag, not a JSON field"
                             f" (use {GROUP_CLI_ONLY[key]!r}; magpie silently ignores {key!r})")
            elif key not in GROUP_FIELDS:
                fail(errors, f"{gp}: unknown field {key!r}")
            if SECRET_FIELD.search(key):
                fail(errors, f"{gp}: secret-like field {key!r}")
        gid = group.get("id")
        if not isinstance(gid, str) or not gid:
            fail(errors, f"{gp}.id: required non-empty string")
            gid = f"<invalid-{gi}>"
        elif gid in seen_ids:
            fail(errors, f"{gp}: duplicate group id {gid!r}")
        seen_ids.add(gid)
        nest_adj.setdefault(gid, set())
        all_refs.setdefault(gid, set())

        if "disabled" in group and not isinstance(group["disabled"], bool):
            fail(errors, f"{gp}.disabled: must be bool")
        for fld in ("name", "note", "family"):
            if fld in group and not isinstance(group[fld], str):
                fail(errors, f"{gp}.{fld}: must be string")
        if "routing" in group and group["routing"] not in ROUTING_MODES:
            fail(errors, f"{gp}.routing: unknown mode {group['routing']!r}")
        if "affinity" in group and group["affinity"] not in AFFINITY:
            fail(errors, f"{gp}.affinity: unknown value {group['affinity']!r} (CLI stays=)")
        if "effort" in group:
            if group["effort"] not in GROUP_EFFORT:
                fail(errors, f"{gp}.effort: only auto|agent allowed")
            elif group["effort"] == "auto" and "classifier" not in group:
                fail(errors, f"{gp}.effort=auto requires a classifier")
        if "intentSure" in group:
            v = group["intentSure"]
            if not is_num(v) or not (0 <= v <= 1):
                fail(errors, f"{gp}.intentSure: must be number 0..1")
        for fld in ("context", "compact"):
            if fld in group:
                v = group[fld]
                if not is_num(v) or v < 0:
                    fail(errors, f"{gp}.{fld}: must be non-negative number (tokens)")
        if "levels" in group:
            lv = group["levels"]
            if not isinstance(lv, list) or not all(x in MEMBER_EFFORT for x in lv):
                fail(errors, f"{gp}.levels: must be list of effort levels")

        # 类型写错会让 magpie 整份 providers.json 解析失败（不是忽略该字段），故类型必须严格
        if "unlists" in group and not isinstance(group["unlists"], bool):
            fail(errors, f"{gp}.unlists: must be bool (CLI listed=no → unlists:true)")

        members = group.get("members")
        if members is None:
            members = []          # pattern-only 组落盘时 members 为 null（实测）
        if not isinstance(members, list):
            fail(errors, f"{gp}.members: must be list")
            members = []
        match = group.get("match")
        if match is None:
            match = []
        if not isinstance(match, list) or not all(isinstance(x, str) and x for x in match):
            fail(errors, f"{gp}.match: must be a list of non-empty pattern strings")
            match = []
        # hidden 墓碑是 magpie 有意保留的状态：`group rm` 一个自动发现的组会落盘
        # {"id":"auto-x","name":"","members":null,"hidden":true}（实测），不是坏配置
        if not members and not match and not group.get("hidden"):
            fail(errors, f"{gp}: needs members or match (default routing uses the group's routing mode)")
        has_pattern = bool(match)   # 模式在 match 里，不在 members（实测）
        member_refs = {m for m in members if isinstance(m, str)}

        def check_member_ref(ref, path):
            """weights/fast/ultra/pick 的元素须为完整成员引用（含 :effort）。
            实测：非成员或裸引用在 CLI 路径硬报错、JSON 路径静默忽略。
            但组含模式时，元素可以是**模式展开出来的**模型（magpie 接受，实测），
            而工具不展开模式，故此时退回「已知模型」检查，不做成员资格判定。"""
            if has_pattern:
                check_ref(ref, path, errors)
            elif not isinstance(ref, str) or ref not in member_refs:
                fail(errors, f"{path}: {ref!r} is not a member of this group"
                             " (use the full member ref incl. :effort; magpie ignores others)")

        if "weights" in group:
            w = group["weights"]
            if not isinstance(w, dict):
                fail(errors, f"{gp}.weights: must be an object mapping member ref -> integer 1..1000")
            else:
                for k, v in w.items():
                    check_member_ref(k, f"{gp}.weights key {k!r}")
                    if isinstance(v, bool) or not isinstance(v, int) or not 1 <= v <= 1000:
                        fail(errors, f"{gp}.weights[{k!r}]: must be an integer 1..1000"
                                     " (magpie reads out-of-range values, but every later"
                                     " `group set` on this group is refused until fixed)")
        if "pick" in group:
            if not isinstance(group["pick"], str):
                fail(errors, f"{gp}.pick: must be a single model ref string")
            else:
                check_member_ref(group["pick"], f"{gp}.pick")
        for fld in ("fast", "ultra"):
            if fld in group:
                v = group[fld]
                if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
                    fail(errors, f"{gp}.{fld}: must be a list of model ref strings")
                else:
                    for xi, x in enumerate(v):
                        check_member_ref(x, f"{gp}.{fld}[{xi}]")
        member_models = set()
        member_groups = set()
        for mi, member in enumerate(members):
            mp = f"{gp}.members[{mi}]"
            check_ref(member, mp, errors)
            if is_group_ref(member):
                ref = member[len("group/"):]
                nest_adj[gid].add(ref)
                all_refs[gid].add(ref)
                member_groups.add(ref)
            elif is_pattern(member):
                fail(errors, f"{mp}: pattern belongs in 'match', not 'members'"
                             " (magpie treats it as a literal model id and skips it)")
            elif isinstance(member, str):
                member_models.add(base_model(member))

        rules = group.get("rules", [])
        if not isinstance(rules, list):
            fail(errors, f"{gp}.rules: must be list")
            rules = []
        rule_models = set()

        def check_target(ref, path):
            """规则目标引用校验 + 成员资格（magpie 强制 use/more 必须是本组成员）。"""
            check_ref(ref, path, errors)
            if is_group_ref(ref):
                r = ref[len("group/"):]
                all_refs[gid].add(r)
                if r not in member_groups:
                    fail(errors, f"{path}: {ref!r} is not a member of group {gid!r} (use/more must be members)")
            elif isinstance(ref, str) and not is_pattern(ref):
                bm = base_model(ref)
                rule_models.add(bm)
                if not has_pattern and bm not in member_models:
                    fail(errors, f"{path}: {ref!r} is not a member of group {gid!r} (use/more must be members)")

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
                fail(errors, f"{rp}: use is required (pause rules also carry use=<model> + pause:true)")
            else:
                check_target(rule["use"], f"{rp}.use")
            if "more" in rule:
                if not isinstance(rule["more"], list):
                    fail(errors, f"{rp}.more: must be list")
                else:
                    for mi, ref in enumerate(rule["more"]):
                        check_target(ref, f"{rp}.more[{mi}]")
            if "effort" in rule and rule["effort"] not in RULE_EFFORT:
                fail(errors, f"{rp}.effort: must be on or an effort level")
            if "useEffort" in rule and rule["useEffort"] not in USE_EFFORT:
                fail(errors, f"{rp}.useEffort: unknown level {rule['useEffort']!r}")
            if "compact" in rule and rule["compact"] is not True:
                fail(errors, f"{rp}.compact: only true allowed (compaction trigger)")
            if "pause" in rule and rule["pause"] is not True:
                fail(errors, f"{rp}.pause: only true allowed (model carried in use)")
            if "intent" in rule and not isinstance(rule["intent"], str):
                fail(errors, f"{rp}.intent: must be string")
            if "tokens" in rule and (not is_num(rule["tokens"]) or rule["tokens"] < 0):
                fail(errors, f"{rp}.tokens: must be non-negative number")
            if "images" in rule and not isinstance(rule["images"], bool):
                fail(errors, f"{rp}.images: must be bool")
            if "agents" in rule and not isinstance(rule["agents"], list):
                fail(errors, f"{rp}.agents: must be list")
            for fld in ("folders", "exceptFolders"):
                if fld in rule and not isinstance(rule[fld], list):
                    fail(errors, f"{rp}.{fld}: must be list")
            if "time" in rule and not isinstance(rule["time"], dict):
                fail(errors, f"{rp}.time: must be object {{from,to,days,zone}} (CLI time=/days=/tz=)")
            if "where" in rule:
                w = rule["where"]
                # subagent 条件天然无 value（magpie 落盘 {"field":"subagent","op":"is"}，实测）
                if not isinstance(w, list) or not all(
                    isinstance(c, dict) and {"field", "op"} <= set(c)
                    and ("value" in c or c.get("field") == "subagent") for c in w
                ):
                    fail(errors, f"{rp}.where: must be list of {{field,op,value}} (CLI when=)")

        cls = group.get("classifier")
        if cls is not None:
            check_ref(cls, f"{gp}.classifier", errors)
            if is_group_ref(cls):
                all_refs[gid].add(cls[len("group/"):])
        if any(isinstance(r, dict) and "intent" in r for r in rules) and cls is None:
            fail(errors, f"{gp}: intent rules require a classifier")
        gdata[gid] = {
            "member_models": member_models, "member_groups": member_groups,
            "has_pattern": has_pattern, "rule_models": rule_models, "classifier": cls,
        }

    # 组引用存在性
    for gid, refs in all_refs.items():
        for ref in refs:
            if ref not in seen_ids:
                fail(errors, f"group {gid!r}: references unknown group {ref!r}")

    # classifier 分离守卫（跨组）：意图判断模型绝不进【任何】路由组的成员/规则目标。
    # classifier 为组时，解析其成员模型；该 classifier 池自身的成员豁免（它们就是分类器）。
    classifier_models = set()
    classifier_groups = set()

    def resolve_models(gid, visited):
        if gid in visited or gid not in gdata:
            return set()
        visited.add(gid)
        classifier_groups.add(gid)
        dat = gdata[gid]
        out = set(dat["member_models"])
        for gr in dat["member_groups"]:
            out |= resolve_models(gr, visited)
        return out

    for gid, dat in gdata.items():
        cls = dat["classifier"]
        if isinstance(cls, str) and is_group_ref(cls):
            classifier_models |= resolve_models(cls[len("group/"):], set())
        elif isinstance(cls, str) and not is_pattern(cls):
            classifier_models.add(base_model(cls))
    for gid, dat in gdata.items():
        if gid in classifier_groups:
            continue
        for m in sorted(dat["member_models"] | dat["rule_models"]):
            if m in classifier_models:
                fail(errors, f"group {gid!r}: {m!r} is a classifier model; classifier must only judge intent, never a routing member/target")

    # 禁自包含（嵌套图环检测）+ 深度 ≤8（有环则跳过深度，避免递归崩溃）
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {gid: WHITE for gid in nest_adj}
    has_cycle = False

    def dfs(gid, stack):
        nonlocal has_cycle
        color[gid] = GRAY
        for nxt in sorted(nest_adj.get(gid, set())):
            if nxt not in color:
                continue
            if color[nxt] == GRAY:
                has_cycle = True
                fail(errors, f"group nesting cycle (self-inclusion): {' -> '.join(stack + [nxt])}")
            elif color[nxt] == WHITE:
                dfs(nxt, stack + [nxt])
        color[gid] = BLACK

    for gid in list(nest_adj):
        if color[gid] == WHITE:
            dfs(gid, [gid])

    if not has_cycle:
        depth_cache = {}

        def depth(gid):
            if gid in depth_cache:
                return depth_cache[gid]
            best = 0
            for nxt in nest_adj.get(gid, set()):
                if nxt in color:
                    best = max(best, 1 + depth(nxt))
            depth_cache[gid] = best
            return best

        for gid in nest_adj:
            d = depth(gid)
            if d > MAX_DEPTH:
                fail(errors, f"group {gid!r}: nesting depth {d} exceeds {MAX_DEPTH}")

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
