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

VALIDATE = Path(__file__).resolve().parent / "validate.py"   # 与 apply/render 同目录那份（单真源）
# 复用 validate.py 的密钥判定（单真源）。-I 模式下脚本目录不在 sys.path，故按路径加载。
_spec = importlib.util.spec_from_file_location("magpie_validate", VALIDATE)
_validate = importlib.util.module_from_spec(_spec)
try:
    _spec.loader.exec_module(_validate)
except Exception as exc:    # 少文件、不可读、以及「文件在但语法坏了」都是安装坏了，不该甩 traceback
    sys.exit(f"FAIL: cannot load validate.py next to apply.py ({exc}) — the validation and"
             " redaction tables live there; fix the install and re-run")
# 载进来了不等于判据齐：一份缺函数的半成品副本会在**跑到一半**时才 AttributeError——
# 那时可能已经写完盘（apply 的写后校验正要调 derive_known / validator_crashed），
# 使用者看到的是 traceback 加一句「已写入」，而不是「我没跑」。所以启动时按 validate 自带
# 的 PUBLIC_API 逐名核，缺就停下。名单只读那一份表，本机不抄第二份。
_names = getattr(_validate, "PUBLIC_API", None)
_missing = ("PUBLIC_API",) if _names is None else tuple(n for n in _names if not hasattr(_validate, n))
if _missing:
    sys.exit("FAIL: validate.py next to apply.py loaded but is missing "
             + ", ".join(_missing)
             + " — that file is a partial copy, and the validation and redaction tables live"
             " there; refusing to run rather than failing halfway through a write")
# endpoint 不在 validate 的密钥形态常量里，但同样承诺不回显。
# 形态表放在 validate（单真源）：doctor 的输出面要用同一套判据，抄第二份就会漂。
ENDPOINT = _validate.ENDPOINT_SHAPE


def secretish(v):
    """存量组【不经校验】（校验的是合并结果），回显前先自查密钥/endpoint 形态。
    命中就把整组的 diff 降级成形态摘要——宁可少显示，不可把凭据打进上下文。
    这张表**刻意比逐串 shield 粗**：只看凭据形态 + endpoint 形态，不含熵判据。整组降级
    很贵（一个长 token 会把整组 diff 全变成形态摘要），而漏下来的部分仍有逐串 shield 兜底。
    判据走 validate 的**单真源**入口（`looks_secret` / `looks_endpoint`）：它们先剥控制字符
    再判形态——直接用正则 search 会让换行切断一条连续凭据，整组降级随之失效。"""
    if isinstance(v, str):
        return bool(_validate.looks_secret(v) or _validate.looks_endpoint(v))
    if isinstance(v, list):
        return any(secretish(x) for x in v)
    if isinstance(v, dict):
        return any(secretish(k) or secretish(x) for k, x in v.items())
    return False


def run_validate(groups_doc, known):
    """黑盒复用 validate.py：提取 groups + known 写临时文件，subprocess 校验。

    返回 (rc, stdout, stderr) 三份，**不合并**：崩溃判定只能看 stderr——未捕获异常的
    traceback 走 stderr，stdout 是校验器给出的判决。混在一段文本里判就等于允许
    「值里造一行 Traceback」冒充崩溃（普通不合格会被说成「校验器崩了」）。

    **崩溃判定必须排在「没判决」之前**：崩溃的那次同样一行判决都没打，先判 no_verdict 就会把
    traceback 整个吞掉，只剩一句「没跑出判决」——使用者丢掉唯一能定位问题的报告。
    连临时文件都写不出去（磁盘满 / 目录不可用）也算「没判决」：那是校验器根本没开跑，
    抛 traceback 给使用者只能得到 0 字节的 stdout。"""
    try:
        with tempfile.TemporaryDirectory() as td:
            gp = Path(td) / "groups.json"
            kp = Path(td) / "known.json"
            # 临时文件一律用 ASCII 转义写法落盘。配置里可能有「合法 JSON、但 UTF-8 编不出来」的字符
            # （孤立代理对，见 validate.utf8_encodable），原先这里按 UTF-8 写，**判决还没开始**就抛
            # traceback——使用者拿不到任何结论。转义写法解码回来是同一个串，校验判据不受影响。
            gp.write_text(json.dumps(groups_doc, ensure_ascii=True))
            kp.write_text(json.dumps(known, ensure_ascii=True))
            p = subprocess.run([sys.executable, "-I", str(VALIDATE), str(gp), str(kp)],
                               capture_output=True, text=True)
    except (OSError, ValueError) as exc:
        return None, _validate.NO_VERDICT_NOTE, f"could not run the validator: {type(exc).__name__}: {exc}"
    if _validate.validator_crashed(p.stderr):
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    if _validate.no_verdict(p.stdout):
        # 一行判决都没有 ≠ 合格。返回 rc=None 让调用方**必须**处理这第三种状态，
        # 而不是顺着 `rc != 0` 掉进「你的配置不合格」——那也是一句假结论。
        return None, _validate.NO_VERDICT_NOTE, p.stderr.strip()
    return p.returncode, p.stdout.strip(), p.stderr.strip()


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
            # 组 id 是用户可控串：报错信息里也要过 shield（有人把凭据贴进 id 时，这条会先于校验打出来）
            return (f"{label} groups[{i}] duplicates group id {_validate.shield(gid)!r}"
                    " (upsert would silently drop one)")
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
        # echo=True 不等于「原样打」：echo 只是「这类字段允许回显」，具体回显什么仍由 shield 决定
        # （`#账号` 段、点分域名、高熵串都要掩）。allowlist 挡不住无已知前缀的 token。
        return _validate.shield(v) if echo else f"<text {len(v)} chars>"
    if isinstance(v, (bool, int, float)):
        return str(v)
    if isinstance(v, list):
        return f"[{len(v)} items]"
    if isinstance(v, dict):
        return f"{{{len(v)} keys}}"
    return f"<{type(v).__name__}>"


def core_of(raw):
    """模型引用的**核心**（剥掉 `#账号` 段）：`prov/model:high#acct` → `prov/model:high`。
    「换了模型」与「只换了通道」的区别就在这里——核心变了是换模型，核心没变是换通道。"""
    return raw.split("#", 1)[0] if isinstance(raw, str) else raw


def is_model_ref(v):
    """是不是模型引用形态（含 `/` 且不是 URL）。自由文本不是模型引用，不能拿模型那套措辞描述它。"""
    return isinstance(v, str) and "/" in v and "://" not in v


def pair_kind(a, b, same_core_elsewhere=False):
    """两个引用掩完后同形时，这次改动属于哪一类（**列表元素**用这张表）：
    'chan'   —— 核心没变，差别只在 `#账号` 段（换通道）；
    'model'  —— 核心变了（换模型/供应商/档位/条目），即使核心本身被掩成同形；
    'unsure' —— 核心变了且两边都被掩，**分不清**是换了模型还是换了通道。
    自由文本也走这张表（核心就是整串）：列表字段里的元素换掉就是换了条目。
    **入参必须是字符串**（调用方保证：`pair_masked` 先过类型闸，`change_kind` 先过 `is_model_ref`）。
    这张表整张都在讲「模型引用 vs 通道」，喂进非字符串就是拿措辞造对象，还会直接 TypeError。"""
    ca, cb = core_of(a), core_of(b)
    if ca == cb:
        return "chan"
    if ("#" not in a and "#" not in b) or \
            (_validate.shield(ca) == ca and _validate.shield(cb) == cb):
        # 核心引用本身可读且不同 → 确实换了模型；两边都没有账号段时也一样
        # （差异只可能在模型引用上）。
        return "model"
    # 核心被掩了，但 `#账号` 段两侧**逐字相同**：通道没变，差异只可能落在被掩的那一段
    # （provider / 模型 / 档位）。这就是一次确定的换条目，说「分不清」是事实为假的保守话。
    # 方向上只往「更确定」走，不多泄：措辞仍然只讲两侧都被掩、新值不给看。
    # **但这条只在配对本身可信时用**：`same_core_elsewhere` 为真表示另一侧还存在**核心引用相同**的
    # 元素、只是掩后不同形（账号段是可见短标签时就是这样：同一个模型换通道，两侧形态跟着变）。
    # 那时手上这条配对是**配错了**的对子，「条目被换掉」就成了事实为假的断言（实测：两条各换通道
    # 被打成「2 条换了模型引用」）。配不准就是分不清，退回 unsure，不硬升级为更强的结论。
    if ("#" in a and "#" in b and a.partition("#")[2] == b.partition("#")[2]
            and not same_core_elsewhere):
        return "model"
    # 核心引用也被掩了、账号段也不同：分不清是换了模型还是换了通道——**明说分不清**，
    # 不许二选一给一句可能是假的断言。
    return "unsure"


def change_kind(a, b):
    """标量字段用：只有**模型引用形态**才配谈「换模型 / 换通道」；
    自由文本（note、where 的值…）返回 None——那种只能说「值被扣下了」。"""
    if not (is_model_ref(a) and is_model_ref(b)):
        return None
    return pair_kind(a, b)


EMPTY_BUCKETS = {"chan": 0, "model": 0, "unsure": 0}   # 桶名单真源，见 change_counts


def pair_masked(gone_raw, came_raw, gone, came):
    """把「按本面掩后同形」的两侧元素配对，返回 `[(gone 下标, came 下标, kind), ...]`。

    **成员列表与规则 more 列表共用这一个函数**：同一个说法在两处必须同义，否则 diff 段自己就
    自相矛盾（实测过：同一批改动放进 members 是三句、放进 more 少一句）。
    `gone`/`came` 由调用方按**自己那一面**掩好传进来（echo 面是 shield，整组降级面是 `<text N chars>`）——
    配对的「同形」必须按那一面判，不能在这里替调用方决定。
    候选里优先挑**核心引用相同**的那条：多条元素掩成同一形态时按位置配会配错对子，
    下面「换模型还是换通道」就给出事实为假的断言。
    另外记下「另一侧是否还有核心相同但没配上的元素」（`same_core_elsewhere`）：那说明本条配对
    本身可信度不足，`pair_kind` 据此拒绝把「分不清」升级成「条目被换掉」。
    """
    used, pairs = set(), []
    for i, x in enumerate(gone):
        # **两侧都是字符串才配得上这条对**。`pair_kind` 那张表讲的全是「模型引用 vs 通道」：
        # 拿它比一个非字符串元素，轻则给一句关于模型/通道的假断言，重则直接 TypeError（实测：存量组
        # `match: [5]` 配草案 `match: ["5"]`，dry-run 与 --write 都甩 traceback，使用者一行判决都
        # 拿不到）。别指望上游拦掉——**存量侧的元素不过 validate**：合并结果里这个字段的值是草案侧的，
        # 校验器根本看不见旧值长什么样。类型畸形只能在这里防。
        # 不配对不等于「没变化」：它们仍留在 gone/came 里，照原样打成 `-旧 +新`（非字符串按形态渲染），
        # 那读起来就是「这条条目被换掉了」，不带任何关于模型或通道的断言。
        if not isinstance(gone_raw[i], str):
            continue
        cands = [k for k, y in enumerate(came)
                 if y == x and k not in used and isinstance(came_raw[k], str)]
        if not cands:
            continue
        ci = core_of(gone_raw[i])
        j = next((k for k in cands if core_of(came_raw[k]) == ci), cands[0])
        used.add(j)
        skipped = any(k != j and core_of(came_raw[k]) == ci for k in range(len(came_raw)))
        pairs.append((i, j, pair_kind(gone_raw[i], came_raw[j], skipped)))
    return pairs


def change_counts(gone_raw, came_raw):
    """把「掩后同形」的成员配对，分成 chan / model / unsure 三类计数（判据见 `pair_masked`）。"""
    gone = [_validate.shield(x) if isinstance(x, str) else x for x in gone_raw]
    came = [_validate.shield(x) if isinstance(x, str) else x for x in came_raw]
    counts = dict(EMPTY_BUCKETS)
    for _, _, kind in pair_masked(gone_raw, came_raw, gone, came):
        counts[kind] += 1
    return counts


def diff_pair(a, b, echo=False):
    """`旧 → 新` 的渲染。两侧掩完一模一样时不能就这么打出来：改动是真的，只是差别落在
    看不见的那部分。照原样打等于告诉使用者「这两边相同」，那是谎报。

    三种「看不见」要分清楚，说错就是骗人：
    - 字符串、且确实有一**段**被掩（`#账号` 换通道最常见）→ 「差别落在被掩的那段」；
    - 字符串、但整条值被扣下只给形态（自由文本字段）→ 「值被扣下了，两边确实不同」；
    - 容器（dict/list）塌成同一形状 → 「只有形状，差异在形状里面」——这是结构信息不足，
      说成「被掩那段」会把人引到凭据上去猜。
    """
    x, y = brief(a, echo=echo), brief(b, echo=echo)
    if x == y and not same(a, b):
        if isinstance(a, str) and isinstance(b, str):
            # 三态措辞**只对「这一面真的按段掩过」成立**：echo=False 时整条值是被扣下给形态的，
            # 那一行里没有任何一段被掩过——说成「差别落在被掩那段」或「两边都被掩」都是假的。
            # 判据必须看本面的 echo，不能只看**值的形态**：`note` 里写一条模型引用太常见了
            # （`route acme/m:high#team-a`），只看形态就会拿「模型引用被换掉」去描述自由文本。
            kind = change_kind(a, b) if echo else None
            if kind == "chan":
                return f"{x} → {y} (differ only inside a masked segment)"
            if kind == "model":
                # 核心引用变了：说成「只换了通道」就是骗人（审批者会以为成本很低，实际换了模型）。
                return (f"{x} → {y} (the reference itself was replaced — both sides are"
                        " masked, so the new value is not shown)")
            if kind == "unsure":
                return (f"{x} → {y} (the model and the channel cannot be told apart —"
                        " both sides are masked)")
            if echo and (_validate.shield(a) != a or _validate.shield(b) != b):
                return f"{x} → {y} (differ only inside a masked segment)"
            return f"{x} → {y} (the value is withheld; the two values differ)"
        return f"{x} → {y} (shape only: the values differ inside)"
    return f"{x} → {y}"


def canon(v):
    """类型敏感的规范形态：Python 的 1 == True == 1.0 会把真实改动判成没变，所以按 JSON 写法比。
    单独抽出来是为了**能进集合**：列表两侧做差时，`any(same(x, y) …)` 是 O(n²) 且每步都重新
    dumps 一整棵子树（实测 1500 个成员的单次 dry-run 光这段 4.4 秒）；规范形态算一次、进集合，
    存在性判断变 O(1)，语义不变（存在性比较本来就等价于「规范形态在对侧集合里」）。"""
    return json.dumps(v, sort_keys=True, ensure_ascii=False)


def same(a, b):
    """类型敏感比较：Python 的 1 == True == 1.0 会把真实改动判成没变。"""
    return canon(a) == canon(b)


def seq(v):
    """列表字段归一：magpie 会落盘 null（纯模式组 / 自动发现组），与 [] 语义相同。"""
    return [] if v is None else v


def refs(v, echo=True):
    return [_validate.shield(x) if isinstance(x, str) and echo else brief(x) for x in v]


def conds(w, echo=True):
    """where 条件摘要：field/op 是枚举可回显，value 可能是路径等自由文本 → 只给形态。"""
    if not isinstance(w, list):
        return brief(w)
    parts = []
    for c in w:
        if not isinstance(c, dict):
            parts.append(brief(c))
            continue
        # `field`/`op` 看着像枚举，但 validate **从不校验它们的取值**（只要求键存在），存量侧也
        # 不过校验 → 只放过白名单里的值，其余按自由文本给形态（`op` 的全集未实测，白名单刻意保守）。
        def echo_enum(val, table):
            return val if isinstance(val, str) and val in table else brief(val)
        s = f"{echo_enum(c.get('field'), _validate.ECHO_WHERE_FIELDS)}" \
            f" {echo_enum(c.get('op'), _validate.ECHO_WHERE_OPS)}"
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
                left, right = conds(a, echo), conds(b, echo)
                note = "" if left != right else " (the values are withheld; the two differ)"
                out.append(f"{tag}.where: {left} → {right}{note}")
            elif k == "more":
                aa = refs(seq(a), echo) if isinstance(a, list) or a is None else [brief(a)]
                bb = refs(seq(b), echo) if isinstance(b, list) or b is None else [brief(b)]
                note = ""
                if aa == bb and not same(a, b):
                    # 临时变量别叫 aa/bb：那是上面刚算好的**掩后**渲染值，覆盖掉就等于
                    # 把未掩的账号段打进 diff（这条正是被脱敏断言抓住的）
                    sa, sb = seq(a), seq(b)
                    ka, kb = {canon(x) for x in sa}, {canon(x) for x in sb}
                    gone_raw = [x for x in sa if canon(x) not in kb]
                    came_raw = [x for x in sb if canon(x) not in ka]
                    # echo=False 时元素是整条被扣下的（`<text N chars>`），不是「按段掩」：
                    # 三态桶在那一面上一句都不该说，与 diff_pair 同一个口径。
                    # 三态桶只在 echo 面上取。echo=False 时元素是整条被扣下的 `<text N chars>`，
                    # 不是「按段掩」，那一面上一句都不该说（与 diff_pair 同一个口径）——但**别取空
                    # dict**：下面每个桶都要按 key 索引，空 dict 会让这里 KeyError 崩溃，dry-run 与
                    # --write 一起走不下去，而崩的正是「存量侧不过校验、必须整组降级」这条路径（实测）。
                    counts = change_counts(gone_raw, came_raw) if echo else dict(EMPTY_BUCKETS)
                    # 每个非零桶**各打一句**：用 if/elif 链只报第一个桶，会把「分不清」的那部分
                    # 整个吞掉——同一批改动放进 members 时三句都在，放进 more 少了��句。
                    parts = []
                    if counts["model"]:
                        parts.append(f"{counts['model']} entry/entries: the reference itself was"
                                     " replaced — both sides are masked, so the new value is not shown")
                    if counts["unsure"]:
                        parts.append(f"{counts['unsure']} entry/entries: the model and the channel"
                                     " cannot be told apart — both sides are masked")
                    if counts["chan"]:
                        # 措辞按字段族走：成员列表用 `changed only inside a masked segment`，
                        # 标量与 more 用 `differ only inside a masked segment`（既有约定）。
                        parts.append(f"{counts['chan']} entry/entries differ only inside a"
                                     " masked segment")
                    if parts:
                        note = " (" + "; ".join(parts) + ")"
                    else:
                        note = (" (differ only inside a masked segment)"
                                if echo else " (the values are withheld; the two differ)")
                out.append(f"{tag}.more: {' '.join(aa) or '(unset)'} → {' '.join(bb) or '(unset)'}" + note)
            elif k == "intent":
                # 两侧都只给形态。**「草案侧已过校验」不是回显的理由**：校验只拒已知前缀的凭据，
                # 而靠连字符/下划线分隔的长 token 与两段内网主机名都能过校验（熵判据刻意不认它们，
                # 免得吃掉真实模型名）——放过去就是把它打进终端、再进上下文与工单。
                # `intent` 是自由文本（docs/schema.md），不在 ECHO_RULE_FIELDS 里，就该按自由文本处理。
                # 走 diff_pair(echo=False) 而不是自己拼两个 brief()：等长改动时通用那句
                # 「the value is withheld; the two values differ」必须也在——否则同一份改动落在 `note`
                # 上有说明、落在 `intent` 上只剩 `<text 6 chars> → <text 6 chars>`，读起来像「没改」，
                # 而 intent 恰恰是意图分发的判据，批准写入时看不见它被换掉了。
                out.append(f"{tag}.intent: {diff_pair(a, b, False)}")
            else:
                e = echo and k in ECHO_RULE_FIELDS
                # 规则的键来自**存量侧**（不过校验），野键可能是任何东西——合法键（use/more/where…）是
                # 短词，过 shield 原样通过；怪键才会被换成形态摘要。
                out.append(f"{tag}.{_validate.shield(k)}: {diff_pair(a, b, e)}")
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
        # 集合差必须在**原文**上算，只在渲染那一刻掩：先掩后比会让两条只差账号段的成员串塌成
        # 同一个形态 → gone/came 皆空 → 真实改动被报成 `order changed`（等于没报）。
        ka, kb = {canon(x) for x in a}, {canon(x) for x in b}
        gone_raw, came_raw = [x for x in a if canon(x) not in kb], [x for x in b if canon(x) not in ka]
        gone, came = refs(gone_raw, echo), refs(came_raw, echo)
        # 掩完之后两侧长得一样：改动是真的，差别落在被掩的那段——照实说，别谎报成换序。
        # 同形配对按**多重集**认，不按位置：换序写法（存量 `[A#x, B#y]` → 草案 `[B#y', A#x']`）在位置
        # 配对下一对都对不上，标注整条丢失，打出来的 `-A -B +B +A` 读起来像「把两条一样的串挪了个位置」，
        # 而真实改动是两条都换了通道。
        # **但多重集在形态全都相同时会退化成按位置**：多条成员掩成同一形态（模型段被掩）时，
        # 配对挑错一条，下面的「换模型还是换通道」就会给出**事实为假的断言**（实测：
        # 两个模型只是各换了通道，工具却说「模型引用被换掉」）。所以配对时优先挑
        # **核心引用相同**的那条（原串剥掉 `#账号`）——那是「同一个模型换了通道」。
        # 配对与分桶的判据住在 `pair_masked`（more 列表用的是同一个），这里只管渲染。
        pairs = pair_masked(gone_raw, came_raw, gone, came)
        hidden = {i for i, _, _ in pairs}
        used = {j for _, j, _ in pairs}
        gone, came = [x for i, x in enumerate(gone) if i not in hidden], \
                     [y for k, y in enumerate(came) if k not in used]
        if gone or came:
            lines.append(f"{key}: " + " ".join(["-" + x for x in gone] + ["+" + x for x in came]))
        if pairs:
            # 「看不见的改动」分两种，混成一句就是在骗人：
            # ① 只是**账号段**不同（`#账号` 换通道）→ 模型没变，说「差别落在被掩的那段」；
            # ② **模型引用本身**变了（换了模型/供应商/档位）→ 这是批准写入时最该看见的一种，
            #    说成 ① 会让人以为只是换了通道。判据：剥掉 `#账号` 之后两侧的核心引用是否相同。
            #    整组降级时（echo=False）成员整条被扣下、连核心引用都读不到，此时只有一句通用说法。
            if echo:
                chan = model = unsure = 0
                for _, _, kind in pairs:
                    if kind == "chan":
                        chan += 1
                    elif kind == "model":
                        # 核心引用本身变了 → 确实换了模型。
                        model += 1
                    else:
                        # 核心引用也被掩了（或配对本身就不可信）：分不清是换了模型还是换了通道——
                        # **明说分不清**，不许二选一给一句可能是假的断言。
                        unsure += 1
                if chan:
                    lines.append(f"{key}: {chan} entry/entries changed only inside a masked segment"
                                 " (the change is real; the differing part is not shown)")
                if unsure:
                    lines.append(f"{key}: {unsure} entry/entries: the model and the channel cannot"
                                 " be told apart (both sides are masked)")
                if model:
                    # 措辞按字段走：`members` 里换的确实是模型引用；`levels`/`fast`/`ultra` 这些
                    # 列表换的是**条目**，说成「模型引用被换掉」就是拿字段当事实。
                    what = ("the model reference was replaced" if key == "members"
                            else "the entry was replaced")
                    lines.append(f"{key}: {model} entry/entries: {what}"
                                 " (both sides are masked, so the new value is not shown)")
            else:
                lines.append(f"{key}: {len(pairs)} entry/entries"
                             " the values are withheld (shape only); the entries differ"
                             " (the change is real; the differing part is not shown)")
        if not gone and not came and not pairs:
            if len(a) != len(b):
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
            # 同上：被替换组的存量侧不过校验，键名也要过 shield（合法字段名不受影响）。
            lines.append(f"{_validate.shield(key)}: {diff_pair(a, b, e)}")
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
        original_text = target_path.read_text()      # 留原文：写前要拿它跟磁盘上的现状比对
        target = json.loads(original_text)
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
        known = _validate.derive_known(target)
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
    rc, out, err = run_validate({"groups": merged}, known)
    if rc is None:
        # 校验器一行判决都没打（退 0、被杀、连临时文件都没写出去，都算）：没有判决。
        # 这**既不是**合格**也不是**不合格，更不等于可以继续写盘——
        # 落进下面的 `rc != 0` 会给出「你的配置不合格」这句假结论，而放任它通过就是拿使用者的线上
        # 配置给一份没跑成的校验背书（实测：不存在的模型引用被写进文件，还宣布 validation PASS）。
        print("FAIL: the validator produced no verdict at all (no PASS/FAIL line on its output);"
              " nothing merged — that is not a pass")
        if err:
            print(err)   # 有的场合有具体原因（写不出临时文件），有的场合一个字都没有
        else:
            print("hint: the validate.py next to apply.py is most likely a partial copy; re-copy the"
                  " whole scripts/ directory and re-run")
        return 1
    if rc != 0:
        # 崩了 ≠ 不合格：那种情况下**没有**任何关于配置的结论，把锅指给使用者的配置是假结论。
        if _validate.validator_crashed(err):
            print("FAIL: the validator CRASHED while checking the merged config; nothing merged"
                  " — the text below is a crash report, not a verdict on your config")
            print(err)              # 崩溃报告在 stderr；stdout 这时是空的
        else:
            print("FAIL: merged result would not pass validation; nothing merged")
            print(out)
            # 这条指引只属于「有 findings」的场合。崩溃分支里没有 findings，跟在崩溃报告
            # 后面打它等于凭空造出一个不存在的对象，读者会回头在 traceback 里找「findings」。
            print("hint: findings in groups you are not replacing come from the existing config;"
                  " inspect it with doctor.py")
        return 1
    result = dict(target)
    result["groups"] = merged

    # 2. 组级 diff 摘要（脱敏）
    def n_members(gid):
        g = next((x for x in merged if x.get("id") == gid), {})
        mem = g.get("members")
        return len(mem) if isinstance(mem, list) else 0
    def label(gid):
        """组 id 同样过闸门：凭据形态会被 validate 先拒，但 endpoint 形态不会，
        而 keep/add 列表里的 id 不经 group_diff，故这里必须自查。"""
        # 组 id 也要过 shield：`secretish` 是前缀名单（sk-/ghp_/AKIA…），无已知前缀的高熵 id
        # 会整串进 merge plan（实测 `keep (1): <id>`）。判定交给单真源。
        return _validate.shield(gid)
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

    # 3. --write：写前**重读目标** → 备份（保留原权限）→ 写入 → 读回磁盘校验，失败自动恢复
    #
    # 写前重读是并发守卫：合并结果是按**读档时**的内容算的。目标文件在这期间被别人改过
    # （magpie 自己会回写、另一个 apply 也会写），拿旧结果盖上去＝静默丢掉对方的改动，
    # 而且工具还会报「OK」。实测过：在 apply 运行的窗口里注入一个组，那组会被抹掉而
    # apply 毫无察觉。所以这里宁可不写：改了就说改了，让使用者重跑。
    try:
        current_text = target_path.read_text()
    except (OSError, ValueError) as exc:
        # ValueError 也要接：读的是**字节解码**，不只是打开文件。目标里若有按 UTF-8 解不出来的字节，
        # 这里抛 UnicodeDecodeError（ValueError 的子类）——这一刻校验已经过了、备份还没建，
        # 甩 traceback 的使用者不知道自己到底动没动过配置。这里还没碰目标文件，说清楚就能干净退出。
        print(f"FAIL: cannot re-read {target_path} before writing: {exc}")
        print("nothing was written; re-run.")
        return 1
    if current_text != original_text:
        print(f"FAIL: {target_path} changed on disk while this run was in progress; nothing was written.")
        print("the merge plan above was computed from the older content — applying it would"
              " silently drop the other writer's changes, so this run stops here.")
        print("re-run against the current file (no backup was needed: nothing was written).")
        return 1
    original = current_text
    backup = backup_path(target_path)
    try:
        backup.write_text(original)
        os.chmod(backup, stat.S_IMODE(target_path.stat().st_mode))
    except (OSError, ValueError) as exc:
        # ValueError 不是可选项：磁盘上的原文里可能有「合法 JSON、但 UTF-8 编不出来」的字符
        # （孤立代理对），那时备份**写不出来**——原先这里只剩一句 traceback，使用者不知道
        # 自己的配置到底动没动。这一刻还没碰目标文件，说清楚就能干净退出。
        # 备份都建不出来 → 什么都没改，直接干净退出（别把 traceback 当结论）
        print(f"FAIL: cannot create the backup next to {target_path}: {exc}")
        print("nothing was written; fix the file/directory permissions and re-run.")
        return 1

    def restore(reason):
        # 写回的是**写盘前读到的原文**（内存副本），不是从备份文件读回来——措辞要如实说，
        # 事故复盘时这两者不是一回事。写回失败也不能抛 traceback：这一刻正是「原配置可能
        # 不可恢复」的关键时刻，必须给出可读 FAIL 与备份路径。
        try:
            target_path.write_text(original)
        except (OSError, ValueError) as exc:
            # 原文本身可能编不成 UTF-8（见上面的备份分支），那时「写回原文」这件事根本做不到：
            # 只能给可读 FAIL + 备份路径，绝不能在这里抛 traceback——这一刻正是
            # 「原配置可能不可恢复」的关键时刻。
            print(f"FAIL: {reason}")
            print(f"could not write the original config back ({exc}); the backup was kept at:"
                  f" {backup}")
            return 1
        print(f"FAIL: {reason}")
        print("restored the original config from the copy taken before the write (not from"
              f" the backup file); the backup was kept at: {backup}")
        return 1

    try:
        # allow_nan=False：NaN/Infinity 不是合法 JSON，写出去会让别的解析器读不回来。
        # validate 已经拒了非有限数，这里是双保险（万一将来哪条路径绕过了校验）。
        # **原子落盘**（与 render 同一写法）：`write_text` 是先 O_TRUNC 截断再写，中途失败（磁盘满、
        # 超过单文件大小上限、进程被杀）会在**活配置**的位置留下半份文件——apply 自己那套「读回比对 +
        # 写回原文」根本不会跑，因为跑它的进程已经死了；下一次 magpie 读档直接解析失败。备份还在，
        # 但没有任何东西提醒使用者去看它。同目录临时文件写完再 replace：replace 之前目标始终是完整的
        # 旧内容，失败时要么旧的全在、要么新的全在，没有第三种状态。换 inode 的两条代价一并搬过来：
        # 按 realpath 落点建临时文件（不把指向它的符号链接换成普通文件）、权限位显式搬过去
        # （临时文件默认 0600，直接 replace 会悄悄改掉原配置的权限）。
        text = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
        real = Path(os.path.realpath(str(target_path))) if target_path.exists() else target_path
        if real.exists() and not os.access(str(real), os.W_OK):
            # **原子替换会绕过只读位**：把 0444 的配置换成一个新 inode，写就成功了——可那个只读位
            # 正是使用者自己立的护栏（「这份配置别动」）。绕过它就不是「更稳的写法」，而是一次静默
            # 覆盖，还是对一份使用者明确拒绝写入的文件。所以这里照旧拒绝；目录只读是另一回事
            # （那时临时文件都建不出来，走下面的 except）。
            raise PermissionError(13, "Permission denied (the target file is not writable)")
        fd, tmp_name = tempfile.mkstemp(dir=str(real.parent), prefix=".apply-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(text)
            if real.exists():
                os.chmod(tmp_name, stat.S_IMODE(real.stat().st_mode))
            os.replace(tmp_name, str(real))
        except BaseException:
            # 残片不留：配置目录里躺半份 JSON 同样是垃圾。
            # `unlink(missing_ok=True)` 是 3.8+ 的 API：3.7 上这里会甩 TypeError 盖掉真正的错因，
            # 读者拿到的是「unlink 报了个参数错」而不是「写盘失败」——自己接 FileNotFoundError
            # （语义与 missing_ok 相同）。
            try:
                Path(tmp_name).unlink()
            except FileNotFoundError:
                pass
            raise
    except (OSError, ValueError) as exc:
        # 原子落盘之后这条分支基本只剩「临时文件根本没写出去 / replace 没成」，目标通常原样未动。
        # 但去留判据仍然**读回比对**而不是推测写入方式：写失败不能无条件删备份——万一目标真被写坏了，
        # 唯一完好的副本就是刚建的备份，删掉它等于把原配置变成不可恢复；而文件也可能根本没被打开
        # （只读目录），那时备份确实是孤儿。判据：读回来与原文比对——一样说明没动过，删备份；
        # 不一样说明可能写坏了，写回原文。
        print(f"FAIL: could not write {target_path}: {exc}")
        try:
            intact = target_path.read_text() == original
        except (OSError, ValueError):
            # 读不回原文就按「可能写坏了」处理：这条分支会写回原文并留着备份，
            # 猜错方向的代价是不恢复（原配置可能已经是坏的）。
            intact = False
        if intact:
            # 「备份删掉了」与「备份删不掉」是两句话，不能说反：删不掉时读者按「没留备份」去找
            # 副本就找不到，而那里其实有一份。unlink 失败不是罕见边角（备份文件被别人改成
            # 只读、目录权限变了、同名目录顶上来了都会失败）。
            try:
                backup.unlink()
                kept = "nothing was written and no backup was kept"
            except OSError as exc:
                kept = (f"nothing was written; the backup could not be removed ({exc}) and is"
                        f" still there: {backup}")
            print(f"{kept}; the original config is untouched.")
            return 1
        try:
            target_path.write_text(original)
        except (OSError, ValueError) as exc2:
            print(f"the write failed part-way and the original config could not be written"
                  f" back either ({exc2}); the backup was kept at: {backup}")
            return 1
        try:
            backup.unlink()
            kept2 = "and no backup was kept"
        except OSError as exc:
            kept2 = (f"and the backup could not be removed ({exc}); it is still there: {backup}")
        print(f"the write failed part-way; the original config was written back {kept2};"
              " the original config is untouched.")
        return 1
    print(f"backup: {backup}")
    try:
        on_disk = json.loads(target_path.read_text())
    except Exception as exc:
        return restore(f"written file is not readable JSON: {exc}")
    if not isinstance(on_disk, dict) or non_groups(on_disk) != non_groups(target):
        return restore("providers section changed on disk; only groups may be merged")
    # 注意：这里**不**比「落盘的 groups == 我们写的 groups」——写坏与被别人改写在这时长得
    # 一模一样，分不出来；而写坏必须能回滚（下面那条恢复路径），所以宁可放过那个极窄的窗口：
    # 真正要挡的「读档到写盘之间被改过」由写前的重读守卫挡（那里能分清，因为磁盘上的内容
    # 与我们读到的原文不同）。
    rc, out, err = run_validate({"groups": on_disk.get("groups", [])}, known)
    if rc is None:
        # 写都写完了才发现校验器没跑出判决——这一刻不能宣布 PASS，也不能只说「检查没跑成」就退：
        # 文件已经被我们改过，必须按写盘失败同样对待，恢复原样。
        return restore("post-write check did not run: the validator printed no PASS/FAIL verdict"
                       + (f" ({err})" if err else " (a partial copy of validate.py?)")
                       + " — an unchecked config is not a written one")
    if rc != 0:
        if _validate.validator_crashed(err):
            print(err)
            return restore("post-write check could not run: the validator CRASHED on the on-disk"
                           " config (crash report above, not a verdict)")
        print(out)
        return restore("post-write validation of the on-disk config FAILED")
    print(f"OK: merged {len(merged)} group(s); post-write validation PASS")
    print("next: point your agent at the group you want (magpie <agent> group/<id>), send one request"
          " from a NEW session, then check that row in the routing log carries group.id"
          " (doctor.py prints the wiring smoke steps; wiring changes only affect new sessions).")
    # magpie 曾被观测到在之后的回写里重排 members（本机一次观测，触发规则未知，见 docs/patterns.md 坑 3）。
    # 刚写完的读回几乎总是等于草案（只有 magpie 恰好在写入窗口内插一手才会不同，本机没观测到）——
    # 那种断言查不到漂移，所以不做。漂移要这样查：稍后用同一份草案再跑一次 dry-run。
    print("recheck drift later: run this same draft again WITHOUT --write; a reorder shows up as"
          " 'members: order changed'. doctor.py's `shape findings:` section can also flag order-like"
          " groups (order/drain) that share the same member (model and tier) but start with different"
          " ones — that check reads"
          " only what's on disk, so it still works after magpie rewrote the file (it cannot tell drift"
          " from a deliberate non-anchored group). It needs two or more such groups: with a single"
          " order-like group there is nothing to compare against, and drift there is invisible.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
