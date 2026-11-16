#!/usr/bin/env python3
"""生成 unicode 包的码点分类表、规范化表、混淆映射表与脚本归属表。

数据来源有三处：分类与规范化取自本机 Python 的 unicodedata，混淆映射与脚本归属取自随仓库
提交的 UTS #39 与 UCD 数据文件。重新生成要求宿主数据正好是钉定版本，否则同一脚本会在不同
解释器上产出不同的表。产物是 Pini 源码，构建与运行不读宿主 Unicode 数据。

宿主语义层要用同一份混淆与脚本数据，故生成器同时把它们复制进 `Sources/PiniSemantics/Resources`
并登记摘要；两份不一致时门禁先红，不靠人工比对。

校验只看登记摘要与生成物头部的版本，不读宿主数据：门禁的判据是「提交的产物与登记的摘要
一致」，因此宿主 Python 的 Unicode 版本漂移不影响校验结果。

用法：
  python3 bootstrap/tools/gen-unicode-tables.py            # 重新生成并重写摘要清单
  python3 bootstrap/tools/gen-unicode-tables.py --check    # 按登记摘要校验生成物
  python3 bootstrap/tools/gen-unicode-tables.py --seal     # 只为现有产物登记摘要
"""

import hashlib
import os
import shutil
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pini_source import pini_string  # noqa: E402

UNICODE_VERSION = "15.1.0"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INTERNAL = os.path.join(ROOT, "bootstrap", "packages", "unicode", "src", "_internal")
OUT_CLASS = os.path.join(INTERNAL, "tables.pini")
OUT_NFC = os.path.join(INTERNAL, "nfc_tables.pini")
OUT_CONFUSABLE = os.path.join(INTERNAL, "confusable_tables.pini")
OUT_SCRIPTS = os.path.join(INTERNAL, "script_tables.pini")
CONFUSABLE_DATA = os.path.join(
    ROOT, "bootstrap", "tools", "data", "confusables-15.1.0.txt")
SCRIPTS_DATA = os.path.join(
    ROOT, "bootstrap", "tools", "data", "scripts-15.1.0.txt")
HOST_RESOURCES = os.path.join(ROOT, "Sources", "PiniSemantics", "Resources")
HOST_LEXER_RESOURCES = os.path.join(ROOT, "Sources", "PiniSyntax", "Resources")
DIGEST_MANIFEST = os.path.join(
    ROOT, "bootstrap", "tools", "data", "unicode-%s.digests" % UNICODE_VERSION)
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


CODE_WIDTH = 6


def hex_text(records):
    """定宽十六进制记录拼成一串：字段宽度固定，故可按偏移直接读，不必整体解码。"""
    return "".join(
        "".join("%0*x" % (width, value) for value, width in record)
        for record in records
    )


def emit_table(lines, name, records, value_width, note):
    """产出一张表：数据串、表描述与查表入口；查表由 table_search.pini 的通用二分承担。"""
    lines.append(note)
    lines.append("%sData|func() -> (String,):" % name)
    lines.append('    return "%s"' % hex_text(records))
    lines.append("")
    lines.append("%sTable|func() -> (HexTable,):" % name)
    lines.append("    var out = HexTable()")
    lines.append("    out.limit = %d" % len(records))
    lines.append("    out.recordWidth = %d" % sum(width for _, width in records[0]))
    lines.append("    out.valueWidth = %d" % value_width)
    lines.append("    return out")
    lines.append("")


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


# 高风险脚本各占一号；其余脚本一律 0，故中文与日韩的组合天然不参与混写判定。
HIGH_RISK_SCRIPTS = {"Latin": 1, "Cyrillic": 2, "Greek": 3}


def high_risk_scripts():
    """从 UCD 脚本数据取高风险脚本区间，只保留拉丁、西里尔与希腊。"""
    if not os.path.exists(SCRIPTS_DATA):
        raise SystemExit("生成器：缺少 %s" % SCRIPTS_DATA)
    with open(SCRIPTS_DATA, encoding="utf-8") as handle:
        header = handle.readline().strip()
    if UNICODE_VERSION not in header:
        raise SystemExit(
            "生成器：脚本数据版本与脚本钉定的 %s 不符（首行 %s）。"
            % (UNICODE_VERSION, header))
    ranges = []
    with open(SCRIPTS_DATA, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#")[0].strip()
            if not line:
                continue
            parts = [item.strip() for item in line.split(";")]
            if len(parts) < 2:
                continue
            value = HIGH_RISK_SCRIPTS.get(parts[1], 0)
            if value == 0:
                continue
            span = parts[0]
            if ".." in span:
                lo, hi = span.split("..")
            else:
                lo = hi = span
            ranges.append((int(lo, 16), int(hi, 16), value))
    ranges.sort()
    merged = []
    for lo, hi, value in ranges:
        if merged and merged[-1][2] == value and merged[-1][1] + 1 >= lo:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi), value)
        else:
            merged.append((lo, hi, value))
    return merged


def script_segments():
    """补上未被高风险脚本覆盖的码点，得到从 0 到上限连续覆盖的分段。"""
    out = []
    cursor = 0
    for lo, hi, value in high_risk_scripts():
        if lo > cursor:
            out.append((cursor, lo - 1, 0))
        out.append((lo, hi, value))
        cursor = hi + 1
    if cursor <= MAX_CODE:
        out.append((cursor, MAX_CODE, 0))
    return out


def build_scripts(ranges):
    records = [((start, CODE_WIDTH), (value, 2)) for start, _end, value in ranges]
    lines = [
        "; 本文件由 bootstrap/tools/gen-unicode-tables.py 生成，勿手改。",
        "; 数据版本 Unicode %s；记录为定宽十六进制，按码点升序。" % UNICODE_VERSION,
        "; 脚本号：0 其它，1 拉丁，2 西里尔，3 希腊。",
        "",
    ]
    emit_table(
        lines, "script", records, 2,
        "; 脚本表：每条 = 区间起点 6 位 + 脚本号 2 位，覆盖 0 到 U+10FFFF。")
    lines += [
        "; 码点脚本号：只区分三个高风险脚本，其余一律 0；越界码点按 0。",
        "scriptClassOf|func(_code: I32,) -> (I32,):",
        "    if _code < 0:",
        "        return 0",
        "    if _code > %s:" % hex_literal(MAX_CODE),
        "        return 0",
        "    return lookupRange(bytes = tempUtf8Bytes(scriptData()), table = scriptTable(), code = _code)",
        "",
    ]
    return "\n".join(lines)


def host_resource_copies():
    """数据各归其层：混淆给语义层，脚本给词法层，两条依赖方向都不许反向。"""
    placements = [
        (CONFUSABLE_DATA, HOST_RESOURCES),
        (SCRIPTS_DATA, HOST_LEXER_RESOURCES),
    ]
    copied = []
    for source, directory in placements:
        os.makedirs(directory, exist_ok=True)
        destination = os.path.join(directory, os.path.basename(source))
        shutil.copyfile(source, destination)
        copied.append(destination)
    return copied


def all_paths():
    """门禁与封存共用的路径集：生成物、数据源与宿主副本一视同仁。"""
    copies = [
        os.path.join(HOST_RESOURCES, os.path.basename(CONFUSABLE_DATA)),
        os.path.join(HOST_LEXER_RESOURCES, os.path.basename(SCRIPTS_DATA)),
    ]
    return [OUT_CLASS, OUT_NFC, OUT_CONFUSABLE, OUT_SCRIPTS, CONFUSABLE_DATA, SCRIPTS_DATA] + copies


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
    records = [((start, CODE_WIDTH), (value, 1)) for start, _end, value in ranges]
    lines = [
        "; 本文件由 bootstrap/tools/gen-unicode-tables.py 生成，勿手改。",
        "; 数据版本 Unicode %s；记录为定宽十六进制，按码点升序。" % UNICODE_VERSION,
        "; 分类：0 其它，1 字母（L*），2 数字（N*），3 空白（White_Space）。",
        "",
    ]
    emit_table(
        lines, "unicodeClass", records, 1,
        "; 分类表：每条 = 区间起点 6 位 + 类别 1 位，覆盖 0 到 U+10FFFF。")
    lines += [
        "; 码点分类：0 其它，1 字母，2 数字，3 空白；越界码点一律按其它。",
        "unicodeClassOf|func(_code: I32,) -> (I32,):",
        "    if _code < 0:",
        "        return 0",
        "    if _code > %s:" % hex_literal(MAX_CODE),
        "        return 0",
        "    return lookupRange(bytes = tempUtf8Bytes(unicodeClassData()), table = unicodeClassTable(), code = _code)",
        "",
        "; 已持字节视图时用它：同一份表多次查询只转一次。",
        "unicodeClassOfIn|func(_data: Array<U8>, _code: I32,) -> (I32,):",
        "    if _code < 0:",
        "        return 0",
        "    if _code > %s:" % hex_literal(MAX_CODE),
        "        return 0",
        "    return lookupRange(bytes = _data, table = unicodeClassTable(), code = _code)",
        "",
        "; 数据版本，供上层核对表与规范声明是否同版。",
        "unicodeDataVersion|func() -> (String,):",
        '    return "%s"' % UNICODE_VERSION,
        "",
    ]
    return "\n".join(lines)


def build_nfc(table, ccc, groups):
    pool, packed = pool_of(table)
    decomp = [
        ((code, CODE_WIDTH), ((packed[code][0] << DECOMP_SHIFT) | packed[code][1], 8))
        for code in sorted(packed)
    ]
    classes = [((start, CODE_WIDTH), (value, 2)) for start, _end, value in ccc]
    pairs = [
        ((first, CODE_WIDTH), (second, CODE_WIDTH), (composed, CODE_WIDTH))
        for first, items in groups
        for second, composed in items
    ]
    lines = [
        "; 本文件由 bootstrap/tools/gen-unicode-tables.py 生成，勿手改。",
        "; 数据版本 Unicode %s；记录为定宽十六进制，按码点升序。" % UNICODE_VERSION,
        "",
        "; 全量规范分解池：每个目标串都是递归分解后的结果，韩文不在表内。",
        "decompositionPool|func() -> (String,):",
        '    return "%s"' % pini_string(pool),
        "",
    ]
    emit_table(
        lines, "decomposition", decomp, 8,
        "; 分解索引：每条 = 码点 6 位 + 池内位置 8 位（字节偏移左移 %d 位或上字节长）。" % DECOMP_SHIFT)
    lines += [
        "; 码点的分解在池中的位置；未列出的码点答 -1。",
        "decompositionPacked|func(_code: I32,) -> (I32,):",
        "    return lookupExact(bytes = tempUtf8Bytes(decompositionData()), table = decompositionTable(), code = _code)",
        "",
        "; 已持字节视图时用它：同一份表多次查询只转一次。",
        "decompositionPackedIn|func(_data: Array<U8>, _code: I32,) -> (I32,):",
        "    return lookupExact(bytes = _data, table = decompositionTable(), code = _code)",
        "",
    ]
    emit_table(
        lines, "combining", classes, 2,
        "; 组合类表：每条 = 区间起点 6 位 + 组合类 2 位，覆盖 0 到 U+10FFFF。")
    lines += [
        "; 组合类（Canonical_Combining_Class）：0 为起始字符，越界码点答 0。",
        "combiningClassOf|func(_code: I32,) -> (I32,):",
        "    if _code < 0:",
        "        return 0",
        "    if _code > %s:" % hex_literal(MAX_CODE),
        "        return 0",
        "    return lookupRange(bytes = tempUtf8Bytes(combiningData()), table = combiningTable(), code = _code)",
        "",
        "; 已持字节视图时用它：同一份表多次查询只转一次。",
        "combiningClassOfIn|func(_data: Array<U8>, _code: I32,) -> (I32,):",
        "    if _code < 0:",
        "        return 0",
        "    if _code > %s:" % hex_literal(MAX_CODE),
        "        return 0",
        "    return lookupRange(bytes = _data, table = combiningTable(), code = _code)",
        "",
    ]
    emit_table(
        lines, "composition", pairs, CODE_WIDTH,
        "; 组合表：每条 = 首字符 6 位 + 次字符 6 位 + 合成码点 6 位，按两码点升序。")
    lines += [
        "; 单步规范组合：两个标量合成一个码点，-1 表示不成对；韩文由调用方算术处理。",
        "compositionOf|func(first: I32, second: I32,) -> (I32,):",
        "    return lookupPair(bytes = tempUtf8Bytes(compositionData()), table = compositionTable(), first = first, second = second)",
        "",
        "; 已持字节视图时用它：同一份表多次查询只转一次。",
        "compositionOfIn|func(_data: Array<U8>, _first: I32, _second: I32,) -> (I32,):",
        "    return lookupPair(bytes = _data, table = compositionTable(), first = _first, second = _second)",
        "",
    ]
    return "\n".join(lines)


def build_confusable(table):
    pool, packed = pool_of(table)
    entries = [
        ((code, CODE_WIDTH), ((packed[code][0] << CONFUSABLE_SHIFT) | packed[code][1], 8))
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
    ]
    emit_table(
        lines, "confusable", entries, 8,
        "; 混淆索引：每条 = 源码点 6 位 + 池内位置 8 位（字节偏移左移 %d 位或上字节长）。" % CONFUSABLE_SHIFT)
    lines += [
        "; 源码点的目标在池中的位置；未列出的码点答 -1。",
        "confusablePacked|func(_code: I32,) -> (I32,):",
        "    return lookupExact(bytes = tempUtf8Bytes(confusableData()), table = confusableTable(), code = _code)",
        "",
        "; 已持字节视图时用它：同一份表多次查询只转一次。",
        "confusablePackedIn|func(_data: Array<U8>, _code: I32,) -> (I32,):",
        "    return lookupExact(bytes = _data, table = confusableTable(), code = _code)",
        "",
    ]
    return "\n".join(lines)


def relative(path):
    """清单里记仓库相对路径：换机器、换工作区都不影响摘要。"""
    return os.path.relpath(path, ROOT)


def digest_of(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return True


def write_manifest(paths):
    """重写摘要清单：生成物与数据源各一条，按路径排序。"""
    lines = ["%s  %s" % (digest_of(path), relative(path)) for path in sorted(paths)]
    os.makedirs(os.path.dirname(DIGEST_MANIFEST), exist_ok=True)
    with open(DIGEST_MANIFEST, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    return DIGEST_MANIFEST


def read_manifest():
    """读出登记的摘要；缺文件或格式坏都答 None，由调用方报错。"""
    try:
        with open(DIGEST_MANIFEST, encoding="utf-8") as handle:
            rows = [line.split() for line in handle if line.strip()]
    except FileNotFoundError:
        return None
    if not rows or any(len(row) != 2 or len(row[0]) != 64 for row in rows):
        return None
    return rows


def verify(paths):
    """按登记摘要校验：产物与数据源逐字节一致，且生成物头部声明的版本是钉定版本。"""
    rows = read_manifest()
    if rows is None:
        print("生成器：缺少或读不懂摘要清单 %s，先不带 --check 跑一次。"
              % relative(DIGEST_MANIFEST), file=sys.stderr)
        return 1
    ok = True
    recorded = {}
    for hexdigest, rel in rows:
        recorded[rel] = hexdigest
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            print("生成器：清单登记的 %s 不存在。" % rel, file=sys.stderr)
            ok = False
            continue
        if digest_of(path) != hexdigest:
            print("生成器：%s 与登记摘要不符，重新生成并提交。" % rel, file=sys.stderr)
            ok = False
    for path in paths:
        rel = relative(path)
        if rel not in recorded:
            print("生成器：%s 未登记摘要，重新生成并提交。" % rel, file=sys.stderr)
            ok = False
    if not declared_version_ok(paths):
        ok = False
    if not ok:
        return 1
    print("生成器：%d 份文件与登记摘要一致（Unicode %s），校验不读宿主数据。"
          % (len(rows), UNICODE_VERSION))
    return 0


def declared_version_ok(paths):
    """生成物头部声明的版本必须是钉定版本：用错版本重建时摘要可能对得上，头部对不上。"""
    ok = True
    for path, label in [(OUT_CLASS, "Unicode"), (OUT_NFC, "Unicode"),
                        (OUT_CONFUSABLE, "UTS39")]:
        marker = "%s %s" % (label, UNICODE_VERSION)
        with open(path, encoding="utf-8") as handle:
            header = handle.readline() + handle.readline()
        if marker not in header:
            print("生成器：%s 头部未声明 %s。" % (relative(path), marker), file=sys.stderr)
            ok = False
    return ok


def seal(paths):
    """只为现有产物登记摘要：复制别的机器上的生成物后，不必重跑数据源。"""
    if not declared_version_ok(paths):
        return 1
    manifest = write_manifest(paths)
    print("生成器：已为 %d 份文件登记摘要（%s）。" % (len(paths), relative(manifest)))
    return 0


def main():
    check = "--check" in sys.argv[1:]
    if check:
        return verify(all_paths())
    if "--seal" in sys.argv[1:]:
        return seal(all_paths())
    if unicodedata.unidata_version != UNICODE_VERSION:
        print(
            "生成器：本机 Unicode 数据是 %s，脚本钉定 %s。换用匹配版本的 Python 再生成。"
            % (unicodedata.unidata_version, UNICODE_VERSION),
            file=sys.stderr)
        return 2
    ranges = segments()
    table = decompositions()
    ccc = combining_ranges()
    groups = composition_groups(table)
    confusable = confusables()
    script_ranges = script_segments()

    outputs = [
        (OUT_CLASS, build_class(ranges), "%d 个分类区间" % len(ranges)),
        (OUT_NFC, build_nfc(table, ccc, groups),
         "%d 条分解 / %d 段组合类 / %d 组组合" % (len(table), len(ccc), len(groups))),
        (OUT_CONFUSABLE, build_confusable(confusable),
         "%d 条混淆映射" % len(confusable)),
        (OUT_SCRIPTS, build_scripts(script_ranges),
         "%d 个脚本区间" % len(script_ranges)),
    ]
    for path, text, _ in outputs:
        write(path, text)
    host_resource_copies()
    manifest = write_manifest(all_paths())
    for path, _, summary in outputs:
        print("生成器：写入 %s（%s）。" % (path, summary))
    print("生成器：摘要清单 %s 已重写。" % relative(manifest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
