#!/usr/bin/env python3
"""提交闸：git commit 前由全局 hook 调用（规则放在仓库里，别的项目不受影响）。

挡两类「review 过了但文档没同步就提交」：
  1. 本批 staged 改动触及脚本公开面，却没有 staged 任何公开文档（也没写 doc-sync 豁免理由）
  2. 当日 review 档案缺「文档对照」小节（逐文件结论）——等于没做文档同步这一步

只读 git 与仓库文件，不碰任何本机配置。退出码 0=放行，1=拦下（理由打印到 stdout）。
"""
import re
import sys
from datetime import date
from pathlib import Path

# 本仓库脚本一律用 `python3 -I` 调用，而 -I 会把脚本自身目录从 sys.path 移除，
# 裸 `import docgate` 会 ModuleNotFoundError（实测）。显式补回同目录。
sys.path.insert(0, str(Path(__file__).resolve().parent))
import docgate

ROOT = Path(__file__).resolve().parent.parent


def git(*args):
    import subprocess
    p = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    return p.returncode, p.stdout


def show(rev, rel):
    rc, out = git("show", f"{rev}:{rel}")
    return out if rc == 0 else None


def archive_section(docs):
    """取当日 review 档案里的「文档对照/文档同步」小节正文；没有则返回 None。"""
    d = ROOT / "docs/superpowers/code-reviews"
    if not d.is_dir():
        return None, "review 档案目录不存在"
    files = sorted(d.glob(f"{date.today().isoformat()}*.md"))
    if not files:
        return None, f"当日 review 档案缺失（需 {date.today().isoformat()}-*.md）"
    for f in files:                      # 当日可能有多份档案，任何一份含该小节都算（实测只取首份误拦）
        text = f.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        for i, line in enumerate(lines):
            m = re.match(r"^(#{1,4})\s*.*(?:文档对照|文档同步)", line)
            if not m:
                continue
            level = len(m.group(1))
            body = []
            for nxt in lines[i + 1:]:
                h = re.match(r"^(#{1,6})\s", nxt)
                if h and len(h.group(1)) <= level:
                    break
                body.append(nxt)
            return "\n".join(body), str(f.relative_to(ROOT))
    return None, f"当日档案缺「文档对照」小节（需 {date.today().isoformat()}-*.md）"


def _mentioned(body, path, basenames):
    """该文件是否在小节里被点名。全路径优先；basename 只在无歧义时用，且两侧不得贴着路径字符。"""
    pats = [re.escape(path)]
    base = Path(path).name
    if len(basenames[base]) == 1:
        pats.append(re.escape(base))
    return any(re.search(rf"(?<![\w./-]){p}(?![\w.-])", body) for p in pats)


def main():
    problems = []
    rc, staged = git("diff", "--cached", "--name-only")
    if rc != 0:
        print("commit-gate: 无法读取 git 暂存区，放行（请在仓库内运行）")
        return 0
    files = [f for f in staged.split() if f]
    docs = docgate.public_docs(ROOT)

    # 1. 公开面变更 → 必须同批同步公开文档
    pairs = [(f, show("HEAD", f), show("", f)) for f in files]
    changed = docgate.surface_changes(pairs)
    if changed:
        rc, diff = git("diff", "--cached", "--", "scripts/", "templates/")
        reasons = docgate.exemptions(diff)              # {文件: [理由]}
        staged_docs = [f for f in files if f in docs]
        # 有文档同步 → 放行（改的是否相关由流程闸的逐文件结论兜，机器判不了相关性）；
        # 无文档同步 → 每个公开面文件都必须自带豁免，一条无关豁免不能掩护整批
        uncovered = [] if staged_docs else [f for f in changed if f not in reasons]
        if uncovered:
            problems.append("本批改了脚本公开面，却没有同步任何公开文档：")
            for f in uncovered:
                targets = docgate.docs_mentioning(ROOT, f, docs)
                problems.append(f"  - {f}" + (f" → 请对照 {', '.join(targets)}" if targets else ""))
            problems.append("  同步文档后再提交；确属纯内部改动时，在【该文件】里加独立注释并写明理由：")
            problems.append("    # doc-sync: 纯内部修复，不改公开行为")
        elif staged_docs:
            print("commit-gate: 按「本批已改公开文档」放行（相关性由档案逐文件结论兜，机器未核验）："
                  + ", ".join(staged_docs))
        elif reasons:
            print("commit-gate: 已按 doc-sync 豁免放行："
                  + "；".join(f"{k}: {'/'.join(v)}" for k, v in reasons.items()))

    # 2. review 档案必须有逐文件的文档对照结论
    body, where = archive_section(docs)
    if body is None:
        problems.append(f"文档同步这一步没有留痕：{where}")
        problems.append("  在当日 review 档案里加「## 文档对照」小节，逐个公开文件写结论（相关/无关 + 依据）")
    else:
        # 计数必须消歧：`README.md` 同时也是 examples/demo/README.md 的 basename，
        # 直接子串匹配会把两者都算进去，「写 2 个名字就满足 ≥3」（实测）
        basenames = {}
        for d in docs:
            basenames.setdefault(Path(d).name, []).append(d)
        named = {d for d in docs if _mentioned(body, d, basenames)}
        if len(named) < 3:
            problems.append(f"「文档对照」小节只提到 {len(named)} 个公开文件（{where}），不足以证明做了全量对照")
            problems.append("  逐个公开文件写结论，至少覆盖：" + ", ".join(docs[:6]))

    if problems:
        print("❌ 提交闸未通过（文档同步）\n")
        print("\n".join(problems))
        return 1
    print("commit-gate: 文档同步检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
