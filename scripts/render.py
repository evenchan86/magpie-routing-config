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
import importlib.util
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

# 回显判据与 validate/doctor/apply 同一张表（单真源）：mapping 的键与元素都是使用者写的串，
# 报错会原样进 stdout。抄第二份形态表一定会漂。
_V_PATH = Path(__file__).resolve().parent / "validate.py"
_spec = importlib.util.spec_from_file_location("magpie_validate", str(_V_PATH))
_validate = importlib.util.module_from_spec(_spec)
try:
    _spec.loader.exec_module(_validate)
except Exception as exc:   # 少文件或文件本身坏了都算安装问题，都给可读 FAIL
    sys.exit(f"FAIL: cannot load validate.py next to render.py ({exc}) — the redaction table"
             " lives there; fix the install and re-run")
q = _validate.q

ROLE_RE = re.compile(r"<role:([^>]+)>(.*)", re.S)
# **不抄这张表**：强度名单的真源在 validate.MEMBER_EFFORT。抄一份就会漂（validate 加一个档位词，
# render 这边就把 `model@新档` 读成模型名的一部分，报错指到 unknown-model 上去，谁都不知道为什么）。
EFFORT_SUFFIXES = _validate.MEMBER_EFFORT


def has_effort_suffix(ref):
    """base 引用是否带可剥的 :effort 后缀。镜像 validate.py base_model 的判定：
    只把「后缀全是已知强度」当强度，避免误伤 prov/cn:coder-a 这类含冒号的模型名。"""
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


def secret_like_paths(node, path=""):
    """渲染产物里 secret-like 串的位置（JSON 路径）。判据复用 validate 的同一张表
    （`SECRET_VALUE`）——抄第二份一定会漂。路径里的键是使用者写的串，回显时过 `q()`。

    **键也要查**：dict 的键会原样落进产物（`levels`/`weights` 这类映射的键就是使用者的串），
    只查值等于给「凭据当键」留了一条路。"""
    hits = []
    if isinstance(node, str):
        if _validate.looks_secret(node):
            hits.append(path or "(top level)")
    elif isinstance(node, list):
        for i, item in enumerate(node):
            hits.extend(secret_like_paths(item, f"{path}[{i}]"))
    elif isinstance(node, dict):
        for k, item in node.items():
            if _validate.looks_secret(str(k)):
                hits.append((path + "." if path else "") + str(k) + " (key)")
            hits.extend(secret_like_paths(item, f"{path}.{k}" if path else str(k)))
    return hits


def suspicious_paths(node, path="", seen=None):
    """产物里「按形态可疑」的串：**去重后的个数**与它们所在的 JSON 路径。
    判据走 validate 的单真源（`looks_suspicious`：熵 / 主机名 / endpoint 形态）——
    控制字符不是判据的刀，那一边已经统一过了。
    渲染色不因为这个**被拦**——合法的长模型名、点分模型名与 token/内网主机名形态完全同形，
    硬拦会把好配置也堵死；但使用者有权知道自己往终端里打了什么，所以给一句计数警告。
    同一个串既是键又是值只算一次（去重），路径给出位置（路径本身也可能是使用者的串，
    回显时过 `q()`）。"""
    if seen is None:
        seen = {}
    if isinstance(node, str):
        if _validate.looks_suspicious(node):
            seen.setdefault(node, []).append(path or "(top level)")
    elif isinstance(node, list):
        for i, item in enumerate(node):
            suspicious_paths(item, f"{path}[{i}]", seen)
    elif isinstance(node, dict):
        for k, item in node.items():
            if _validate.looks_suspicious(str(k)):
                seen.setdefault(str(k), []).append((path + "." if path else "") + str(k) + " (key)")
            suspicious_paths(item, f"{path}.{k}" if path else str(k), seen)
    return seen


def stale_note(dest):
    """拒绝写盘时**每个分支**都要提醒：目标路径上可能还留着上一次跑出来的文件。
    不提醒的分支等于让读者以为「既然没写成功，那边界状态未知」——实际是「那里有个陈旧副本，
    本次没有更新它」，这两件事在排查时完全不同。

    必须用**真正要写的那个路径**问这个问题：写盘那一步走的是 `expanduser()` 之后的路径，
    这里若拿原始的 `sys.argv[3]` 去 `exists()`，`~/out.json` 这种写法下探测的是当前目录里
    一个叫 `~/out.json` 的文件——展开处明明有旧产物，提醒却静默丢掉（实测：同一个拒绝分支，
    tilde 写法 0 次提醒、绝对路径 1 次）。每条拒绝分支承诺的披露不能取决于使用者怎么写路径。"""
    if dest is not None and dest.exists():
        print(f"note: {dest} still holds the file from an earlier run;"
              " it was not updated by this one")


def main():
    if len(sys.argv) < 3:
        print("usage: render.py <template.json> <mapping.json> [output.json]")
        return 2
    # 输出路径**在这里就展开一次**：真正写盘的那一步与「目标上还留着旧产物」的提醒必须问同一个路径。
    dest = Path(sys.argv[3]).expanduser() if len(sys.argv) > 3 else None
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
            errors.append(f"mapping[{q(role)}]: must be a non-empty list of model strings")
        elif not all(isinstance(m, str) and m for m in models):
            errors.append(f"mapping[{q(role)}]: every element must be a non-empty model string")
        else:
            for entry in models:
                base, _ = split_override(entry)
                if not base:
                    errors.append(f"mapping[{q(role)}]: {q(entry)} 模型名为空；mapping 元素须为 base 引用 provider/model（可加 @effort 覆写）")
                elif has_effort_suffix(base):
                    errors.append(f"mapping[{q(role)}]: {q(entry)} 的模型部分含强度后缀；mapping 元素须为 base 引用（强度由模板后缀或 @effort 覆写施加）")
    # 预校验失败先返回，避免展开阶段对非法元素崩溃（干净 FAIL 契约）
    if errors:
        print("FAIL:")
        for err in errors:
            print(f"  {err}")
        return 1

    def models_for(role):
        ms = mapping.get(role)
        if not isinstance(ms, list) or not ms:
            errors.append(f"role {q(role)} used in template but not mapped to a non-empty list")
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

    if not isinstance(tpl, dict):        # 顶层给成 list/字符串时原先直接 AttributeError
        print("FAIL: template must be an object with a groups list")
        return 1
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
    # 渲染产物里若混进了 secret-like 的串，**不打印、不写盘**：render 的输出是要进 providers.json 的，
    # 而它同时也是使用者能直接看到的终端内容——凭据一进终端就等于带进了上下文与对话记录。
    # validate 事后会拒（check_value → secret-like value），但那时已经打过一遍了。这里提前拦。
    hits = secret_like_paths(tpl)
    if hits:
        print("FAIL: the rendered config contains a value that looks like a credential;")
        print("       nothing was printed or written.")
        for path in hits[:5]:
            print(f"  at {q(path)}")
        if len(hits) > 5:
            print(f"  ... and {len(hits) - 5} more")
        stale_note(dest)
        return 1
    try:
        # allow_nan=False：NaN/Infinity 不是合法 JSON。产物是要进 providers.json 的配置本体，
        # 写出非法 JSON 等于让下游解析器整份读不回来（validate 的文件头就警告过这件事）。
        # 这一步**排在可疑形态警告之前**：警告的措辞是「它们会原样打出来」，
        # 在一次什么都没打的运行里先打它，就是谎报。
        out = json.dumps(tpl, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    except ValueError as exc:
        print(f"FAIL: the rendered config contains a non-finite number (NaN/Infinity): {exc}")
        print("that is not valid JSON; nothing was printed or written.")
        stale_note(dest)
        return 1
    try:
        # **先编码，再碰目标文件**。合法 JSON 允许孤立代理对（`\\ud800` 这类转义），json.dumps 不报错，
        # 到按 UTF-8 写文件那一刻才炸；而 write_text 是先截断再写——上一次的产物被清成 0 字节，
        # 手里只剩一句 traceback（实测 200 字节 → 0 字节）。validate 现在把这种串判成 finding，
        # 这里是产物侧的双保险：编不出来就一个字节都不碰目标路径。
        data = out.encode("utf-8")
    except UnicodeError as exc:
        print(f"FAIL: the rendered config contains a character that cannot be written as UTF-8: {exc}")
        print("that is not storable in a UTF-8 config file; nothing was printed or written.")
        stale_note(dest)
        return 1

    def warn_suspicious():
        """警告**只在真的要产出时**打。这句话的内容是「它们会原样打出来」，在一次什么都没打、
        什么都没写的运行里先打出去就是谎报（实测：写盘失败那次 stdout 一个字节都没有，警告却先打了）。
        计数按**位置**数，不按去重后的串数：同一个可疑串落在 6 处时只报「1 个串、1 条位置」，
        等于让读者以为只剩一处，另外 5 处根本定位不到。"""
        susp = suspicious_paths(tpl)
        if not susp:
            return
        locs = [p for paths in susp.values() for p in paths]
        print(f"warning: {len(locs)} location(s) holding {len(susp)} distinct string(s) that look"
              " like a token or a host (16+ contiguous letters/digits, or a hostname/endpoint"
              " shape). They are printed as-is: a long model name and a token look the same, so"
              " the tool cannot tell them apart. The product is the config body; it is not"
              " redacted like the error text."
              " (this warning goes to stderr so the product on stdout stays parsable JSON)",
              file=sys.stderr)
        for path in locs[:3]:
            print(f"  at {q(path)}", file=sys.stderr)
        if len(locs) > 3:
            print(f"  ... and {len(locs) - 3} more location(s) not listed", file=sys.stderr)

    if len(sys.argv) > 3:
        # 写不出去要说人话：apply 对「建不出备份」「写不进去」都有可读 FAIL，render 这里原来
        # 只剩一句 PermissionError traceback——使用者会以为是自己模板写错了。
        # 每条拒绝写盘的分支都要提醒「目标路径上还留着上一次的产物」：这次没写进去，那里就是旧文件。
        # **原子落盘**：同目录临时文件写完 + os.replace。`write_bytes` 是先截断再写，中途任何失败
        # （磁盘满、超过单文件大小上限、进程被打断）都会在目标路径上留下半份产物：实测旧产物 5099 字节
        # 被截成 4096 字节的残片，旧配置读不回来、新配置也解析不出，而报错还写着「nothing was written」。
        # replace 之前目标文件始终是完整旧内容，失败时要么旧的全在、要么新的全在，没有第三种。
        # 代价两条：①换的是新 inode，指向它的符号链接会被换成普通文件（所以临时文件按 realpath 落点建）；
        # ②权限要显式搬过去（临时文件默认 0600，直接 replace 会悄悄改掉旧产物的权限位）。
        try:
            real = Path(os.path.realpath(str(dest))) if dest.exists() else dest
            if real.exists() and not os.access(str(real), os.W_OK):
                # **原子替换会绕过只读位**：换成一个新 inode 就写进去了，可那个只读位是使用者自己
                # 立的护栏（「这份产物别覆盖」）。绕过它等于静默覆盖一份明确拒绝写入的文件，
                # 与「更安全的落盘写法」无关。照旧拒绝，拒绝分支照样提醒「那边还留着上一次的产物」。
                raise PermissionError(13, "Permission denied (the target file is not writable)")
            fd, tmp_name = tempfile.mkstemp(dir=str(real.parent), prefix=".render-", suffix=".tmp")
            try:
                with os.fdopen(fd, "wb") as fh:
                    fh.write(data)
                if real.exists():
                    os.chmod(tmp_name, stat.S_IMODE(real.stat().st_mode))
                os.replace(tmp_name, str(real))
            except BaseException:
                Path(tmp_name).unlink(missing_ok=True)   # 残片不留：目录里那个半份文件同样是垃圾
                raise
        except OSError as exc:
            print(f"FAIL: could not write {sys.argv[3]}: {exc}")
            print("nothing was written; fix the path/permissions and re-run.")
            stale_note(dest)
            return 1
        warn_suspicious()
        print(f"OK: rendered {len(groups)} group(s) -> {sys.argv[3]}")
    else:
        try:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        except BrokenPipeError:
            # 下游 `| head` 之类提前关掉管道，不是渲染失败：产物已经算出来了，只是没人读。
            # 不接住它，解释器会甩一段 traceback 并把退出码变成非零——调用方拿 `$?` 判成败，
            # 于是一次成功的渲染被读成失败（还会去 stderr 里找那句根本不存在的错误）。
            # 这里刻意仍回非零（管道确实断了，这是惯例信号），但**只给一句话**，不给 traceback。
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())   # 关掉解释器退出时的再刷写
            print("note: stdout was closed by the reader before the product was consumed;"
                  " the render itself succeeded", file=sys.stderr)
            return 1
        warn_suspicious()
    return 0


if __name__ == "__main__":
    sys.exit(main())
