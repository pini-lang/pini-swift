#!/usr/bin/env python3
"""生成 unicode 包的码点分类表。

数据来源是本机 Python 的 unicodedata；版本钉在 UNICODE_VERSION，不匹配即拒绝生成，
避免同一脚本在不同解释器上产出不同的表。产物是 Pini 源码，构建与运行不读宿主 Unicode 数据。

用法：
  python3 bootstrap/tools/gen-unicode-tables.py            # 写入生成物
  python3 bootstrap/tools/gen-unicode-tables.py --check    # 只校验生成物是否最新
"""

import os
import sys
import unicodedata

UNICODE_VERSION = "15.1.0"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUT = os.path.join(
    ROOT, "bootstrap", "packages", "unicode", "src", "_internal", "tables.pini")
MAX_CODE = 0x10FFFF

# White_Space 属性自 Unicode 4.0 起未变；它不随通用类别表达，因此单独列出。
WHITE_SPACE = frozenset([
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
    0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F,
    0x205F, 0x3000,
])

OTHER, LETTER, NUMBER, SPACE = 0, 1, 2, 3


def classify(code):
    """0 其它，1 字母（L*），2 数字（N*），3 空白（White_Space）。"""
    if code in WHITE_SPACE:
        return SPACE
    category = unicodedata.category(chr(code))
    if category[0] == "L":
        return LETTER
    if category[0] == "N":
        return NUMBER
    return OTHER


def segments():
    """把码点空间切成分类恒定的闭区间，按起点升序。"""
    out = []
    start = 0
    previous = classify(0)
    for code in range(1, MAX_CODE + 1):
        current = classify(code)
        if current != previous:
            out.append((start, code - 1, previous))
            start = code
            previous = current
    out.append((start, MAX_CODE, previous))
    return out


def hex_literal(value):
    return "0x%X" % value


def emit_tree(ranges, lo, hi, depth, lines):
    """按中点切分区间下标，生成平衡二叉判定；深度约 log2(区间数)。"""
    indent = "    " * depth
    if lo == hi:
        lines.append("%sreturn %d" % (indent, ranges[lo][2]))
        return
    mid = (lo + hi + 1) // 2
    lines.append("%sif code < %s:" % (indent, hex_literal(ranges[mid][0])))
    emit_tree(ranges, lo, mid - 1, depth + 1, lines)
    lines.append("%selse:" % indent)
    emit_tree(ranges, mid, hi, depth + 1, lines)


def build(ranges):
    lines = [
        "; 本文件由 bootstrap/tools/gen-unicode-tables.py 生成，勿手改。",
        "; 数据版本 Unicode %s；区间为闭区间，按码点升序。" % UNICODE_VERSION,
        "; 分类：0 其它，1 字母（L*），2 数字（N*），3 空白（White_Space）。",
        "",
        "; 码点分类：0 其它，1 字母，2 数字，3 空白；越界码点一律按其它。",
        "unicodeClassOf|func(code: I32,) -> (I32,):",
        "    if code < 0:",
        "        return 0",
        "    if code > %s:" % hex_literal(MAX_CODE),
        "        return 0",
    ]
    emit_tree(ranges, 0, len(ranges) - 1, 1, lines)
    lines += [
        "",
        "; 数据版本，供上层核对表与规范声明是否同版。",
        "unicodeDataVersion|func() -> (String,):",
        '    return "%s"' % UNICODE_VERSION,
        "",
    ]
    return "\n".join(lines)


def main():
    if unicodedata.unidata_version != UNICODE_VERSION:
        print(
            "生成器：本机 Unicode 数据是 %s，脚本钉定 %s。换用匹配版本的 Python 再生成。"
            % (unicodedata.unidata_version, UNICODE_VERSION),
            file=sys.stderr)
        return 2
    ranges = segments()
    text = build(ranges)
    check = "--check" in sys.argv[1:]
    if check:
        try:
            with open(OUTPUT, encoding="utf-8") as handle:
                current = handle.read()
        except FileNotFoundError:
            print("生成器：缺少生成物 %s，先不带 --check 跑一次。" % OUTPUT, file=sys.stderr)
            return 1
        if current != text:
            print("生成器：%s 与数据源不一致，重新生成并提交。" % OUTPUT, file=sys.stderr)
            return 1
        print("生成器：生成物与 Unicode %s 数据一致（%d 个区间）。" % (UNICODE_VERSION, len(ranges)))
        return 0
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("生成器：写入 %s（Unicode %s，%d 个区间）。" % (OUTPUT, UNICODE_VERSION, len(ranges)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
