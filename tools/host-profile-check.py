#!/usr/bin/env python3
"""构建口径门禁：门禁、钩子与 CI 只读 release，不写回 debug 二进制。

判据：一行里 `.build` 在 `debug` 前、`pini` 在后，即读了 debug 产物。
豁免两处：`docs/plans/readings/` 记录的是当时构型，本脚本自身的模式串是判据。
退出码 0 通过，1 有引用，2 环境不满足。
"""

import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 语义判据：`.build/debug/pini` 与 `".build" / "debug" / "pini"` 两种写法都覆盖；
# `pini-bootstrap` 与 `.pini` 文件后缀不算。
HOST_PATTERN = re.compile(r"\.build[^\n]{0,60}\bdebug\b[^\n]{0,60}(?<!\.)\bpini\b(?!-bootstrap)")
SKIP_DIRS = {".git", ".build", "__pycache__", "node_modules"}
SKIP_PREFIXES = (os.path.join("docs", "plans", "readings"),)
SUFFIXES = (".sh", ".py", ".yml", ".yaml", ".toml", ".md")


def scanned_files(root):
    """遍历待扫文件：跳过构建产物、版本库与历史读数件。"""
    for base, dirs, files in os.walk(root):
        dirs[:] = [name for name in dirs if name not in SKIP_DIRS]
        rel_base = os.path.relpath(base, root)
        if any(rel_base == prefix or rel_base.startswith(prefix + os.sep)
               for prefix in SKIP_PREFIXES):
            dirs[:] = []
            continue
        for name in files:
            if name.endswith(SUFFIXES):
                yield os.path.join(base, name)


def hits_in(path):
    """返回带行号与原文的命中行。"""
    found = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for number, line in enumerate(handle, 1):
                if HOST_PATTERN.search(line):
                    found.append((number, line.strip()))
    except OSError:
        return found
    return found


def scan(root, skip_self):
    """全仓扫描：返回 (路径, 行号, 原文) 列表，路径相对 root。"""
    self_path = os.path.abspath(__file__) if skip_self else ""
    found = []
    for path in scanned_files(root):
        if os.path.abspath(path) == self_path:
            continue
        for number, text in hits_in(path):
            found.append((os.path.relpath(path, root), number, text))
    return found


def self_test():
    """在临时目录验证判据开火与豁免：合规不报、违规必报。"""
    with tempfile.TemporaryDirectory() as work:
        ok_path = os.path.join(work, "ok.sh")
        with open(ok_path, "w", encoding="utf-8") as handle:
            handle.write("pini=.build/release/pini\n")
        bad_path = os.path.join(work, "bad.sh")
        with open(bad_path, "w", encoding="utf-8") as handle:
            handle.write("pini=\"$root/.build/debug/pini\"\n")
        split_path = os.path.join(work, "split.py")
        with open(split_path, "w", encoding="utf-8") as handle:
            handle.write('BIN = ROOT / ".build" / "debug" / "pini"\n')
        named_path = os.path.join(work, "named.sh")
        with open(named_path, "w", encoding="utf-8") as handle:
            handle.write("pini=.build/debug/bin/pini-bootstrap\n")
        if hits_in(ok_path):
            return "自检失败：合规文件被判为违规"
        if len(hits_in(bad_path)) != 1:
            return "自检失败：违规文件未被命中"
        if len(hits_in(split_path)) != 1:
            return "自检失败：分段写法未被命中"
        if hits_in(named_path):
            return "自检失败：pini-bootstrap 被当成 pini"
        found = scan(work, skip_self=False)
        if len(found) != 2:
            return "自检失败：全仓扫描的命中集不对"
    return ""


def main():
    if "--self-test" in sys.argv[1:]:
        problem = self_test()
        if problem:
            print(f" 行不通  [口径] {problem}", file=sys.stderr)
            return 1
        print("自检通过：合规不报、违规必报")
        return 0
    found = scan(ROOT, skip_self=True)
    if not found:
        print("构建口径门禁：通过（门禁与脚本只读 release）")
        # 旧产物留着不影响判定，但会让人误以为门禁在用它；明说一次，不红。
        stale = os.path.join(ROOT, ".build", "debug", "pini")
        if os.path.isfile(stale):
            print(" 注意  .build/debug/pini 还在，但不参与任何门禁；可删掉或手动留作调试")
        return 0
    for path, number, text in found:
        print(f"{path}:{number}: [宿主读 debug] {text}", file=sys.stderr)
    print(" 行不通  [口径] 构建口径是 release；把引用改成 .build/release/pini，"
          "构建用 swift build -c release --disable-sandbox", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
