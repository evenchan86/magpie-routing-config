#!/usr/bin/env python3
"""只读诊断本机 magpie 路由配置：提取 groups、派生已知模型、跑校验、报形状问题（schema 合法但吃亏的配法）、给接线冒烟步骤（步骤本身含对活实例的 CLI 写操作）。

用法: doctor.py <providers.json>
不写任何文件。输出脱敏：只含组结构/id/模型名/诊断，绝不打印密钥或 endpoint 形态——
所有用户可控的串（组 id、成员引用、首位成员、字段名、报错路径的每一段）都过 validate.shield() 再回显。
**刻意不掩的一类**：只含一个点的串（`llm.internal`、`proxy.corp`，以及 `#user@example.com` 这类两段
域名）——模型名里带点太常见，掩了回显就读不懂；代价是两段主机形态的内网名会原样出现，射程写进 AGENTS.md。
（三段点分的 `acme/model.v2.pro` 不在这类里：它与 endpoint 同形，一律掩。）
**含控制字符的串**走第四种形态：先按形态判——**判可疑就整串掩成 `<ref N chars>`**（N=原串长度），
不可疑才按 ascii 转义显示（`g\x1b]0;…\x07\n…`）——一个换行就能让值在终端里造出新行
（包括伪造本工具自己的句子），OSC/BEL 还能改终端标题、响铃。
退出码 0=诊断完成（含发现问题）1=文件/JSON 错误 2=用法。
"""
import collections
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
    失败返回 None：此时**模型名/档位类判据必须明说没查**，且所有回显一律走形态摘要（fail closed）。

    「载得进来」不等于「判据齐」：一份缺函数的半成品副本会在跑到一半时才 AttributeError，
    而 doctor 是逐段打印的——停在半句上的输出比一条 FAIL 更难读，也更容易被当成体检结果。
    所以按 validate 自带的 `PUBLIC_API` 逐名核，缺任何一名都按「载不进」处理（同一套 fail closed），
    并把缺的名字带进措辞。名单只读那一份表，本机不抄第二份。"""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("magpie_validate", str(VALIDATE))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception:
        return None, ("present but not loadable (broken or partial copy)" if VALIDATE.exists()
                      else "not found next to doctor.py")
    names = getattr(mod, "PUBLIC_API", None)
    missing = ("PUBLIC_API",) if names is None else tuple(n for n in names if not hasattr(mod, n))
    if missing:
        return None, "present but missing " + ", ".join(missing) + " (broken or partial copy)"
    return mod, None


_V, _V_WHY = load_validate()


def shield(value):
    """回显前的最后一道闸。载不进 validate 时**不打印原文**，只给形态——
    没比较器也不能把可能的凭据打进上下文。"""
    if _V is None:
        s = str(value)
        if s in NO_COMPARATOR_LITERALS:
            return s
        return f"<ref {len(s)} chars>"
    return _V.shield(value)


def derive_known(providers_doc):
    """providers 段畸形时抛 ValueError，由调用方转成可读 FAIL（不 traceback）。
    首选 `validate.derive_known`（单真源）；载入不了时走下面这份**逐条对齐**的副本——doctor 的
    降级路径要在 validate.py 缺席时也能读出 providers。两份的口径由 e2e 的畸形 providers 那条
    一起钉（同一批形状必须让两个脚本给出同样的 FAIL）。"""
    if _V is not None:
        return _V.derive_known(providers_doc)
    providers = providers_doc.get("providers", [])
    if not isinstance(providers, list) or not all(isinstance(p, dict) for p in providers):
        raise ValueError("providers section must be a list of objects")
    for p in providers:
        models = p.get("models")
        if models is None:
            continue
        if not isinstance(models, list) or not all(isinstance(m, str) for m in models):
            # 同 validate 的 mask_provider_id：一律给长度摘要。**两份口径必须一致**——
            # 降级路径没有形态表可用，若这里按别的规则放行，同一份坏配置在两个脚本下
            # 会给出不同形状的 FAIL（e2e 一起钉）。
            pid = str(p.get('id', '?'))
            raise ValueError(f"providers[<ref {len(pid)} chars>]"
                             ".models must be a list of strings")
    return sorted({(m if "/" in m else f"{p.get('id', '')}/{m}")
                   for p in providers for m in (p.get("models") or [])})


def run_validate(groups_doc, known):
    """返回 (rc, stdout, stderr)。**崩溃判定只看 stderr**（未捕获异常的 traceback 走 stderr，
    stdout 是校验器的判决）；混在一段文本里判就等于给「值伪造 traceback」留了口子。"""
    if _V is None:
        # 判据必须是「载不载得进来」，不是「文件在不在」：文件在但载不进（半成品拷贝、语法坏）时
        # 起子进程会以 SyntaxError 退出，而那份报错**没有** `Traceback (most recent call last)`
        # 头部行 → 崩溃判定说是「没崩」→ validation 段下面只剩一个空行，会被读成
        # 「校验没查出问题」。两种故障都得明说「没跑」。
        return None, f"(validate.py {_V_WHY} — validation not run)", ""
    try:
        with tempfile.TemporaryDirectory() as td:
            gp = Path(td) / "groups.json"
            kp = Path(td) / "known.json"
            # 临时文件用 ASCII 转义写法落盘（apply 同一口径）：配置里可能有「合法 JSON、但 UTF-8
            # 编不出来」的字符（孤立代理对），原先这里抛 traceback，整次体检连判决都没开始。
            gp.write_text(json.dumps(groups_doc, ensure_ascii=True))
            kp.write_text(json.dumps(known, ensure_ascii=True))
            p = subprocess.run([sys.executable, "-I", str(VALIDATE), str(gp), str(kp)],
                               capture_output=True, text=True)
    except (OSError, ValueError) as exc:
        # 连校验器都没开跑（磁盘满 / 临时目录不可用）。抛 traceback 会让这次体检的 stdout 是 0 字节，
        # 使用者拿到的是「什么都没输出」，而不是「校验没跑成」。
        return None, f"(validate.py could not be started: {type(exc).__name__}: {exc} — validation not run)", ""
    if _V.validator_crashed(p.stderr):
        # 崩溃判定排在「没判决」之前：崩溃那次同样一行判决都没打，先判 no_verdict 就把唯一的
        # traceback 吞了，只剩一句「没跑出判决」。
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    if _V.no_verdict(p.stdout):
        # 第三种状态：既不是合格也不是崩溃，而是**没跑出判决**。留在 validation 段里的
        # 一个空行会被读成「没查出问题」，配上下面独立的 `shape findings: none` 更像体检合格
        # （实测：被截断的 validate.py 与被 SIGKILL 的 validate.py 都是这样，stdout 空）。
        return None, _V.NO_VERDICT_NOTE, p.stderr.strip()
    return p.returncode, p.stdout.strip(), p.stderr.strip()


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
    i = group.get("id")
    if not isinstance(i, str) or not i:
        # 空列会被读成「这一行属于上面那个组」；`<no id>` 是 doctor 自己的哨兵，不是配置内容
        return "<no id>"
    return shield(i)


# 判据出处都在 docs/patterns.md（目前只有中文版）：单成员→模式 9/经验 2；首位→模式 13 与坑 3；
# 档位→模式 3 的代价段与经验 1；usage/rotate/weight→模式 2 与经验 2。工具输出保持英文（与
# validate/apply 一致，README 的入口是英文），文档锚点按编号引，段首的限定语里声明文档语言
# （输出是英文、判据出处是中文文档，不说破的话读者会以为编号对应的是英文段落）。
# 降级时**只有**这张封闭枚举表里的字面量可以原样打印（deny-by-default）。判据不能是「像不像
# 名字」：`ghp_` + 字母数字那种凭据本身就是合法 identifier，按「是 identifier 就放行」会把整串
# 凭据打进一份已经声明「这里全是形态摘要」的输出。
# 这张表**必须覆盖 validate 的三张枚举表**（ROUTING_MODES / AFFINITY / MEMBER_EFFORT）加
# doctor 自己的哨兵——漏一个取值，降级时那个合法值就会被打成 `<ref 4 chars>`，而同一行已经声明
# 「模式名与档位按枚举原样出现」，等于谎报。e2e 第 67 条把 ROUTING_MODES 与 AFFINITY **逐个取值**
# 跑降级面钉住；MEMBER_EFFORT/GROUP_EFFORT 那几词今天不出现在降级输出里（降级时档位判据根本不跑），
# 留在表里是防御性的——以后谁给降级面加一列档位，就得给 e2e 补一条同样的逐值遍历。
NO_COMPARATOR_LITERALS = {"(unset)", "(empty)", "(invalid)", "-", "<no id>", ""} | set(
    ("smart", "order", "drain", "rotate", "usage", "pace", "weight",
     "free", "fast", "cheap", "expiring", "manual",                     # = validate.ROUTING_MODES
     "auto", "session", "turn", "off", "strict",                        # = validate.AFFINITY
     "agent",                                                          # = validate.GROUP_EFFORT
     "none", "minimal", "low", "medium", "high", "xhigh", "max"))        # = validate.MEMBER_EFFORT
NO_COMPARATOR =("model-name and effort checks were NOT RUN (could not load validate.py)"
                 " — that line is 'not checked', not 'clean'; the first-member, drift and tier"
                 " advisories are skipped here too (comparing masked forms would invent matches)"
                 " — only the single-member and duplicate-group-id advisories still run")


def first_member_note(order_g):
    """首位类判据的**射程披露**，返回一个列表（有得比时为空）。

    首位类判据是**组间**判据：两组 order 类叶子组才比得出「锚被挪走了」。单组配置在这里永远
    「干净」，而那份干净没有任何证据含量——不说破，读者会把它当成「锚还在首位」，而漂移恰恰
    只能从组间差异里看见（本机唯一一次观测就是组间看到的）。
    单真源放这里：比较器在不在的两条出口都要带同一句话，写两份就会漂。"""
    if len(order_g) >= 2:
        return []
    # 措辞刻意**不**复用 `not evaluated`：那是崩溃时整段形状判据被抹掉的说法（两处含义共用一个
    # 短语，读者与 e2e 的分寸都会糊）。这里说的是「没得可比」，不是「没跑」。
    return ["first-member checks: nothing to compare here — "
            f"only {len(order_g)} order-like leaf group(s) here, and both of those checks"
            " compare one group's first member against another group's. So the absence of"
            " a first-member finding is not evidence that the anchor is still first; re-run"
            " the same draft through apply.py later WITHOUT --write to catch a reorder"
            " (that comparison has a before/after to diff)"]


def find_shape_issues(groups):
    """合法但吃亏的形状——validate 刻意不管（同档与锚定是本机成本取舍，不是 schema 约束）。
    射程（要写清，别让读者以为覆盖全部）：只看**不含 `group/` 成员**的叶子组；首位类判据只配对
    order 类组（`order`/`drain`）；配了 `match` 的组不判「只有一个成员」（还有模式成员兜着，
    跨模式成员的故障转移未实测，所以只说「不能断定没有备用路径」）；裸引用与 `:low+high`
    多级成员解析不出单一档位，档位类判据对它们沉默。

    返回 `(findings, notes)`：notes 是**射程披露**（这一轮哪些判据根本没得比），不是发现，
    所以不参与退出码那套「有问题」的措辞。「没得比」和「比了、没问题」必须分开打——把前者并入
    后者就是「没查完」被读成「查过且干净」。"""
    out = []
    notes = []
    # 重复 id 会让下面的判据「同一个 id 自相矛盾」，先声明出来（apply 侧是直接拒绝合并）
    # 只比【非空字符串】id：两个组都缺 id 不是「重复 id」，那是 validate 单独 FAIL 的另一回事
    ids = [g["id"] for g in groups
           if isinstance(g, dict) and isinstance(g.get("id"), str) and g["id"]]
    # Counter 而不是 ids.count：后者是 O(n²)（20000 个组实测 90 秒，而这里只要重复 id 的名单）
    id_counts = collections.Counter(ids)
    dups = sorted(i for i, c in id_counts.items() if c > 1)
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
        # 没比较器时**射程披露也要照带**：下面那段直接不走了，而「没得比」这条披露与比较器在不在无关
        notes.extend(first_member_note(order_g))
        return out, notes
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
    # 按成员建索引找候选对：原来是对所有 order 组两两比（O(n²)），实测 20000 个组要 90 秒，
    # 而输出最多只打 6 条——花在看不见的地方。索引把候选对限定到「确实共用某个成员」的组对上。
    by_member = {}
    for g in order_g:
        for m in set(members_of(g)):
            by_member.setdefault(m, []).append(g)
    idx_of = {id(g): i for i, g in enumerate(order_g)}
    # 预算按成员**轮转**消耗：按成员名字母序推进会让字母序靠前的成员吃光预算，
    # 后面的成员根本没被看过——共享成员排序靠后的组对直接漏掉（实测 250 个组共享一个成员时，
    # 靠后那个共享成员的漂移彻底消失）。轮转保证每个成员都分得到预算。
    # 用真函数而不是生成器表达式：生成器表达式闭包共享循环变量，两个成员会指向同一份列表。
    def _pairs(gs):
        for i in range(len(gs)):
            for j in range(i + 1, len(gs)):
                yield gs[i], gs[j]

    iters = []
    for m in sorted(by_member):
        gs = by_member[m]
        if len(gs) < 2:
            continue
        iters.append(_pairs(gs))
    seen_pairs = set()
    matched = []
    examined = 0
    truncated = False
    PAIR_BUDGET = 20000
    while iters:
        for it in list(iters):
            if examined > PAIR_BUDGET:
                truncated = True
                break
            pair = next(it, None)
            if pair is None:
                iters.remove(it)
                continue
            examined += 1
            a, b = pair
            ia, ib = idx_of[id(a)], idx_of[id(b)]
            key = (ia, ib) if ia < ib else (ib, ia)
            if key in seen_pairs:
                continue
            seen_pairs.add(key)
            ma, mb = members_of(a), members_of(b)
            fa, fb = ma[0], mb[0]
            shared = set(ma) & set(mb)
            if shared and fa != fb and (fa in shared or fb in shared):
                matched.append((key[0], key[1]))
        if truncated:
            break
    if iters:
        # 还有候选对没看完（预算用尽）：计数与 drift 列表都只是下界。
        truncated = True
    if matched:
        cap = 6
        drift = []
        for ia, ib in sorted(matched)[:cap]:
            a, b = order_g[ia], order_g[ib]
            ma, mb = members_of(a), members_of(b)
            fa, fb = ma[0], mb[0]
            shared = set(ma) & set(mb)
            moved = fa if fa in shared else fb
            head_of = gid(a) if moved == fa else gid(b)
            other = gid(b) if moved == fa else gid(a)
            drift.append(f"{gid(a)}/{gid(b)}: {shield(moved)} is first in {head_of} but not in"
                         f" {other} (firsts {shield(fa)} vs {shield(fb)})")
        extra = ""
        if len(matched) > cap:
            extra = f" (+{len(matched) - cap} more pairs not listed)"
        out.append("order-like groups share a member but do not start with it the same way: "
                   + "; ".join(drift) + extra +
                   " -> two readings, the tool cannot tell them apart: deliberate non-anchoring"
                   " (pattern 13 allows it) or magpie's own later rewrite moved the first member"
                   " (pitfall 3, one local observation)")
    if truncated:
        # 截断披露必须独立于「有匹配」：搜索没走完却一条都没匹配上时，披露句若挂在
        # matched 分支里就永远不执行，输出直接是「none」——把「没查完」说成「查过且干净」。
        out.append("the shared-member pair scan stopped early (budget reached before every"
                   " candidate pair was examined): this report's drift list is a lower bound"
                   " and pairs that were never examined may be missing from it entirely;"
                   " a 'none' above does not mean the file is free of anchor drift")
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
            out.append(f"{gid(g)}: members at different effort {[t or '?' for t in ts]} (? = unparseable tier)"
                       " -> legal (pattern 3 'same model, two efforts'); cost: the turn that falls"
                       " back to another member repays the whole prefix (pattern 3, cost paragraph)")
            if mode in ("usage", "rotate", "weight"):
                out.append(f"{gid(g)}: {mode} assumes interchangeable members;"
                           " different effort conflicts with that premise (pattern 2, evidence 2)")
    notes.extend(first_member_note(order_g))
    return out, notes


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
        print("note: validate.py is not loadable from here -> group ids, first members and the"
              "\n      classifier column below are SHAPE SUMMARIES (<ref N chars>), not names;"
              "\n      routing/affinity appear verbatim only when they are known enum words. This"
              "\n      is not a readable inspection table; fix the install and re-run.")
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
    masked_first = {}
    for g in groups:
        cls = shield(g.get("classifier")) if g.get("classifier") else "-"
        # members 可能是 null 甚至非列表（magpie 自建的空组、pattern-only 组、畸形配置）→ 按空处理
        mem = members_of(g)
        pat = len(match_of(g))
        extra = f" match={pat}" if pat else ""
        # 粘性取值与首位成员都要打出来：magpie 曾被观测到重排 members（见 docs/patterns.md 坑 3），
        # 「落盘后回读首位与 affinity」这一步没有这两个读数就无从执行。首位只对 order 类有意义。
        first = ""
        if mem and g.get("routing", "smart") in ORDER_LIKE:
            mf = shield(mem[0])
            masked_first.setdefault(mf, set()).add(str(mem[0]))
            first = f" first={mf}"
        aff = g.get("affinity", "(unset)")
        # 空串是「配了但配成空」，与「没这个键」（`(unset)`）是两回事；打成空列会被读成串行。
        # **非字符串也不是空**：`routing: ["order"]` 这种畸形值打 `(empty)` 是一句事实为假的话——
        # 它配了，只是配得不成样子（校验段确实会报 `unknown mode '['order']'`，可组行已经被读完了）。
        rv = g.get("routing", "smart")
        if isinstance(rv, str):
            rv = rv if rv else "(empty)"
        else:
            rv = "(invalid)"
        if isinstance(aff, str) and not aff:
            aff = "(empty)"
        print(f"  {gid(g):<14} routing={shield(rv):<8} members={len(mem)}{extra}"
              f" affinity={shield(aff)} classifier={cls}{first}")
    # 形态摘要不是身份：两条**不同**的成员串掩完可能一模一样（同长度的 `acme/<model N chars>:high`
    # 就会撞）。这一列是给人核对「首位有没有被挪走」用的，塌成同串时必须当场说破——否则配上
    # `shape findings: none`，读者会把它坐实成「两组同锚同档」。
    collided = sum(1 for m, raws in masked_first.items() if len(raws) > 1)
    if collided:
        print(f"note: {collided} masked first= form(s) above stand for more than one underlying ref."
              " Masked forms are shapes, not identities — do not read this column as proof that two"
              " groups share an anchor.")
    rc, out, err = run_validate({"groups": groups}, known)
    # 校验器崩了 ≠ 校验通过：把这点显式打出来，否则下面 `shape findings: none` 会被读成体检合格
    # 判据在 `validate.validator_crashed`（apply 用的是同一个）：**只看 stderr**，且头部行必须是
    # 第一条非空行。stdout 是校验器的判决——把它混进来判，就等于允许「值里造一行 Traceback」
    # 冒充崩溃（实测：普通不合格被报成崩溃，形状诊断整段消失）。
    # **载入不了 validate.py 时不需要第二份崩溃判据**：那种情况下 `run_validate` 根本没起子进程
    # （它直接返回「validation not run」，stderr 为空），手上没有崩溃报告可判。这里原先留着一份
    # 同形副本，注释还写着「两份口径由 e2e 的必崩夹具钉一致」——那句话是假的：e2e 的 crashkit
    # （第 75/118/126 条）与第 67 条注入的都是**能载入**的 validate.py（`_V` 非 None），而 `_V` 为
    # None 时 err 恒为空，那份副本在任何可达路径上都不会被执行。判据只留一处。
    crashed = _V.validator_crashed(err) if _V is not None else False
    print("validation:")
    print(out)
    if crashed:
        print(err)                  # 崩溃报告在 stderr；stdout 这时没有判决
        print("note: the validator CRASHED on this config (traceback above) — no validation verdict;")
        print("      the shape findings are therefore not printed at all (a crash can make the")
        print("      shape pass read malformed structures — anything it says would be luck)")
    issues, shape_notes = find_shape_issues(groups)
    # 段名刻意保持短（`shape findings:`），限定语放下一行——文档要能逐字指到这段。
    # 限定语说「每条各自 schema 合法、validate 不 enforce 这些」，不说「validate 会接受这份配置」：
    # 同一份配置可能另有 FAIL，那时后者就是假话。
    print("shape findings:")
    print("  (each one is schema-legal on its own — validate does not enforce these")
    print("   when a finding cites a pattern/evidence/pitfall number, that section is in docs/patterns.md")
    print("   (that document is Chinese-only — the output you are reading is English)")
    print("   single-member advisories cover every routing mode except manual and skip"
          " pattern-pooled (match) groups; first-member ones only order-like)")
    if crashed:
        # 崩溃时形状判据可能正读到畸形结构，那段不是结论——所以**一条都不打**，
        # 否则「not evaluated」与下面的结论同时出现，读者不知道该信哪半。
        print("  not evaluated: the validator crashed above, so this section is not a verdict")
    else:
        # `none` 只在「查过了、没有发现」时打。有射程披露时不打它：`none` 与「这部分没得比」
        # 同屏出现，读者只会记住前一个（这一段本来就是给人扫的）。
        if issues:
            for line in issues:
                print(f"  {line}")
        elif not shape_notes:
            print("  none")
        for line in shape_notes:
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
