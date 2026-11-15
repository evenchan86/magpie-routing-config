#!/usr/bin/env python3
"""文档同步守卫的共享判定：e2e 验收闸与 commit 提交闸共用，避免两处各写一套口径。

「公开面」= 使用者可见的契约，只有三类：
  1. 任意 scripts/*.py 的 usage 行（CLI 签名）
  2. scripts/validate.py 的【公开常量】（见 PUBLIC_CONSTANTS；内部判定常量不算）
  3. templates/*.json 的顶层键
改了公开面 → 同批必须同步公开文档；函数体、注释、内部重构不触发。
豁免：改动的新增行里写 `# doc-sync: <理由>`（理由至少 6 个字符），【按文件生效】——
一条无关文件的豁免不能掩护同批其它公开面漂移。

另提供 CLI 契约解析：从脚本自己的 usage 字符串取参数个数与旗标白名单，
用于校验公开文档里所有 bash 块的命令签名——真源是脚本，不是手写表。
"""
import json
import re
import subprocess
from pathlib import Path

# 只认真实 print 输出行：注释/docstring 里写「旧版 usage: …」是正当内容，
# 逐行 search 会把它当公开面变更、还会劫持 cli_contract 的首匹配（实测两种都复现）
USAGE_RE = re.compile(r"print\(\s*[fFrR]?[\"']usage:\s*(\S+\.py)\s+([^\"']+)")
CONST_RE = re.compile(r"^([A-Z][A-Z0-9_]*)\s*=")
# 内部开发过程目录不是公开文档
INTERNAL_PREFIXES = ("docs/superpowers/", "tasks/")
# 公开常量白名单：只这些算公开面。SECRET_VALUE 这类内部判定常量改了不该逼出文档改动（实测误拦）
PUBLIC_CONSTANTS = frozenset({
    "GROUP_FIELDS", "RULE_FIELDS", "ROUTING_MODES", "AFFINITY",
    "MEMBER_EFFORT", "USE_EFFORT", "RULE_EFFORT", "GROUP_EFFORT", "GROUP_CLI_ONLY",
})


def public_docs(root):
    """公开文档 = 仓库里的 .md（git 跟踪的 + 未跟踪的新文档），排除内部过程目录。
    不能只用 git ls-files：本批新增的文档还没被跟踪，恰好最需要被守卫覆盖。"""
    p = subprocess.run(["git", "ls-files", "*.md"], cwd=root, capture_output=True, text=True)
    files = set(p.stdout.split()) if p.returncode == 0 else set()
    files |= {str(x.relative_to(root)) for x in Path(root).rglob("*.md")
                  if ".git" not in x.parts}
    return sorted(f for f in files if not f.startswith(INTERNAL_PREFIXES))


def surface_of(rel, text):
    """取一个文件的公开面。非公开面文件返回空集合。"""
    if text is None:
        return set()
    if rel.startswith("scripts/") and rel.endswith(".py"):
        out = set()
        for line in text.splitlines():
            if line.lstrip().startswith("#"):
                continue                  # 注释里提到 usage 不是 CLI 契约变更
            if USAGE_RE.search(line):
                out.add(line.strip())
            if rel == "scripts/validate.py":
                m = CONST_RE.match(line)
                if m and m.group(1) in PUBLIC_CONSTANTS:
                    out.add(line.strip())
        return out
    if rel.startswith("templates/") and rel.endswith(".json"):
        try:
            return set(json.loads(text).keys())
        except (ValueError, AttributeError):
            return set()
    return set()


def surface_changes(pairs):
    """pairs = [(rel, old_text, new_text)]；返回公开面发生变化的文件列表。"""
    return sorted({rel for rel, old, new in pairs
                   if surface_of(rel, old) != surface_of(rel, new)})


def exemptions(diff_text):
    """按文件收集豁免：返回 {文件路径: [理由, …]}。
    只认【独立注释行】里的 doc-sync（新增行，去掉 + 后以 # 开头），且理由 ≥6 字。
    调用方必须只传【代码路径】的 diff（scripts/、templates/）：
    - 不锚定行首 → 闸门自己的帮助文本、docstring、字符串字面量里的示例会自指放行（实测）
    - 不排除文档 → 文档里讲解豁免写法的示例本身也会变成豁免
    - 不按文件归集 → 一条无关文件的豁免会掩护整批公开面漂移（实测）
    """
    out, current = {}, None
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            path = line[4:].strip()
            current = path[2:] if path.startswith("b/") else path
            continue
        if not line.startswith("+") or current is None:
            continue
        m = re.match(r"\+\s*#\s*doc-sync:\s*(.+)$", line)
        if m and len(m.group(1).strip()) >= 6:
            out.setdefault(current, []).append(m.group(1).strip())
    return out


def docs_mentioning(root, script, docs):
    """哪些公开文档提到了这个脚本——给可操作的「该对照哪份文档」提示，不维护手工映射表。"""
    name = Path(script).name
    return [d for d in docs if name in Path(root, d).read_text(encoding="utf-8", errors="replace")]


def cli_contract(source):
    """从脚本源码的 usage 字符串解析 (脚本名, 最少位置参数, 最多位置参数, 旗标白名单)。"""
    m = USAGE_RE.search(source)
    if not m:
        return None
    name, rest = m.group(1), m.group(2)
    opts = re.findall(r"\[([^\]]+)\]", rest)
    req = re.sub(r"\[[^\]]+\]", "", rest)
    lo = len(re.findall(r"<[^>]+>", req))
    opt_pos = sum(1 for o in opts if not o.strip().startswith("--"))
    flags = {t for o in opts for t in o.split() if t.startswith("--")}
    return name, lo, lo + opt_pos, flags


def strip_redirections(args):
    """去掉输出/输入重定向及其目标：`> out.json` 不是位置参数（实测把合法文档判成参数超限）。
    占位符 `<草案.json>` 是一个参数，不是重定向，必须保留。"""
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a in (">", ">>", "2>", "2>>", "<"):
            i += 2
            continue
        if re.match(r"^\d*>>?\S", a):       # >file 连写
            i += 1
            continue
        out.append(a)
        i += 1
    return out


def logical_lines(block):
    """bash 块 → 逻辑行：反斜杠续行先拼接，heredoc 正文跳过（里面的示例不是命令）。"""
    out, buf, heredoc = [], "", None
    for raw in block.splitlines():
        if heredoc is not None:
            if raw.strip() == heredoc:
                heredoc = None
            continue
        if raw.endswith("\\"):
            buf += raw[:-1] + " "
            continue
        line, buf = buf + raw, ""
        out.append(line)
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_]\w*)['\"]?", line)
        if m:
            heredoc = m.group(1)
    if buf:
        out.append(buf)
    return out


def check_doc_commands(root, docs):
    """校验公开文档里所有 bash 块的脚本调用签名；返回问题列表（空 = 通过）。
    含 <占位符> 的用法示例也校验——它们正是使用者照抄的那部分。
    一行里的 `a && b`、管道、分号只校验含脚本调用的那一段（实测整行误判参数超限）。"""
    contracts = {}
    for p in sorted(Path(root, "scripts").glob("*.py")):
        c = cli_contract(p.read_text(encoding="utf-8", errors="replace"))
        if c:
            contracts[p.name] = c
    problems = []
    for rel in docs:
        text = Path(root, rel).read_text(encoding="utf-8", errors="replace")
        for block in re.findall(r"```bash\n(.*?)```", text, re.S):
            for line in logical_lines(block):
                if line.lstrip().startswith("#"):
                    continue          # 注释掉的旧写法不是活命令（实测误拦）
                for seg in re.split(r"&&|\|\||[;|]", line):
                    # 容许 `python3  -I  ./scripts/x.py` 这类空白与 ./ 拼法（实测绕过）
                    m = re.search(r"python3\s+-I\s+(?:\./)?scripts/([A-Za-z0-9_.-]+\.py)\s*(.*)", seg)
                    if not m:
                        continue
                    _check_segment(m, seg, rel, contracts, problems)
    return problems


def _check_segment(m, seg, rel, contracts, problems):
    name = m.group(1)
    # 只剥「空白 + #」开始的注释：模型引用里的 #account 不是注释
    rest = re.sub(r"\s#.*$", "", m.group(2)).strip()
    if name not in contracts:
        problems.append(f"{rel}: unknown script {name} (no usage contract)")
        return
    _, lo, hi, flags = contracts[name]
    try:
        args = __import__("shlex").split(rest)
    except ValueError as e:
        problems.append(f"{rel}: cannot parse command ({e}): {seg.strip()[:80]}")
        return
    args = strip_redirections(args)
    pos = [a for a in args if not a.startswith("-")]
    bad = [a for a in args if a.startswith("-") and a not in flags]
    if bad:
        problems.append(f"{rel}: {name} unknown flag {bad}: {seg.strip()[:80]}")
    if not lo <= len(pos) <= hi:
        problems.append(f"{rel}: {name} takes {lo}..{hi} args, got {len(pos)}: {seg.strip()[:80]}")
