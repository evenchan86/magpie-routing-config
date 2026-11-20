#!/usr/bin/env python3
"""只读诊断本机 magpie 路由配置：提取 groups、派生已知模型、跑校验、报形状问题（schema 合法但吃亏的配法）、给接线冒烟步骤（步骤本身含对活实例的 CLI 写操作）。

用法: doctor.py <providers.json>
不写任何文件。输出脱敏：只含组结构/id/模型名/诊断，绝不打印密钥或 endpoint——
所有用户可控的串（组 id、成员引用、首位成员）都过 validate.shield() 再回显。
退出码 0=诊断完成（含发现问题）1=文件/JSON 错误 2=用法。
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

VALIDATE = Path(__file__).resolve().parent / "validate.py"

# 只有这两档有「首成员 = 默认」语义（docs/patterns.md 模式 8 的校正段 + 模式 4 的通道顺序）；
# usage/weight/rotate/pace 的首位不承载优先级，拿首位判锚就是对它们误报。
ORDER_LIKE = ("order", "drain")
# 单成员判据另一条射程：`manual` 由 pick 选定成员、schema.md 明确它不做故障转移，
# 所以「只有一个成员」对它不构成损失。其余模式（含缺省 smart）都靠成员互为退路。
NO_FAILOVER_SKIP = ("manual",)


def load_validate():
    """载入 validate.py 复用它的档位集合、`base_model` 与 `shield`——单真源，别在 doctor 里抄第二份。
    失败返回 None：此时**模型名/档位类判据必须明说没查**，且所有回显一律走形态摘要（fail closed）。"""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("magpie_validate", str(VALIDATE))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


_V = load_validate()


def shield(value):
    """回显前的最后一道闸。载不进 validate 时**不打印原文**，只给形态——
    没比较器也不能把可能的凭据打进上下文。"""
    if _V is None:
        s = str(value)
        # `(unset)` 是 doctor 自己的哨兵、模式名/档位是文档里的枚举词，都不是用户可控串
        if s in NO_COMPARATOR_LITERALS or (s.isidentifier() and len(s) <= 40):
            return s
        return f"<ref {len(s)} chars>"
    return _V.shield(value)


def derive_known(providers_doc):
    """providers 段畸形时抛 ValueError，由调用方转成可读 FAIL（不 traceback）。"""
    providers = providers_doc.get("providers", [])
    if not isinstance(providers, list) or not all(isinstance(p, dict) for p in providers):
        raise ValueError("providers section must be a list of objects")
    return sorted({(m if "/" in m else f"{p.get('id', '')}/{m}")
                   for p in providers for m in (p.get("models") or [])})


def run_validate(groups_doc, known):
    if not VALIDATE.exists():
        return None, "(validate.py not found next to doctor.py — validation not run)"
    with tempfile.TemporaryDirectory() as td:
        gp = Path(td) / "groups.json"
        kp = Path(td) / "known.json"
        gp.write_text(json.dumps(groups_doc, ensure_ascii=False))
        kp.write_text(json.dumps(known, ensure_ascii=False))
        p = subprocess.run([sys.executable, "-I", str(VALIDATE), str(gp), str(kp)],
                           capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def match_of(group):
    """match 同样可能是 null / 字符串 / 对象（畸形或手写配置）。按【列表】语义处理：
    非列表一律视为空——字符串 `match: "acme/*"` 既不能算「有模式成员」，也不能打成长度数字。"""
    pat = group.get("match")
    return pat if isinstance(pat, list) else []


def members_of(group):
    """members 可能是 null/字符串/数字/对象（magpie 自建组、畸形配置）。判据一律按空处理，不崩。"""
    mem = group.get("members")
    return [str(m) for m in mem] if isinstance(mem, list) else []


def tier(member, efforts):
    """成员尾部档位；先剥 `#account`（`provider/model:high#acc` 合法）。
    解析不出单一档位（裸引用、多级 `:low+high`）返回 None，档位类判据对它沉默。"""
    if not efforts:
        return None
    base = str(member).split("#", 1)[0]
    suf = base.rsplit(":", 1)[1] if ":" in base else ""
    return suf if suf in efforts else None


def gid(group):
    return shield(group.get("id") if group.get("id") is not None else "?")


# 判据出处都在 docs/patterns.md（目前只有中文版）：单成员→模式 9/经验 2；首位→模式 13 与坑 3；
# 档位→模式 3 的代价段与经验 1；usage/rotate→模式 2 与经验 2。工具输出保持英文（与
# validate/apply 一致，README 的入口是英文），文档锚点按编号引，段首的限定语里声明文档语言
# （输出是英文、判据出处是中文文档，不说破的话读者会以为编号对应的是英文段落）。
NO_COMPARATOR_LITERALS = {"(unset)", "-", ""} | set(
    ("smart", "order", "drain", "usage", "weight", "rotate", "pace", "manual",
     "auto", "session", "none", "minimal", "low", "medium", "high", "xhigh", "max"))
NO_COMPARATOR =("model-name and effort checks were NOT RUN (could not load validate.py)"
                 " — that line is 'not checked', not 'clean'")


def find_shape_issues(groups):
    """合法但吃亏的形状——validate 刻意不管（同档与锚定是本机成本取舍，不是 schema 约束）。
    射程（要写清，别让读者以为覆盖全部）：只看**不含 `group/` 成员**的叶子组；首位类判据只配对
    order 类组（`order`/`drain`）；配了 `match` 的组不判「只有一个成员」（还有模式成员兜着，
    跨模式成员的故障转移未实测，所以只说「不能断定没有备用路径」）；裸引用与 `:low+high`
    多级成员解析不出单一档位，档位类判据对它们沉默。"""
    out = []
    # 重复 id 会让下面的判据「同一个 id 自相矛盾」，先声明出来（apply 侧是直接拒绝合并）
    # 只比【非空字符串】id：两个组都缺 id 不是「重复 id」，那是 validate 单独 FAIL 的另一回事
    ids = [g["id"] for g in groups
           if isinstance(g, dict) and isinstance(g.get("id"), str) and g["id"]]
    dups = sorted({i for i in ids if ids.count(i) > 1})
    if dups:
        out.append("duplicate group ids: " + ", ".join(shield(d) for d in dups)
                   + " -> apply.py refuses such a config (upsert would silently drop one); findings"
                   " below may attribute different groups to the same id")
    leaf = [g for g in groups
            if isinstance(g, dict) and members_of(g)
            and not any(m.startswith("group/") for m in members_of(g))]
    order_g = [g for g in leaf if g.get("routing", "smart") in ORDER_LIKE]
    for g in leaf:
        # match 非空时还有模式成员，「members 只有 1 个」不足以断定没有备用路径
        if g.get("routing", "smart") in NO_FAILOVER_SKIP:
            continue
        if len(members_of(g)) == 1 and not match_of(g):
            out.append(f"{gid(g)}: {shield(g.get('routing', 'smart'))} group has a single member and no match"
                       " pool -> no failover inside the group (a whole-group failure falls back to some"
                       " other intent group = silent quality drop; add a second member, pattern 9)")
    if _V is None or not getattr(_V, "MEMBER_EFFORT", None):
        # 谎报干净比不查更糟：单成员判据上面已经跑完，这里只声明缺比较器的那几类没查
        out.append(NO_COMPARATOR)
        return out
    efforts = set(_V.MEMBER_EFFORT)

    def base(m):
        return _V.base_model(str(m))

    # 两条首位判据刻意用不同粒度，各自都有实测理由：
    # ① 漂移/不锚：只在两组共享【完全相同的成员串】（同模型同档）、且该成员至少在某一组居首时报警。
    #    按基名比会在自家 demo 上刷噪声（共享基名但两边档位不同的组根本不是锚漂移）；
    #    不要求「至少在一组居首」则会在「各自有自己的锚、共用同一个便宜备胎」这种正常配法上误报。
    #    射程边界（必须写出来，别让人把 `none` 读成「没有漂移」）：锚在【所有】组里都被挪到非首位时，
    #    这份落盘数据与「各自有锚 + 共用备胎」完全同形，任何只看落盘的判据都分不出——这类漂移看不见。
    # ② 同锚不同档：按【基名】聚合各首位（`base_model` 剥掉 :effort/#account）。这是最贵的漏判：
    #    档位进 prompt cache 键（实测只改 budget_tokens 就让 cache_read 归零，见经验 1），首位看着
    #    一致、前缀照样整段重付。它必须在①的「完全相同」粒度之外单独跑，否则正好被①漏掉。
    drift = []
    for i, a in enumerate(order_g):
        for b in order_g[i + 1:]:
            ma, mb = members_of(a), members_of(b)
            fa, fb = ma[0], mb[0]
            shared = set(ma) & set(mb)
            if shared and fa != fb and (fa in shared or fb in shared):
                moved = fa if fa in shared else fb
                head_of = gid(a) if moved == fa else gid(b)
                other = gid(b) if moved == fa else gid(a)
                drift.append(f"{gid(a)}/{gid(b)}: {shield(moved)} is first in {head_of} but not in"
                             f" {other} (firsts {shield(fa)} vs {shield(fb)})")
    if drift:
        cap, extra = 6, ""
        if len(drift) > cap:
            extra = f" (+{len(drift) - cap} more pairs not listed)"
            drift = drift[:cap]
        out.append("order-like groups share a member but do not start with it the same way: "
                   + "; ".join(drift) + extra +
                   " -> two readings, the tool cannot tell them apart: deliberate non-anchoring"
                   " (pattern 13 allows it) or magpie's own later rewrite moved the first member"
                   " (pitfall 3, one local observation)")
    by_first = {}
    for g in order_g:
        t = tier(members_of(g)[0], efforts)
        if t:
            by_first.setdefault(base(members_of(g)[0]), []).append((gid(g), t))
    for b, lst in sorted(by_first.items()):
        if len({t for _, t in lst}) > 1:
            out.append("order-like groups start with the same model at different effort: "
                       f"{shield(b)} -> " + ", ".join(f"{g}:{t}" for g, t in sorted(lst)) +
                       " -> two readings: deliberate per-intent effort (pattern 13 says it is mutually"
                       " exclusive with anchoring) or a missed edit / a rewritten order. Cost:"
                       " effort is part of the cache key (evidence 1), so the switch that lands on"
                       " another tier repays the whole prefix")
    for g in leaf:
        mode = g.get("routing", "smart")
        ts = [tier(m, efforts) for m in members_of(g)]
        # manual 不参与：pick 选定成员、不做故障转移，没有「落到别的成员」的那一轮去重付
        if len({t for t in ts if t}) > 1 and mode != "manual":
            out.append(f"{gid(g)}: members at different effort {[t or '-' for t in ts]}"
                       " -> legal (pattern 3 'same model, two efforts'); cost: the turn that falls"
                       " back to another member repays the whole prefix (pattern 3, cost paragraph)")
            if mode in ("usage", "rotate", "weight"):
                out.append(f"{gid(g)}: {mode} assumes interchangeable members;"
                           " different effort conflicts with that premise (pattern 2, evidence 2)")
    return out


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
  3. prove the group served the request: in ~/.config/magpie/routing/<date>.jsonl that request
     must carry group.id (the time field is `time`). Which group served it is not the same as
     which level picked the member — see docs/concepts.md. One row with a null group does NOT
     prove the entry is a model — see docs/concepts.md. `applied.json` is a stale ledger, not
     current state.
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
    if _V is None:
        # 降级不是「一切照常、只是少几项」：连合法组 id 与模型引用都只能给形态摘要（fail closed
        # 没有形态表可用）。不写这行，读者会把 `<ref 6 chars>` 读成「这里有个被藏起来的值」。
        print("note: validate.py is not loadable from here -> group ids, first members, routing and"
              "\n      affinity below are SHAPE SUMMARIES (<ref N chars>), not names. This is not a"
              "\n      readable inspection table; fix the install and re-run.")
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
        cls = shield(g.get("classifier")) if g.get("classifier") else "-"
        # members 可能是 null 甚至非列表（magpie 自建的空组、pattern-only 组、畸形配置）→ 按空处理
        mem = members_of(g)
        pat = len(match_of(g))
        extra = f" match={pat}" if pat else ""
        # 粘性取值与首位成员都要打出来：magpie 曾被观测到重排 members（见 docs/patterns.md 坑 3），
        # 「落盘后回读首位与 affinity」这一步没有这两个读数就无从执行。首位只对 order 类有意义。
        first = f" first={shield(mem[0])}" if mem and g.get("routing", "smart") in ORDER_LIKE else ""
        aff = g.get("affinity", "(unset)")
        print(f"  {gid(g):<14} routing={shield(g.get('routing', 'smart')):<8} members={len(mem)}{extra}"
              f" affinity={shield(aff)} classifier={cls}{first}")
    rc, out = run_validate({"groups": groups}, known)
    # 校验器崩了 ≠ 校验通过：把这点显式打出来，否则下面 `shape findings: none` 会被读成体检合格
    # 只认 python 未捕获异常的头部行：正常 FAIL 的文本里也可能出现 `Traceback` 这个值本身
    crashed = any(l.startswith("Traceback (most recent call last)") for l in out.splitlines())
    print("validation:")
    print(out)
    if crashed:
        print("note: the validator CRASHED on this config (traceback above) — no validation verdict;")
        print("      the shape findings below are partial at best")
    issues = find_shape_issues(groups)
    # 段名刻意保持短（`shape findings:`），限定语放下一行——文档要能逐字指到这段。
    # 限定语说「每条各自 schema 合法、validate 不 enforce 这些」，不说「validate 会接受这份配置」：
    # 同一份配置可能另有 FAIL，那时后者就是假话。
    print("shape findings:")
    print("  (each one is schema-legal on its own — validate does not enforce these")
    print("   when a finding cites a pattern/evidence/pitfall number, that section is in docs/patterns.md")
    print("   (that document is Chinese-only — the output you are reading is English)")
    print("   single-member advisories cover every routing mode except manual; first-member ones only order-like)")
    if crashed:
        print("  not evaluated: the validator crashed above, so this section is not a verdict")
    elif not issues:
        print("  none")
    for line in issues:
        print(f"  {line}")
    if rc != 0 or crashed or issues:
        # 退出码契约是「0=诊断完成（含发现问题）」，别让调用方拿 && 当闸门
        print("note: doctor still exits 0 with findings — read the validation and shape findings"
              " sections above; do not use `doctor.py && ...` as a gate.")
    print()
    print(SMOKE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
