#!/usr/bin/env python3
"""生成 diagnostics 包的诊断码表。

码表源自主机诊断资源 `Diagnostics.zh.toml`：自举编译器与宿主必须吐同一组稳定码，
码表因此不另抄一份，而是从同一份资源生成。产物是 Pini 源码，构建与运行都不读 TOML。

用法：
  python3 bootstrap/tools/gen-diagnostics-table.py            # 写入生成物
  python3 bootstrap/tools/gen-diagnostics-table.py --check    # 只校验生成物是否最新
"""

import os
import sys
import tomllib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pini_source import pini_string  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT, "Sources", "PiniSemantics", "Resources", "Diagnostics.zh.toml")
OUTPUT = os.path.join(
    ROOT, "bootstrap", "packages", "diagnostics", "src", "_internal", "codes.pini")


def load_codes():
    """码 → {message, suggestion}；`labels` 是标签组表，不是码。"""
    with open(SOURCE, "rb") as handle:
        table = tomllib.load(handle)
    codes = {}
    for key in sorted(table):
        if key == "labels":
            continue
        fields = table[key]
        message = fields.get("message", "")
        if not message:
            raise SystemExit("生成器：%s 没有消息模板，码表不能有空消息。" % key)
        codes[key] = (message, fields.get("suggestion", ""))
    if not codes:
        raise SystemExit("生成器：%s 没有解析出任何诊断码。" % SOURCE)
    return codes


def build(codes):
    lines = [
        "; 本文件由 bootstrap/tools/gen-diagnostics-table.py 生成，勿手改。",
        "; 源自主机诊断资源的 zh 表；码表是封闭集合，未登记的码不参与渲染。",
        "",
        "; 已登记的诊断码数量，供门禁核对表规模。",
        "diagnosticCodeCount|func() -> (I32,):",
        "    return %d" % len(codes),
        "",
        "; 码的消息模板；未登记答空串。占位符由调用方按诊断负载填充。",
        "diagnosticMessage|func(_code: String,) -> (String,):",
    ]
    for code, (message, _) in codes.items():
        lines.append('    if code == "%s":' % code)
        lines.append('        return "%s"' % pini_string(message.encode("utf-8")))
    lines.append('    return ""')
    lines += [
        "",
        "; 码的修复建议模板；没有建议答空串。",
        "diagnosticSuggestion|func(_code: String,) -> (String,):",
    ]
    for code, (_, suggestion) in codes.items():
        if not suggestion:
            continue
        lines.append('    if code == "%s":' % code)
        lines.append('        return "%s"' % pini_string(suggestion.encode("utf-8")))
    lines.append('    return ""')
    lines.append("")
    return "\n".join(lines)


def main():
    codes = load_codes()
    text = build(codes)
    check = "--check" in sys.argv[1:]
    if check:
        try:
            with open(OUTPUT, encoding="utf-8") as handle:
                current = handle.read()
        except FileNotFoundError:
            print("生成器：缺少生成物 %s，先不带 --check 跑一次。" % OUTPUT, file=sys.stderr)
            return 1
        if current != text:
            print("生成器：%s 与主机诊断表不一致，重新生成并提交。" % OUTPUT, file=sys.stderr)
            return 1
        print("生成器：诊断码表与主机诊断资源一致（%d 个码）。" % len(codes))
        return 0
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("生成器：写入 %s（%d 个码）。" % (OUTPUT, len(codes)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
