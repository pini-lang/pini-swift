#!/usr/bin/env python3
"""构建口径门禁：宿主只读 release，自举产物路径须与工作区清单的 profile 一致。

两条判据：一行里 `.build` 之后出现 `debug` 并且再出现 `pini`，即宿主读 debug 二进制；
自举工作区的 `.build/<名字>/` 与 `bootstrap/pini.toml` 的 `profile` 不符，即产物路径与
清单脱节。豁免两处：`docs/plans/readings/` 记录的是当时构型，本脚本自身的模式串是判据。
退出码 0 通过，1 有引用，2 环境不满足。
"""

import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 语义判据：同一行里 `.build` 在 `debug` 前、`pini` 在后，覆盖 `.build/debug/pini`
# 与 `".build" / "debug" / "pini"` 两种写法；`pini-bootstrap` 与 `.pini` 文件后缀不算。
HOST_PATTERN = re.compile(r"\.build[^\n]{0,60}\bdebug\b[^\n]{0,60}(?<!\.)\bpini\b(?!-bootstrap)")
# 自举产物路径：`bootstrap/.build/<段>/` 或 `<任意>/.build/<段>/bin/pini-bootstrap`，段名即 profile。
BOOTSTRAP_SEGMENT = re.compile(r"bootstrap/\.build/([^/\s]+)/")
BOOTSTRAP_BIN = re.compile(r"\.build/([^/\s]+)/bin/pini-bootstrap")
# 这两个目录与 profile 无关：临时区与测试工作区，构建与门禁都往里写。
PROFILE_FREE = {"tmp", "tests"}


def is_placeholder(name):
    """文档与模板写 `<profile>` / `$profile` 占位；占位不是真路径，不参与比对。"""
    return name.startswith("<") or name.startswith("$")
PROFILE_LINE = re.compile(r'^\s*profile\s*=\s*"([^"]+)"')
MANIFEST = os.path.join("bootstrap", "pini.toml")
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


def workspace_profile():
    """自举工作区 profile：读清单的第一处声明；清单缺失按代码缺省 debug。"""
    try:
        with open(os.path.join(ROOT, MANIFEST), "r", encoding="utf-8") as handle:
            for line in handle:
                match = PROFILE_LINE.match(line)
                if match:
                    return match.group(1)
    except OSError:
        pass
    return "debug"


def compact(line):
    """压平写法差异：去引号空白、逗号当分隔，让拼接与 os.path.join 都露出同一段路径。"""
    return re.sub(r"[\"'`\s]", "", line).replace(",", "/")


def profile_segments(line):
    """返回该行里指向自举产物的路径段；临时区、测试区与占位写法不算。"""
    flat = compact(line)
    found = []
    for match in BOOTSTRAP_SEGMENT.finditer(flat):
        found.append(match.group(1))
    for match in BOOTSTRAP_BIN.finditer(flat):
        found.append(match.group(1))
    return [name for name in found
            if name not in PROFILE_FREE and not is_placeholder(name)]


def hits_in(path, profile):
    """返回带行号、缘由与原文的命中行；两类判据各报各的。"""
    found = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for number, line in enumerate(handle, 1):
                if HOST_PATTERN.search(line):
                    found.append((number, "宿主读 debug", line.strip()))
                    continue
                wrong = [name for name in profile_segments(line) if name != profile]
                if wrong:
                    found.append((number, "产物路径 profile 不符 " + wrong[0], line.strip()))
    except OSError:
        return found
    return found


def scan(root, profile, skip_self):
    """全仓扫描：返回 (路径, 行号, 缘由, 原文) 列表，路径相对 root。"""
    self_path = os.path.abspath(__file__) if skip_self else ""
    found = []
    for path in scanned_files(root):
        if os.path.abspath(path) == self_path:
            continue
        for number, reason, text in hits_in(path, profile):
            found.append((os.path.relpath(path, root), number, reason, text))
    return found


def self_test():
    """在临时目录验证两条判据各自开火与豁免：合规不报、违规必报。"""
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
        boot_path = os.path.join(work, "boot.sh")
        with open(boot_path, "w", encoding="utf-8") as handle:
            handle.write("pini=bootstrap/.build/debug/bin/pini-bootstrap\n")
        join_path = os.path.join(work, "join.py")
        with open(join_path, "w", encoding="utf-8") as handle:
            handle.write('BIN = ROOT / "bootstrap" / ".build" / "release" / "bin" / "pini-bootstrap"\n')
        doc_path = os.path.join(work, "doc.md")
        with open(doc_path, "w", encoding="utf-8") as handle:
            handle.write("产物落 `bootstrap/.build/<profile>/packages/`，临时区在 `bootstrap/.build/tmp`。\n")
        if hits_in(ok_path, "release"):
            return "自检失败：合规文件被判为违规"
        if len(hits_in(bad_path, "release")) != 1:
            return "自检失败：违规文件未被命中"
        if len(hits_in(split_path, "release")) != 1:
            return "自检失败：分段写法未被命中"
        if len(hits_in(boot_path, "release")) != 1:
            return "自检失败：自举产物路径的 profile 不符未被命中"
        if hits_in(boot_path, "debug"):
            return "自检失败：自举产物路径与清单一致时仍被报"
        if hits_in(join_path, "release"):
            return "自检失败：合规的自举产物路径被判为违规"
        if hits_in(doc_path, "release"):
            return "自检失败：占位写法或临时区被判为违规"
        found = scan(work, "release", skip_self=False)
        if len(found) != 3:
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
    profile = workspace_profile()
    found = scan(ROOT, profile, skip_self=True)
    if not found:
        print(f"构建口径门禁：通过（宿主读 .build/release/pini，自举产物 profile 为 {profile}）")
        # 旧产物留着不影响判定，但会让人误以为门禁在用它；明说一次，不红。
        stale = os.path.join(ROOT, ".build", "debug", "pini")
        if os.path.isfile(stale):
            print(" 注意  .build/debug/pini 还在，但不参与任何门禁；可删掉或手动留作调试")
        return 0
    for path, number, reason, text in found:
        print(f"{path}:{number}: [{reason}] {text}", file=sys.stderr)
    print(" 行不通  [口径] 宿主口径是 release；把引用改成 .build/release/pini，"
          "构建用 swift build -c release --disable-sandbox", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
