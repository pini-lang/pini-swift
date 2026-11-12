#!/usr/bin/env python3
"""生成 unicode 包的码点分类表、规范化表与混淆映射表。

数据来源有两处：分类与规范化取自本机 Python 的 unicodedata，混淆映射取自随仓库提交的
UTS #39 数据文件。两者的版本都钉在 Unicode 15.1.0，不匹配即拒绝生成，避免同一脚本在
不同解释器或不同数据上产出不同的表。产物是 Pini 源码，构建与运行不读宿主 Unicode 数据。

用法：
  python3 bootstrap/tools/gen-unicode-tables.py            # 写入生成物
  python3 bootstrap/tools/gen-unicode-tables.py --check    # 只校验生成物是否最新
"""

import os
import sys
import unicodedata

UNICODE_VERSION = "15.1.0"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INTERNAL = os.path.join(ROOT, "bootstrap", "packages", "unicode", "src", "_internal")
OUT_CLASS = os.path.join(INTERNAL, "tables.pini")
OUT_NFC = os.path.join(INTERNAL, "nfc_tables.pini")
OUT_CONFUSABLE = os.path.join(INTERNAL, "confusable_tables.pini")
CONFUSABLE_DATA = os.path.join(
    ROOT, "bootstrap", "tools", "data", "confusables-15.1.0.txt")
MAX_CODE = 0x10FFFF
HANGUL_FIRST = 0xAC00
HANGUL_LAST = 0xD7A3
HANGUL_L_BASE = 0x1100
HANGUL_V_BASE = 0x1161
HANGUL_T_BASE = 0x11A7
HANGUL_T_COUNT = 28
HANGUL_N_COUNT = 21 * HANGUL_T_COUNT
BLOCK = 64
DECOMP_SHIFT = 4
CONFUSABLE_SHIFT = 5

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


def emit_range_tree(ranges, lines, depth):
    """平衡二叉判定：区间按起点升序，叶子答该区间的值。"""
    pad = "    " * depth
    if len(ranges) == 1:
        lines.append("%sreturn %d" % (pad, ranges[0][2]))
        return
    mid = len(ranges) // 2
    lines.append("%sif code < %s:" % (pad, hex_literal(ranges[mid][0])))
    emit_range_tree(ranges[:mid], lines, depth + 1)
    lines.append("%selse:" % pad)
    emit_range_tree(ranges[mid:], lines, depth + 1)


def emit_blocked_exact(entries, lines, depth):
    """精确匹配：块间按首码点二分，块内逐条相等比较；未命中一律 -1。"""
    blocks = [entries[i:i + BLOCK] for i in range(0, len(entries), BLOCK)]
    pad = "    " * depth
    if len(blocks) == 1:
        for code, value in blocks[0]:
            lines.append("%sif code == %s:" % (pad, hex_literal(code)))
            lines.append("%s    return %s" % (pad, value))
        lines.append("%sreturn -1" % pad)
        return
    mid = (len(blocks) + 1) // 2
    lines.append("%sif code < %s:" % (pad, hex_literal(blocks[mid][0][0])))
    emit_blocked_exact([e for b in blocks[:mid] for e in b], lines, depth + 1)
    lines.append("%selse:" % pad)
    emit_blocked_exact([e for b in blocks[mid:] for e in b], lines, depth + 1)


def emit_composition(groups, lines, depth):
    """先按起始字符二分，叶子核对该起始字符后逐条比较第二个字符。"""
    pad = "    " * depth
    if len(groups) == 1:
        first, pairs = groups[0]
        lines.append("%sif first != %s:" % (pad, hex_literal(first)))
        lines.append("%s    return -1" % pad)
        for second, composed in pairs:
            lines.append("%sif second == %s:" % (pad, hex_literal(second)))
            lines.append("%s    return %s" % (pad, hex_literal(composed)))
        lines.append("%sreturn -1" % pad)
        return
    mid = (len(groups) + 1) // 2
    lines.append("%sif first < %s:" % (pad, hex_literal(groups[mid][0])))
    emit_composition(groups[:mid], lines, depth + 1)
    lines.append("%selse:" % pad)
    emit_composition(groups[mid:], lines, depth + 1)


def decompositions():
    """全量规范分解：码点 → 目标标量表；韩文按算术处理，不进表。"""
    out = {}
    for code in range(MAX_CODE + 1):
        if HANGUL_FIRST <= code <= HANGUL_LAST:
            continue
        text = unicodedata.normalize("NFD", chr(code))
        if text != chr(code):
            out[code] = [ord(ch) for ch in text]
    return out


def combining_ranges():
    """组合类区间：覆盖整个码点空间，零类也要占区间，否则树查询会把起始字符读成非零。"""
    out = []
    for code in range(MAX_CODE + 1):
        value = unicodedata.combining(chr(code))
        if out and out[-1][1] == code - 1 and out[-1][2] == value:
            out[-1][1] = code
        else:
            out.append([code, code, value])
    return [tuple(item) for item in out]


def composition_groups(table):
    """单步组合对：可合成的两个标量归到起始字符下；有分解但被排除的不进表。"""
    groups = {}
    for code, seq in table.items():
        if len(seq) != 2:
            continue
        if unicodedata.normalize("NFC", chr(code)) != chr(code):
            continue
        groups.setdefault(seq[0], []).append((seq[1], code))
    return [(first, sorted(groups[first])) for first in sorted(groups)]


def confusables():
    """UTS #39 单码点映射；多码点源行不进表（本实现只折单码点）。"""
    if not os.path.exists(CONFUSABLE_DATA):
        raise SystemExit("生成器：缺少 %s" % CONFUSABLE_DATA)
    version = None
    table = {}
    with open(CONFUSABLE_DATA, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#")[0].strip()
            if not line:
                continue
            parts = [item.strip() for item in line.split(";")]
            if len(parts) < 2:
                continue
            source = [int(item, 16) for item in parts[0].split()]
            target = [int(item, 16) for item in parts[1].split()]
            if len(source) == 1:
                table[source[0]] = target
    with open(CONFUSABLE_DATA, encoding="utf-8") as handle:
        for raw in handle:
            if raw.startswith("# Version:"):
                version = raw.split(":", 1)[1].strip()
                break
    if version != UNICODE_VERSION:
        raise SystemExit(
            "生成器：混淆数据版本是 %s，脚本钉定 %s。" % (version, UNICODE_VERSION))
    return table


def pini_string(data):
    """把 UTF-8 字节写成单行 Pini 字符串字面量；控制字符无法内联时直接拒绝。"""
    out = []
    for ch in data.decode("utf-8"):
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            raise SystemExit("生成器：目标串含无法内联的控制字符 U+%04X" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


def pool_of(table):
    """把目标串按码点升序拼成 UTF-8 池，返回池与 码点→(偏移, 字节长)。"""
    chunks = []
    packed = {}
    offset = 0
    for code in sorted(table):
        data = "".join(chr(item) for item in table[code]).encode("utf-8")
        packed[code] = (offset, len(data))
        chunks.append(data)
        offset += len(data)
    return b"".join(chunks), packed


def build_class(ranges):
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
    emit_range_tree(ranges, lines, 1)
    lines += [
        "",
        "; 数据版本，供上层核对表与规范声明是否同版。",
        "unicodeDataVersion|func() -> (String,):",
        '    return "%s"' % UNICODE_VERSION,
        "",
    ]
    return "\n".join(lines)


def build_nfc(table, ccc, groups):
    pool, packed = pool_of(table)
    entries = [
        (code, "%d" % ((packed[code][0] << DECOMP_SHIFT) | packed[code][1]))
        for code in sorted(packed)
    ]
    lines = [
        "; 本文件由 bootstrap/tools/gen-unicode-tables.py 生成，勿手改。",
        "; 数据版本 Unicode %s；分解目标按码点升序拼成 UTF-8 池。" % UNICODE_VERSION,
        "",
        "; 全量规范分解池：每个目标串都是递归分解后的结果，韩文不在表内。",
        "decompositionPool|func() -> (String,):",
        '    return "%s"' % pini_string(pool),
        "",
        "; 码点的分解在池中的位置：字节偏移左移 %d 位或上字节长度；-1 表示无分解。" % DECOMP_SHIFT,
        "decompositionPacked|func(code: I32,) -> (I32,):",
    ]
    emit_blocked_exact(entries, lines, 1)
    lines += [
        "",
        "; 组合类（Canonical_Combining_Class）区间：0 为起始字符，覆盖整个码点空间。",
        "combiningClassOf|func(code: I32,) -> (I32,):",
        "    if code < 0:",
        "        return 0",
        "    if code > %s:" % hex_literal(MAX_CODE),
        "        return 0",
    ]
    emit_range_tree(ccc, lines, 1)
    lines += [
        "",
        "; 单步规范组合：两个标量合成一个码点，-1 表示不成对；韩文由调用方算术处理。",
        "compositionOf|func(first: I32, second: I32,) -> (I32,):",
    ]
    emit_composition(groups, lines, 1)
    lines.append("")
    return "\n".join(lines)


def build_confusable(table):
    pool, packed = pool_of(table)
    entries = [
        (code, "%d" % ((packed[code][0] << CONFUSABLE_SHIFT) | packed[code][1]))
        for code in sorted(packed)
    ]
    lines = [
        "; 本文件由 bootstrap/tools/gen-unicode-tables.py 生成，勿手改。",
        "; 数据版本 UTS39 %s，源自随仓库提交的 confusables 数据。" % UNICODE_VERSION,
        "",
        "; 混淆目标池：按源码点升序拼接的 UTF-8 字节，含多标量目标。",
        "confusablePool|func() -> (String,):",
        '    return "%s"' % pini_string(pool),
        "",
        "; 源码点的目标在池中的位置：字节偏移左移 %d 位或上字节长度；-1 表示无映射。" % CONFUSABLE_SHIFT,
        "confusablePacked|func(code: I32,) -> (I32,):",
    ]
    emit_blocked_exact(entries, lines, 1)
    lines.append("")
    return "\n".join(lines)


def write(path, text, check):
    if check:
        try:
            with open(path, encoding="utf-8") as handle:
                current = handle.read()
        except FileNotFoundError:
            print("生成器：缺少生成物 %s，先不带 --check 跑一次。" % path, file=sys.stderr)
            return False
        if current != text:
            print("生成器：%s 与数据源不一致，重新生成并提交。" % path, file=sys.stderr)
            return False
        return True
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return True


def main():
    if unicodedata.unidata_version != UNICODE_VERSION:
        print(
            "生成器：本机 Unicode 数据是 %s，脚本钉定 %s。换用匹配版本的 Python 再生成。"
            % (unicodedata.unidata_version, UNICODE_VERSION),
            file=sys.stderr)
        return 2
    check = "--check" in sys.argv[1:]
    ranges = segments()
    table = decompositions()
    ccc = combining_ranges()
    groups = composition_groups(table)
    confusable = confusables()

    outputs = [
        (OUT_CLASS, build_class(ranges), "%d 个分类区间" % len(ranges)),
        (OUT_NFC, build_nfc(table, ccc, groups),
         "%d 条分解 / %d 段组合类 / %d 组组合" % (len(table), len(ccc), len(groups))),
        (OUT_CONFUSABLE, build_confusable(confusable),
         "%d 条混淆映射" % len(confusable)),
    ]
    ok = True
    for path, text, summary in outputs:
        if not write(path, text, check):
            ok = False
    if not ok:
        return 1
    if check:
        print("生成器：三份生成物与 Unicode %s 数据一致（%s）。"
              % (UNICODE_VERSION, "；".join(item[2] for item in outputs)))
        return 0
    for path, _, summary in outputs:
        print("生成器：写入 %s（%s）。" % (path, summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
