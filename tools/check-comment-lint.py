#!/usr/bin/env python3
# tools/check-comment-lint.py — 注释门禁：预提交与 CI 共用，退出码 1 表示有违规。
# 判据 C1 块 ≤3 行 · C2 行 ≤120 字（豁免仅 Swift 参数行）· C3–C7 禁行号/文档名/版本/日期/裸待办 · C8 禁批号与改动史。
# 扫描 Sources Tests examples bench tools hooks；.swift/.pini/.toml 各用其注释符，.py/.sh 与钩子用 `#`。

from __future__ import annotations

import os
import re
import sys
import tempfile

EXTS = {".swift": "swift", ".pini": "pini", ".toml": "toml", ".py": "hash", ".sh": "hash"}
DEFAULT_ROOTS = ["Sources", "Tests", "examples", "bench", "tools", "hooks"]
EXTENSIONLESS = {"pre-commit", "commit-msg", "pre-push"}

MAX_LINES = 3
MAX_WIDTH = 120

PARAM_RE = re.compile(r"^[-*]\s*(Parameter|Parameters|parameter|parameters|参数)\b")
DATE_RE = re.compile(r"20\d\d-\d\d-\d\d")
VERSION_RE = re.compile(r"\bv\d+\.\d+\b")
LINENO_RE = re.compile(r"[A-Za-z0-9_]+\.(?:swift|pini|toml):\d+")
DOCNAME_RE = re.compile(r"[A-Za-z0-9_-]+\.md\b")
TODO_RE = re.compile(r"\b(TODO|FIXME|HACK|XXX)\b")
TRACKER_RE = re.compile(r"(issue-|ADR-)")
BATCH_RE = re.compile(
    r"(批\s*\d+|#\d{2,}|\b(?:DE|LR|GP|P4)-[0-9]|\bADR-\d+|issue-\d+"
    r"|原先|此前|以前|原来|改为|改成|已删|删掉|旧版|旧实现|重构前|早先|已废弃"
    r"|\b(?:legacy|formerly|previously|used to|deprecated)\b)",
    re.I,
)


def strip_marker(text: str, lang: str) -> str:
    s = text.strip()
    if lang == "swift":
        for m in ("///", "//", "*/", "/*", "*"):
            if s.startswith(m):
                s = s[len(m):]
                break
    elif lang == "pini":
        if s.startswith(";") or s.startswith("#"):
            s = s[1:]
    else:
        if s.startswith("#"):
            s = s[1:]
    return s[1:] if s.startswith(" ") else s


def split_trailing_pini(line: str) -> str | None:
    """返回 `;` 起头的行尾注释（无则 None）。引号内的 `;` 不算。"""
    quote = None
    esc = False
    for i, ch in enumerate(line):
        if esc:
            esc = False
            continue
        if ch == "\\":
            esc = True
            continue
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            continue
        if ch == ";":
            return line[i:]
    return None


def blocks(path: str, lang: str):
    """产出 (起始行号, [(行号, 正文)]) —— 连续注释行组成一块。"""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")

    out = []
    cur: list[tuple[int, str]] = []
    cur_kind = None

    def flush():
        nonlocal cur, cur_kind
        if cur:
            out.append((cur[0][0], cur))
        cur, cur_kind = [], None

    for no, raw in enumerate(lines, 1):
        s = raw.strip()
        if lang == "hash":
            if no == 1 and s.startswith("#!"):
                flush()
                continue
            if s.startswith("#"):
                if cur_kind not in (None, "line"):
                    flush()
                cur_kind = "line"
                cur.append((no, strip_marker(raw, lang)))
                continue
            flush()
            continue
        if lang == "swift":
            if s.startswith("//"):
                if cur_kind not in (None, "line"):
                    flush()
                cur_kind = "line"
                cur.append((no, strip_marker(raw, lang)))
                continue
            if cur_kind == "block":
                cur.append((no, strip_marker(raw, lang)))
                if "*/" in s:
                    flush()
                continue
            if s.startswith("/*"):
                flush()
                cur_kind = "block"
                cur.append((no, strip_marker(raw, lang)))
                if "*/" in s:
                    flush()
                continue
            flush()
            continue
        if lang == "pini":
            if s.startswith(";") or s.startswith("#"):
                if cur_kind not in (None, "line"):
                    flush()
                cur_kind = "line"
                cur.append((no, strip_marker(raw, lang)))
                continue
            flush()
            tail = split_trailing_pini(raw)
            if tail:
                out.append((no, [(no, strip_marker(tail, lang))]))
            continue
        # toml
        if s.startswith("#"):
            if cur_kind not in (None, "line"):
                flush()
            cur_kind = "line"
            cur.append((no, strip_marker(raw, lang)))
            continue
        flush()
        idx = raw.find("#")
        if idx > 0 and '"' not in raw[:idx] and "'" not in raw[:idx]:
            out.append((no, [(no, strip_marker(raw[idx:], lang))]))
    flush()
    return out


def check_block(lang: str, block) -> list[str]:
    hits = []
    counted = 0
    for _, text in block:
        exempt = lang == "swift" and PARAM_RE.match(text.strip())
        if not exempt:
            counted += 1
        if not exempt and len(text) > MAX_WIDTH:
            hits.append(f"C2 行宽 {len(text)} 字（上限 {MAX_WIDTH}）: {text[:60]}")
        body = text
        if DATE_RE.search(body):
            hits.append(f"C6 日期快照: {body[:80]}")
        if VERSION_RE.search(body):
            hits.append(f"C5 版本叙事: {body[:80]}")
        if LINENO_RE.search(body):
            hits.append(f"C3 行号引用: {body[:80]}")
        if DOCNAME_RE.search(body):
            hits.append(f"C4 文档名: {body[:80]}")
        if TODO_RE.search(body) and not TRACKER_RE.search(body):
            hits.append(f"C7 裸待办: {body[:80]}")
        if BATCH_RE.search(body):
            hits.append(f"C8 批号或改动史: {body[:80]}")
    if counted > MAX_LINES:
        head = block[0][1][:60]
        hits.insert(0, f"C1 块 {counted} 行（上限 {MAX_LINES}）: {head}")
    return hits


def self_test() -> bool:
    """阳性对照：4 行块必被 C1 拦下；3 行摘要 + 参数行必放行。"""
    good = "/// 摘要。\n/// - Parameter a: 甲。\n/// - Parameter b: 乙。\n/// - Parameter c: 丙。\n/// - Parameter d: 丁。\n"
    bad = "// 一\n// 二\n// 三\n// 四\n"
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "probe.swift")
        with open(p, "w", encoding="utf-8") as f:
            f.write(good + "\n" + bad)
        found = []
        for start, blk in blocks(p, "swift"):
            hits = check_block("swift", blk)
            found.append((start, bool(hits)))
    ok = len(found) == 2 and found[0][1] is False and found[1][1] is True
    if not ok:
        print("❌ 阳性对照失败：抽取式或判据失灵（不等于「全部合规」）", file=sys.stderr)
    return ok


def main(argv: list[str]) -> int:
    if not self_test():
        return 1
    roots = argv[1:] or DEFAULT_ROOTS
    targets = []
    for r in roots:
        if os.path.isfile(r):
            targets.append(r)
        elif os.path.isdir(r):
            for dp, dns, fns in os.walk(r):
                dns[:] = [d for d in dns if d not in (".build", ".git", "__pycache__")]
                for fn in sorted(fns):
                    if os.path.splitext(fn)[1] in EXTS or fn in EXTENSIONLESS:
                        targets.append(os.path.join(dp, fn))
    if not targets:
        print(" 注意   无可扫描文件，跳过")
        return 0

    def lang_of(path: str) -> str:
        ext = os.path.splitext(path)[1]
        return EXTS[ext] if ext in EXTS else "hash"

    bad_files = 0
    bad_hits = 0
    shown = 0
    for path in sorted(targets):
        lang = lang_of(path)
        file_hits = []
        for start, blk in blocks(path, lang):
            for h in check_block(lang, blk):
                file_hits.append((start, h))
        if file_hits:
            bad_files += 1
            bad_hits += len(file_hits)
            for start, h in file_hits:
                if shown < 300:
                    print(f"{path}:{start}: [{h.split()[0]}] {h[len(h.split()[0]) + 1:]}")
                    shown += 1
    if bad_hits:
        print(f"\n 行不通  [注释门禁] {bad_files} 个文件 / {bad_hits} 处违规"
              f"（每块 ≤{MAX_LINES} 行、每行 ≤{MAX_WIDTH} 字；Swift 参数行豁免）")
        if bad_hits > shown:
            print(f"   仅显示前 {shown} 处。")
        return 1
    print(f"🎉 [注释门禁] 通过（{len(targets)} 个文件；判据 C1–C8 + 阳性对照）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
