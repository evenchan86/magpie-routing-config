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
import math
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
# 只用于**回显白名单**（apply 的 `where` 摘要），不参与任何校验（校验只看 where 的结构）：
# `field` 的取值集来自 docs/schema.md（实测+CLI，封闭）；`op` 的全集**未逐一实测**，所以这里只列
# 本机见过的——认不出来的一律按自由文本掩。把这张表当成「magpie 支持的 op 全集」是过度承诺。
ECHO_WHERE_FIELDS = {"tokens", "effort", "agent", "subagent", "message", "system", "last"}
ECHO_WHERE_OPS = {"lt", "gt", "lte", "gte", "eq", "ne", "is", "is not", "contains",
                  "does not contain", "starts with", "matches"}
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


# endpoint 形态分两条，因为它们在 `shield` 里的豁免不同：
#   scheme / host:port —— 出现即可疑，任何位置都掩掉。
#   三段以上点分域名（`api.invalid.example`）—— 只在【不是模型名段】的位置掩掉。
# 刻意不匹配【只含一个点】的串：模型名里带点很常见（版本号式写法），掩掉会让回显看不懂。
_SCHEME_PORT_SRC = r"(?:https?|wss?)://|[\w.-]+\.[a-z]{2,}:\d{2,5}"
_DOMAIN3_SRC = r"[\w-]+(?:\.[\w-]+){2,}"
ENDPOINT_SHAPE = re.compile(f"(?i)(?:{_SCHEME_PORT_SRC}|{_DOMAIN3_SRC})")   # 深度自查用（apply）
_SCHEME_PORT = re.compile(f"(?i){_SCHEME_PORT_SRC}")
_DOMAIN3 = re.compile(_DOMAIN3_SRC)
# 前缀名单永远追不上真实凭据：**无已知前缀的 token 也是 token**。
# 于是再加一条熵判据——串里**任意位置**出现 16+ 连续 alnum 就判熵（不是「整串长」才掩）。
# 阈值取 16：模型名里 `20241022` 这种 8 位数字段、`some-model-name-32b` 这种带连字符的长
# 名字都不受影响（分隔符把连续 alnum 切断了），
# `#账号` 段用 12（账号标签本来就是短词，熵高即掩；掩掉只损失标签可读性，不损失诊断）。
_ENTROPY = re.compile(r"[A-Za-z0-9]{16,}")
# 控制字符不参与「像不像凭据」的判断，但它会让一行输出变成两行（凭空造出工具自己的句子，包括
# 崩溃报告），OSC/BEL 这类转义还能改终端标题、响铃、把光标挪回去覆盖上一行。四个输出面共用
# 这一道：命中就把整串按 ascii 转义显示，身份仍然可读（`g-code\nfake`），但没有裸控制字符外溢。
# 覆盖集必须**包含 Python `str.splitlines()` 会切开的所有字符**，否则出现「转义表说安全、
# 判定器说这是行首」的缝隙：C0+DEL 之外还有 NEL(U+0085)、LS(U+2028)、PS(U+2029)——
# 崩溃判据正是按行首匹配的，漏掉它们就等于把「值伪造崩溃」的口子留着。
_CTRL = re.compile(r"[\x00-\x1f\x7f\x85\u2028\u2029]")
_ENTROPY_ACCT = re.compile(r"[A-Za-z0-9]{12,}")


def _acct_shield(acct):
    """`#账号` 段**唯一**的判定点：只有它自己像凭据/endpoint/高熵时才掩，否则原样（账号标签
    本来就是短词，能显示就显示）。单真源：`shield()` 的 `#` 入口分支与 model 段熵分支都调这一个
    函数——两处各写一份判据迟早漂，历史上就是这么差的。"""
    if not acct:
        return acct
    if SECRET_VALUE.search(acct) or ENDPOINT_SHAPE.search(acct) or _ENTROPY_ACCT.search(acct):
        return f"<account {len(acct)} chars>"
    return acct


def _redact_model(s):
    """三段点分域名落在 `provider/model` 的 model 段时**照样掩**：`acme/glm-5.1.flash` 与
    `acme/api.internal.example` 形态完全同形，任何只看落盘的规则都分不出——只能 fail closed。
    （曾按「model 段豁免」放过真实点分模型名，e2e 第 51 条随即把 `acme/<endpoint host>` 放过去。）
    代价用「保留骨架」抵掉一半：provider 前缀与尾部已知档位照打（`MEMBER_EFFORT` 里的词不是凭据，
    而漂移/档位判据必须读得到档位），只掩 model 段本体。"""
    head, sep, tail = s.rpartition("/")
    if not sep:
        return f"<ref {len(s)} chars>"
    if (_DOMAIN3.search(head) or _SCHEME_PORT.search(head)
            or _ENTROPY.search(head) or SECRET_VALUE.search(head)):
        # provider 段**自己**就是主机形态（`网关.internal.example/模型:high`）或自己就是那个高熵
        # token（`<20 位 alnum>/ops` 这种组 id 在 schema 上完全合法）时，没有可信骨架可留：只掩
        # model 段会把前半原样打出来，而整串熵判据是对**整串**算的、算完就丢。
        # 真实 provider id 都是短单段（`acme`、`vertex_ai`），代价只是少显示一层。
        return f"<ref {len(s)} chars>"
    suf = ""
    if ":" in tail:
        base, _, effort = tail.rpartition(":")
        if effort in MEMBER_EFFORT:
            suf, tail = f":{effort}", base
    # provider 段是**两段**主机形态（如 `llm.internal`）时也给长度摘要：这条规则必须与
    # `_mask_value` 的 `/` 分支一致，否则同一个 provider 在 model 段短时被掩、在 model 段
    # 点分/高熵时被原样打出来——同一张表在同一张输出面里自相矛盾。
    prov = mask_provider_id(head) if "." in head else head
    return f"{prov}{sep}<model {len(tail)} chars>{suf}"


def validator_crashed(stderr_text):
    """校验器是不是**真的崩了**：python 未捕获异常的形状 = 头部行**且紧跟一帧 `File "…"`**。

    两个要点，都是被实测打出来的：
    1. **只认 stderr**。未捕获异常的 traceback 走 stderr，stdout 是校验器给出的判决。
       两者混在一段文本里判，就等于留了「值里造一行 Traceback」的口子——普通不合格会被说成
       「校验器崩了」，形状诊断那段还会整段消失（doctor 崩了不打结论，于是连真发现都没了）。
    2. **头部行必须是第一条非空行**：真崩溃时 traceback 从头开始；判决文本里夹着的伪造行
       前面总还有别的内容（`groups[0]: unknown field '…'`）。
    doctor 用它；apply 用它——以前只有 doctor 有，apply 把崩溃报成「你的配置不合格」。
    """
    lines = stderr_text.splitlines()
    i = 0
    while i < len(lines) and not lines[i].strip():
        i += 1
    if i >= len(lines):
        return False
    return (lines[i].startswith("Traceback (most recent call last)")
            and i + 1 < len(lines) and lines[i + 1].lstrip().startswith('File "'))


NO_VERDICT_NOTE = "(validate.py printed no PASS/FAIL verdict — validation not run)"


def no_verdict(stdout_text):
    """校验器**根本没跑出判决**——既不是「合格」也不是「崩溃」的第三种状态。

    validate 的每个正常出口都必然打印一行判决（`PASS: …` 排在 `return 0` 之前，每条 FAIL 分支
    也先打印），所以「stdout 里一行判决都没有」只有一种解释：跑起来的这份 validate 没执行到判决
    ——半成品拷贝、被截断的副本、被换掉的空壳、跑一半被杀掉的进程。
    把它读成「通过」的代价不是措辞问题：apply 会照样写盘并宣布 `post-write validation PASS`，
    doctor 会留下一个空段配上下面的 `shape findings: none`，两边都读起来像体检合格。
    **判据不能看退出码**：被信号杀死（SIGKILL / OOM）的进程退出码是负的（`-9`），
    「rc == 0 且输出为空」这条会在最该报警的场合先放行——进程连打印判决的机会都没有。
    判决行本身才是证据：`PASS:` 或 `FAIL:` 开头的行一行都没有，就是没判决。
    判据住在 validate（单真源，doctor 与 apply 共用），且**必须排在 `main` 之前**：被截断的副本
    也得拿得到它，否则守卫自己先 AttributeError——那正好是要防的那件事。
    """
    return not any(l.startswith(("PASS:", "FAIL:")) for l in stdout_text.splitlines())


# 两个消费者（apply.py / doctor.py）在运行时要取的判据名。**缺任何一个都在启动时停下**，
# 别跑到一半才 AttributeError：那时 apply 可能已经写了盘、doctor 的输出停在半句上，
# 两者都读起来像「跑完了」。名字表住在这里（单真源），消费者只管「少了就停 / 少了就退化成全掩」；
# 抄两份名单到消费者里，迟早和 validate 的改名漂移。
PUBLIC_API = ("shield", "derive_known", "validator_crashed", "no_verdict", "NO_VERDICT_NOTE",
              "looks_secret", "looks_endpoint", "ENDPOINT_SHAPE", "ECHO_WHERE_FIELDS",
              "ECHO_WHERE_OPS", "MEMBER_EFFORT", "base_model")
# 消费者**不能**靠调用 validate 里的函数来检查这张表：一份在 `PUBLIC_API` 之前就被截断的副本
# 连检查函数都没有。所以各自用 `getattr(mod, "PUBLIC_API", None)` 读表、自己逐名 hasattr——
# 读的仍是这一份表（单真源），没有第二份名单可漂。


def derive_known(providers_doc):
    """从 providers 段派生已知模型清单（`provider/model` 拼前缀，已含 `/` 的保持）。
    形状不对一律抛 ValueError，由调用方转成可读 FAIL。`models` 写成标量或字符串也**拒**：
    `"models": "gpt-4"` 会被迭代成逐字符集合，于是每个合法成员都被判成 unknown model ref——
    把「配置写错了」伪装成「模型清单里没有」，比崩掉更难查。"""
    providers = providers_doc.get("providers", [])
    if not isinstance(providers, list) or not all(isinstance(p, dict) for p in providers):
        raise ValueError("providers section must be a list of objects")
    for p in providers:
        models = p.get("models")
        if models is None:
            continue
        if not isinstance(models, list) or not all(isinstance(m, str) for m in models):
            # provider id 也是使用者写的任意串：它多半是内网网关的主机名。原样打进报错，
            # 等于把「配置写坏了」这件事连同内网拓扑一起送进上下文/工单。
            raise ValueError(f"providers[{mask_provider_id(p.get('id', '?'))}]"
                             ".models must be a list of strings")
    return sorted({(m if "/" in m else f"{p.get('id', '')}/{m}")
                   for p in providers for m in (p.get("models") or [])})


def q(value):
    """报错里回显一个用户可控串的**唯一写法**：`{q(x)}`，不是 `{x!r}`。
    整条消息不过 shield（那会把判据本身吞掉），但每一个插进去的组 id / 成员引用 /
    字段名 / 权重键 / classifier 模型都要单独过 `shield()`：它们都可能就是凭据或 endpoint
    形态，而校验失败时这三条脚本都会把报错原样打进 stdout/stderr。同样的道理，`check_value`
    的报错路径里每一段（含 dict 键）也过 `shield()`——**报错文本里没有一处原样回显用户可控串**。"""
    return f"'{shield(value)}'"


def shield(ref):
    """把可能夹带凭据的引用换成形态摘要——**单真源**，validate 的报错 / doctor / apply / render
    四个输出面共用（`render.py` 直接复用这里的 `q()`，抄第二份形态表一定会漂）。
    报错信息、组 id、首位成员都要过它：模型引用本身可回显，但成员串里可能带 `#账号`，
    组 id / note 里可能被人贴进 endpoint 或 key。`#` 之后单独遮蔽，前半（模型引用）保留可读。
    判据按【形态】而不是「看起来像不像密钥」：宁可不显示，不可把凭据打进上下文。
    三种输出形态：`<ref N chars>`（整串可疑）、`provider/<model N chars>[:档位]`（model 段含点分域名）、
    `模型引用#<account N chars>`（只有账号部分可疑）。含控制字符的串走第四种：**先按形态掩、再 ascii 转义**
    （换行/OSC 转义不进终端；顺序反过来就成了「带控制字符就不脱敏」的后门）。"""
    s = str(ref)
    if _CTRL.search(s):
        # 控制字符这层是**先**做的（值不得在终端里造出新行），但它**不能**成为绕过脱敏判据的后门——
        # 而且它还不能**切断**判据：
        # ① 凭据形态的串只要带一个换行，就曾被整条原样打出去（等于「带控制字符就不脱敏」）；
        # ② 换行还能把一条连续凭据切成碎片，让「连续 16+ 位」这类判据**失效**（碎片够长就判不出来）。
        # 所以判据作用在**去掉控制字符后的串**上：控制字符不是判据的刀。掩完再转义，
        # 转义只是展示层——它不能替脱敏干活。
        stripped = _CTRL.sub("", s)
        if _mask_value(stripped) == stripped:
            return _escape_ctrl(s)               # 没问题：转义原样，身份仍然可读
        # 可疑：整串掩成 `<ref N chars>`，**长度按原串算**。不给骨架是有意的：
        # 骨架里的 `<model N chars>`/`<account N chars>` 若按「去掉控制字符后的串」算长度，
        # 同一段输出里就会出现两种长度口径（读者会拿它对长度、判断是不是同一个串）。
        return f"<ref {len(s)} chars>"
    return _mask_value(s)


def _escape_ctrl(s):
    """只转义控制字符（含 C0/DEL/NEL/LS/PS），**不动非 ASCII**：中文组 id 之类不该被转成
    `\\uXXXX`——转义的唯一目的是「值不得在终端里造出新行、改标题」，可读性不该顺手牺牲掉。
    反斜杠本身也转义，免得值里本来就有的 `\x1b` 看着像一次转义。"""
    out = []
    for ch in s:
        if _CTRL.search(ch):
            o = ord(ch)
            out.append("\\u%04x" % o if o > 0xff else "\\x%02x" % o)
        elif ch == "\\":
            out.append("\\\\")
        else:
            out.append(ch)
    return "".join(out)


def _mask_value(s):
    """`shield()` 的脱敏判据本体：按**形态**判断，返回形态摘要或原文（不含控制字符时）。
    控制字符那一层在 `shield()` 里，且必须**在脱敏之后**才转义——顺序反过来就是后门。"""
    if "#" in s:
        head, _, acct = s.partition("#")
        masked = _acct_shield(acct)
        if acct and masked != acct:      # 判据只在 `_acct_shield` 里写一份，这里只负责拼回骨架
            return f"{shield(head)}#{masked}"
    if SECRET_VALUE.search(s) or _SCHEME_PORT.search(s):
        return f"<ref {len(s)} chars>"
    if _ENTROPY.search(s):
        # 含 `/` 的串与「点分域名落在 model 段」是同一件事：整串掩会把 provider 前缀与 `:档位`
        # 一起吃掉，而档位是漂移/混档判据必须读得到的东西（档位进缓存键）。只掩 model 段本体。
        # `#账号` 要先摘出来单独判，否则 `acme/<长模型名>:high#ops` 会把 `:high#ops` 也吞进
        # `<model N chars>` 的本体里——档位与账号标签都不是凭据，不该被 model 段的熵连坐。
        # 不含 `/` 的（组 id、裸值）没有骨架可留，退化成 `<ref N chars>`。
        if "/" in s:
            core, sep, acct = s.partition("#")
            return _redact_model(core) + (sep + _acct_shield(acct) if sep else "")
        return f"<ref {len(s)} chars>"
    if _DOMAIN3.search(s):
        return _redact_model(s)
    if "/" in s:
        head, sep, tail = s.rpartition("/")
        if "." in head:
            # provider 段是**两段**主机形态（如 `llm.internal`）：它是使用者写的 id，多半是内网
            # 网关名，原样回显等于把内网拓扑送进上下文/工单。三段形态在上面已整串掩掉。
            # 这条必须住在 `shield()` 里而不是某个报错点——回显面有四个（validate 报错、
            # doctor 组行、apply 的 diff 段、doctor 的降级面），只补一处就会留下别的口子。
            return f"{mask_provider_id(head)}{sep}{tail}"
    return s


def _strip_ctrl(s):
    """去掉控制字符后的串。**控制字符不是判据的刀**：凭据形态靠的是「前缀 + 连续 16 位」的
    连续性，一个换行就能把它切成碎片，让「已知前缀」「连续 16+ 位」双双判不出来。
    回显侧（`shield()`）与检测侧（`check_value()`、render 的闸）必须用**同一个**判据，
    否则就会出现「脱敏表认为它是凭据、检测器认为它干净」这种自相矛盾。"""
    return _CTRL.sub("", str(s))


def looks_secret(s):
    """凭据形态判据（**单真源**）：对去掉控制字符后的串判 `SECRET_VALUE`。
    回显、校验、render 的写盘闸都调它——抄三份一定会漂，历史上就是这么差的。"""
    return bool(SECRET_VALUE.search(_strip_ctrl(s)))


_HOST2 = re.compile(r"^[A-Za-z0-9-]{1,63}\.[A-Za-z]{2,}$")


def looks_host(s):
    """两段主机形态（`llm.internal`、`proxy.corp`）：三段形态在 `ENDPOINT_SHAPE` 里，两段不在——
    但两段的内网网关名同样是拓扑信息，render 的警告要能看到它。第二段必须是纯字母，
    这样 `model.v2` 这类模型名不会被误判成主机名。"""
    return bool(_HOST2.match(_strip_ctrl(s)))


def looks_endpoint(s):
    """主机名/endpoint 形态判据（**单真源**）：对去掉控制字符后的串判 ENDPOINT_SHAPE。
    与 `looks_secret` 一样，控制字符不是判据的刀——换行切断形态就该被认出来。"""
    return bool(ENDPOINT_SHAPE.search(_strip_ctrl(s)))


def looks_suspicious(s):
    """按**熵**或**主机名/endpoint** 形态可疑（单真源，同上：先剥控制字符再判）。
    用来给「无法确定是不是凭据」的串一个提醒（render 的警告），不用于拒收。"""
    stripped = _strip_ctrl(s)
    return bool(_ENTROPY.search(stripped) or ENDPOINT_SHAPE.search(stripped)
                or looks_host(stripped))


def mask_provider_id(s):
    """providers 段的 id 单独用一条**更严**的判据：它是使用者写的任意串，多半是内网主机名
    （两段式 `llm.internal`、三段式 `gw.internal.example.com` 都在其中）。全局表刻意放过
    两段主机名（模型名带点很常见），但 provider id 没有「模型名」这种误伤顾虑——它就是主机/
    标识符，原样打进报错等于把内网拓扑送进上下文与工单。所以这里一律给长度摘要。"""
    s = str(s)
    return f"<ref {len(s)} chars>"


def utf8_encodable(s):
    """这段文本能不能原样存进 UTF-8 文件。合法 JSON 允许孤立代理对（`\\ud800` 这样的转义），
    python 也收，但按 UTF-8 编码时炸——配置文件、渲染产物、临时文件全是 UTF-8，
    所以这种东西**存不进去**，是一句该由校验器指认位置的判决，而不是写盘那一刻的 traceback。"""
    try:
        s.encode("utf-8")
        return True
    except UnicodeError:
        return False


def check_value(value, path, errors):
    """整份值按**文档顺序**走一遍，逐叶子检查。

    **显式栈，不递归**：`where.value` 是自由 JSON，深度没有上限，嵌一千层就够让递归的校验器自己
    RecursionError。那不是「配置不合格」而是**校验器崩了**——使用者拿不到判决，apply 还会把这次
    失败算成配置的问题（`MAX_DEPTH` 只管组结构嵌套，管不到这里的自由值）。
    栈上每项是 `(kind, value, path)`，`kind == "k"` 表示「先查这个 dict 的键」——
    递归版是「查键 → 深入该键的子树 → 再查下一个键」，压栈时连同键检查一起逆序压进去，
    才能保持报错顺序不变（坐标与顺序都是使用者对着 JSON 找问题的依据）。"""
    stack = [("v", value, path)]
    while stack:
        kind, value, path = stack.pop()
        if kind == "k":
            # path 不只是坐标：dict 的**键**也是使用者写的串（weights 键本来就是模型引用，
            # 野字段键可能是任何东西）。报错文本会原样进 stdout，doctor/apply 再转打一遍。
            # 键本身也要过 secret-like 判据：键会**原样落进** providers.json（render 的产物、
            # apply 的写入都是），只查值就等于给「凭据当键」留了一条路。
            key = str(value)
            if looks_secret(key):
                fail(errors, f"{path}: secret-like value in a key")
            # 「键会原样落盘」这条理由不止推出密钥判据，**值侧那两条「这条配置存不存得进」的判据
            # 一样落在键上**。漏掉它们，validate 打 PASS，危害推到写盘那一刻才出现（实测：自由值里
            # 一个 dict 的键带孤立代理对 → `PASS: 1 group(s) valid` → apply --write 走到「写失败」
            # 分支，报的是「write failed part-way」而不是「你的键存不进去」）；键里留着 `<role:`
            # 占位写法同样 PASS，于是未展开的占位符原样进 providers.json——而 render 展开角色槽位
            # 只认成员与 classifier，键根本不会被展开。
            if "<role:" in key:
                fail(errors, f"{path}: unresolved placeholder in a key")
            if not utf8_encodable(key):
                fail(errors, f"{path}: key contains a character that cannot be stored as UTF-8"
                             " (a lone surrogate such as \\\\ud800) — it cannot be written to the"
                             " config file; remove it or replace it with plain text")
            continue
        if isinstance(value, str):
            if "<role:" in value:
                fail(errors, f"{path}: unresolved placeholder")
            if looks_secret(value):
                fail(errors, f"{path}: secret-like value")
            if not utf8_encodable(value):
                fail(errors, f"{path}: contains a character that cannot be stored as UTF-8"
                             " (a lone surrogate such as \\\\ud800) — it cannot be written to the"
                             " config file; remove it or replace it with plain text")
        elif isinstance(value, list):
            stack.extend(reversed([("v", v, f"{path}[{i}]") for i, v in enumerate(value)]))
        elif isinstance(value, float):
            # NaN / Infinity 不是合法 JSON（RFC 8259 没有这两个字面量），但 python 的 json 收它们。
            # 放过就等于把一份别的解析器读不回来的配置写进 providers.json——而「类型写错 →
            # 整份 providers.json 解析失败」正是本文件头里警告的后果。
            if not math.isfinite(value):
                fail(errors, f"{path}: must be a finite number (NaN/Infinity are not valid JSON)")
        elif isinstance(value, dict):
            pushed = []
            for k, v in value.items():
                pushed.append(("v", v, f"{path}.{shield(str(k))}"))
                pushed.append(("k", k, path))
            stack.extend(reversed(pushed))


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
            fail(errors, f"{path}: unknown model ref {q(ref)}")

    if not isinstance(doc, dict):
        print("FAIL: top level must be an object with a groups list")
        return 1
    for key in doc:
        if key not in TOP_FIELDS:
            fail(errors, f"top-level: unknown field {q(key)} (only groups allowed; providers must not appear)")
        if SECRET_FIELD.search(key):
            fail(errors, f"top-level: secret-like field {q(key)}")

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
                fail(errors, f"{gp}: {q(key)} is a CLI flag, not a JSON field"
                             f" (use {GROUP_CLI_ONLY[key]!r}; magpie silently ignores {q(key)})")
            elif key not in GROUP_FIELDS:
                fail(errors, f"{gp}: unknown field {q(key)}")
            if SECRET_FIELD.search(key):
                fail(errors, f"{gp}: secret-like field {q(key)}")
        gid = group.get("id")
        if not isinstance(gid, str) or not gid:
            fail(errors, f"{gp}.id: required non-empty string")
            gid = f"<invalid-{gi}>"
        elif gid in seen_ids:
            fail(errors, f"{gp}: duplicate group id {q(gid)}")
        seen_ids.add(gid)
        nest_adj.setdefault(gid, set())
        all_refs.setdefault(gid, set())

        if "disabled" in group and not isinstance(group["disabled"], bool):
            fail(errors, f"{gp}.disabled: must be bool")
        for fld in ("name", "note", "family"):
            if fld in group and not isinstance(group[fld], str):
                fail(errors, f"{gp}.{fld}: must be string")
        if "routing" in group and (not isinstance(group["routing"], str) or group["routing"] not in ROUTING_MODES):
            fail(errors, f"{gp}.routing: unknown mode {q(group['routing'])}")
        if "affinity" in group and (not isinstance(group["affinity"], str) or group["affinity"] not in AFFINITY):
            fail(errors, f"{gp}.affinity: unknown value {q(group['affinity'])} (CLI stays=)")
        if "effort" in group:
            if not isinstance(group["effort"], str) or group["effort"] not in GROUP_EFFORT:
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
            # 元素必须先确认是 str 再查集合：`levels: [[]]` 会让 `[] in {…}` 抛
            # TypeError: unhashable type——**出判决而不是抛异常**是这里的标准（环/超深同理）。
            # 崩的代价不止一条报错：doctor 会据此判「校验器崩了」而**整段抑制形状诊断**，
            # apply 只能回一句「这是崩溃报告不是对你配置的判决」，使用者拿不到任何可行动结论。
            if not isinstance(lv, list) or not all(isinstance(x, str) and x in MEMBER_EFFORT
                                                   for x in lv):
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
                fail(errors, f"{path}: {q(ref)} is not a member of this group"
                             " (use the full member ref incl. :effort; magpie ignores others)")

        if "weights" in group:
            w = group["weights"]
            if not isinstance(w, dict):
                fail(errors, f"{gp}.weights: must be an object mapping member ref -> integer 1..1000")
            else:
                for k, v in w.items():
                    check_member_ref(k, f"{gp}.weights key {q(k)}")
                    if isinstance(v, bool) or not isinstance(v, int) or not 1 <= v <= 1000:
                        fail(errors, f"{gp}.weights[{q(k)}]: must be an integer 1..1000"
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
                    fail(errors, f"{path}: {q(ref)} is not a member of group {q(gid)} (use/more must be members)")
            elif isinstance(ref, str) and not is_pattern(ref):
                bm = base_model(ref)
                rule_models.add(bm)
                if not has_pattern and bm not in member_models:
                    fail(errors, f"{path}: {q(ref)} is not a member of group {q(gid)} (use/more must be members)")

        for ri, rule in enumerate(rules):
            rp = f"{gp}.rules[{ri}]"
            if not isinstance(rule, dict):
                fail(errors, f"{rp}: must be object")
                continue
            for key in rule:
                if key not in RULE_FIELDS:
                    fail(errors, f"{rp}: unknown field {q(key)}")
                if SECRET_FIELD.search(key):
                    fail(errors, f"{rp}: secret-like field {q(key)}")
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
            if "effort" in rule and (not isinstance(rule["effort"], str) or rule["effort"] not in RULE_EFFORT):
                fail(errors, f"{rp}.effort: must be on or an effort level")
            if "useEffort" in rule and (not isinstance(rule["useEffort"], str) or rule["useEffort"] not in USE_EFFORT):
                fail(errors, f"{rp}.useEffort: unknown level {q(rule['useEffort'])}")
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
                fail(errors, f"group {q(gid)}: references unknown group {q(ref)}")

    # classifier 分离守卫（跨组）：意图判断模型绝不进【任何】路由组的成员/规则目标。
    # classifier 为组时，解析其成员模型；该 classifier 池自身的成员豁免（它们就是分类器）。
    classifier_models = set()
    classifier_groups = set()

    def resolve_models(gid, visited):
        """classifier 指向的那个组（连同它的嵌套子组）里的全部模型——**迭代版，不递归**。

        递归版在深嵌套链上会自己 RecursionError：那是一句崩溃而不是判决，于是「classifier 只能判意图、
        不能当路由成员」这条守卫对真正的深链根本不生效（下面环检测与深度 ≤8 两段改迭代是同一个理由）。
        worklist 用 `visited` 去重，环与深链都只是少走几步，不会转不完。"""
        out, work = set(), [gid]
        while work:
            cur = work.pop()
            if cur in visited or cur not in gdata:
                continue
            visited.add(cur)
            classifier_groups.add(cur)
            dat = gdata[cur]
            out |= dat["member_models"]
            work.extend(dat["member_groups"])
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
                fail(errors, f"group {q(gid)}: {q(m)} is a classifier model; classifier must only judge intent, never a routing member/target")

    # 禁自包含（嵌套图环检测）+ 深度 ≤8
    # **两段都写成迭代**：递归版在超深链上会撞 RecursionError——那不是判决，是崩溃，
    # 于是「深度 ≤8」这条守卫对真正的深链根本不生效（1200 层链实测：崩溃而非「太深了」）。
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {gid: WHITE for gid in nest_adj}
    has_cycle = False

    for root in list(nest_adj):
        if color[root] != WHITE:
            continue
        color[root] = GRAY
        path = [root]
        stack = [(root, iter(sorted(nest_adj.get(root, set()))))]
        while stack:
            gid, kids = stack[-1]
            descended = False
            for nxt in kids:
                if nxt not in color:
                    continue
                if color[nxt] == GRAY:
                    has_cycle = True
                    fail(errors, f"group nesting cycle (self-inclusion): {' -> '.join(shield(x) for x in path + [nxt])}")
                elif color[nxt] == WHITE:
                    color[nxt] = GRAY
                    path.append(nxt)
                    stack.append((nxt, iter(sorted(nest_adj.get(nxt, set())))))
                    descended = True
                    break
            if not descended:
                color[gid] = BLACK
                stack.pop()
                if path and path[-1] == gid:
                    path.pop()

    if not has_cycle:
        # DAG 上的最长路径 = 深度。拓扑序（Kahn）自底向上算，避免递归。
        indeg = {gid: 0 for gid in nest_adj}
        for gid, kids in nest_adj.items():
            for kid in kids:
                if kid in indeg:
                    indeg[kid] += 1
        ready = [gid for gid in nest_adj if indeg[gid] == 0]
        order = []
        while ready:
            gid = ready.pop()
            order.append(gid)
            for kid in sorted(nest_adj.get(gid, set())):
                if kid in indeg:
                    indeg[kid] -= 1
                    if indeg[kid] == 0:
                        ready.append(kid)
        depth_cache = {gid: 0 for gid in nest_adj}
        for gid in reversed(order):
            best = 0
            for kid in nest_adj.get(gid, set()):
                if kid in depth_cache:
                    best = max(best, 1 + depth_cache[kid])
            depth_cache[gid] = best

        for gid in nest_adj:
            d = depth_cache[gid]
            if d > MAX_DEPTH:
                fail(errors, f"group {q(gid)}: nesting depth {d} exceeds {MAX_DEPTH}")

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
