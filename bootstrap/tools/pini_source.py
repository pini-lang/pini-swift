#!/usr/bin/env python3
"""把字符串字面量写成单行 Pini 源文本。

生成器共用：转义规则只在这里定义，任何一处放宽都会让表在词法层被静默改写。
无法内联的控制字符直接拒绝，而不是悄悄留下原文。
"""


def pini_string(data):
    """UTF-8 字节转 Pini 字符串字面量内容（不含两侧引号）。"""
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
