#!/usr/bin/env python3
"""差异普查：宿主与自举在命令、通道、诊断、程序四个面上的差集。

WHY THIS EXISTS
---------------
「对齐宿主完整功能」的起点是一张差集表，不是印象。本脚本把四张表固定成可重生成的产物，
每张表的取值都来自一次真实读取或一次真实运行：命令表读两侧分派代码，通道表读宿主能力矩阵
与自举节点普查，诊断表读权威 TOML 与自举源码里的发码点，程序表把示例路径直接交给编译器
跑三条腿。表里出现「无」「异」即待办，不会被静默忽略。

WHAT IT WRITES
    bootstrap/tests/parity/commands.tsv     宿主每条命令的开关对自举同名项
    bootstrap/tests/parity/channels.tsv     通道 × 族，自举另记接通节点数
    bootstrap/tests/parity/diagnostics.tsv  宿主码全集对自举已发码，附缺码依据
    bootstrap/tests/parity/programs.tsv     examples 逐个过 check / lower / emit

人工来源（不生成，只读）：
    bootstrap/tests/parity/command-disposition.tsv  每个非「有」命令的去向
    bootstrap/tests/parity/diagnostic-basis.tsv     每条缺码的依据

用法：
  python3 bootstrap/tools/parity.py                # 重取四张表
  python3 bootstrap/tools/parity.py --check        # 只验三张静态表；程序表要 --full
  python3 bootstrap/tools/parity.py --check --full  # 连程序表一起验（交付前跑）
"""

import argparse
import importlib.util
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "bootstrap" / "tests" / "parity"
HOST_MAIN = ROOT / "Sources" / "PiniCLI" / "main.swift"
SELF_MAIN = ROOT / "bootstrap" / "packages" / "driver" / "src" / "api" / "main.pini"
DIAG_TOML = ROOT / "Sources" / "PiniSemantics" / "Resources" / "Diagnostics.zh.toml"
CODES_PINI = ROOT / "bootstrap" / "packages" / "diagnostics" / "src" / "_internal" / "codes.pini"
EXAMPLES = ROOT / "examples"
TIMEOUT = 120
COMMAND_DISPOSITIONS = OUT / "command-disposition.tsv"
DIAGNOSTIC_BASIS = OUT / "diagnostic-basis.tsv"


def fail(message):
    print(f" 行不通  [普查] {message}", file=sys.stderr)


def ledger(path):
    """读人工来源表：首列作键，返回第二三列。首个非注释行是表头，跳过。

    缺表返回空表，由调用方按「缺行」报出，不静默取默认值。
    """
    table = {}
    if not path.is_file():
        return table
    header = True
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if header:
            header = False
            continue
        if len(cols) >= 2:
            table[cols[0]] = (cols[1], cols[2] if len(cols) > 2 else "")
    return table


def host_binary():
    """宿主产物：先认显式变量，否则只认 release；debug 不参与门禁。"""
    candidates = (
        os.environ.get("PINI_HOST_BIN"),
        os.environ.get("PINI_CLI_BIN"),
        ".build/release/pini",
    )
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate)
        if not path.is_absolute():
            path = ROOT / path
        if path.is_file() and os.access(path, os.X_OK):
            return path
    fail("缺宿主可执行文件；先 swift build -c release --disable-sandbox")
    sys.exit(2)


def bootstrap_binary():
    path = Path(
        os.environ.get("PINI_BOOTSTRAP_BIN")
        or (ROOT / "bootstrap" / ".build" / "release" / "bin" / "pini-bootstrap")
    )
    if not path.is_file() or not os.access(path, os.X_OK):
        fail(f"缺自举产物 {path}；先 bash bootstrap/tools/build.sh")
        sys.exit(2)
    return path


def host_binary():
    path = Path(os.environ.get("PINI_HOST_BIN") or (ROOT / ".build" / "release" / "pini"))
    if not path.is_file() or not os.access(path, os.X_OK):
        fail(f"缺宿主产物 {path}；先 swift build -c release --disable-sandbox")
        sys.exit(2)
    return path


def run(command, cwd=None):
    merged = dict(os.environ)
    try:
        done = subprocess.run(
            [str(one) for one in command],
            cwd=str(cwd or ROOT),
            env=merged,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"超过 {TIMEOUT} 秒"
    return done.returncode, done.stdout, done.stderr


# ---------------------------------------------------------------- 命令表

def host_commands():
    """宿主命令 → (别名, 该 case 的正文)。正文用于取开关。"""
    text = HOST_MAIN.read_text(encoding="utf-8")
    body = text[text.index("switch command {"):]
    # 顶层 case 顶格书写，嵌套 switch 有缩进，故 ^case 只命中命令分派。
    marks = list(re.finditer(r'^case ((?:"[^"]+"(?:,\s*)?)+):', body, re.M))
    table = {}
    for index, mark in enumerate(marks):
        labels = re.findall(r'"([^"]+)"', mark.group(1))
        end = marks[index + 1].start() if index + 1 < len(marks) else len(body)
        table[labels[0]] = (labels, body[mark.end():end])
    return table


def switches_in(text):
    found = set()
    for raw in re.findall(r'"(?<!\-)(--?[A-Za-z][A-Za-z0-9=-]*)"', text):
        found.add(raw.split("=", 1)[0])
    return found


def self_commands():
    """自举子命令 → 该子命令后面的参数解析正文。"""
    text = SELF_MAIN.read_text(encoding="utf-8")
    marks = list(re.finditer(r'args\[0\] == "([A-Za-z]+)"', text))
    table = {}
    for index, mark in enumerate(marks):
        end = marks[index + 1].start() if index + 1 < len(marks) else len(text)
        table[mark.group(1)] = text[mark.end():end]
    return table


def commands_table():
    """两个方向都交代：宿主有而自举无记「无」，自举有而宿主无记「自举独有」。

    每条非「有」的行都要有一行处置；缺行即拒生成，避免差项悬空。
    """
    host = host_commands()
    mine = self_commands()
    disposition = ledger(COMMAND_DISPOSITIONS)
    lines = ["# 命令表：宿主每条命令的开关对自举同名项，另收自举独有命令。",
             "# 状态：有 = 同名同开关；部分 = 有但缺开关；无 = 自举没有；自举独有 = 宿主没有。",
             "# 处置：自举内部通道 / 待补齐 / 保留差异 / 待核；已收口记 -。",
             "# 由 bootstrap/tools/parity.py 生成，勿手改；只许缩小，某行转「有」时门禁会红。",
             "命令\t宿主开关\t自举\t自举缺开关\t状态\t处置"]
    missing = []
    for name in sorted(set(host) | set(mine)):
        if name not in mine:
            wanted = ",".join(sorted(switches_in(host[name][1]))) or "-"
            cells = (name, wanted, "无", wanted, "无")
        elif name not in host:
            cells = (name, "-", "有", "-", "自举独有")
        else:
            wanted = switches_in(host[name][1])
            have = switches_in(mine[name])
            short = sorted(wanted - have)
            cells = (name, ",".join(sorted(wanted)) or "-", "有",
                     ",".join(short) or "-", "部分" if short else "有")
        entry = disposition.get(name)
        if cells[4] != "有" and entry is None:
            missing.append(name)
        lines.append("\t".join(cells) + "\t" + (entry[0] if entry else "-"))
    if missing:
        fail(f"命令处置表缺行：{', '.join(missing)}")
        sys.exit(2)
    return "\n".join(lines) + "\n", host, mine


# ---------------------------------------------------------------- 通道表

def load_capability_reach():
    path = ROOT / "bootstrap" / "tools" / "capability-reach.py"
    spec = importlib.util.spec_from_file_location("capability_reach", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def host_matrix():
    """宿主 backends --tsv：族 → 通道 → yes/no，另带 output 行。"""
    code, out, err = run([host_binary(), "backends", "--tsv"])
    if code != 0:
        fail(f"宿主 backends --tsv 失败：{err.strip()}")
        sys.exit(2)
    rows = [line.split("\t") for line in out.splitlines() if line.strip()]
    header, outputs = rows[0], rows[1]
    channels = header[1:]
    table = {}
    for row in rows[2:]:
        table[row[0]] = dict(zip(channels, row[1:]))
    return channels, table, dict(zip(channels, outputs[1:]))


def self_family_counts():
    """族 → (已声明, 已接通节点数)，取自能力普查同一套读法。"""
    reach = load_capability_reach()
    entries = reach.contract_entries()
    families = reach.family_names()
    emitted = reach.emitted_tags()
    declared = reach.declared_families()
    counts = {}
    for code, name in enumerate(families):
        mine = [tag for tag, _node, family in entries if family == code]
        counts[name] = (code in declared, sum(1 for tag in mine if tag in emitted))
    return counts


def channels_table():
    channels, matrix, outputs = host_matrix()
    counts = self_family_counts()
    lines = ["# 通道表：通道 × 族。宿主列取 backends --tsv，自举列取能力普查；「接通」是已发射的节点数。",
             "# 自举没有的通道整列为「无」；embedded_min 按裁定留差异，不进归零判据。",
             "# 由 bootstrap/tools/parity.py 生成，勿手改；只许缩小。",
             "通道\t产出\t族\t宿主\t自举声明\t自举接通\t状态"]
    for channel in channels:
        for family, cells in matrix.items():
            host_side = cells.get(channel, "no")
            if channel == "llvm":
                declared, reach = counts.get(family, (False, 0))
                self_decl, self_reach = ("1" if declared else "0"), str(reach)
                if not declared:
                    state = "缺" if host_side == "yes" else "异"
                elif host_side == "no":
                    state = "异"
                else:
                    state = "有" if reach > 0 else "部分"
            else:
                self_decl, self_reach = "-", "-"
                state = "无" if host_side == "yes" else "-"
            lines.append(
                f"{channel}\t{outputs.get(channel, '-')}\t{family}\t{host_side}\t{self_decl}\t{self_reach}\t{state}"
            )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 诊断表

def diagnostic_sets():
    with DIAG_TOML.open("rb") as handle:
        document = tomllib.load(handle)
    host_codes = {key for key in document if key != "labels"}
    registered = set(re.findall(r'"(E[0-9]-[0-9]{3})"', CODES_PINI.read_text(encoding="utf-8")))
    emitted = set()
    for path in sorted((ROOT / "bootstrap" / "packages").rglob("*.pini")):
        if path.name == "codes.pini" or "tests" in path.parts:
            continue
        emitted.update(re.findall(r'"(E[0-9]-[0-9]{3})"', path.read_text(encoding="utf-8")))
    return host_codes, registered, emitted


def diagnostics_table():
    """缺码必须带依据：参考件条款、仅宿主实现或待核。

    依据缺行即拒生成，让「差集为空」这条总判据的每一行都能回答「该不该补」。
    """
    host_codes, registered, emitted = diagnostic_sets()
    basis = ledger(DIAGNOSTIC_BASIS)
    lines = ["# 诊断表：宿主码全集（权威 TOML）对自举已发码。「缺」= 自举永不产出该码。",
             "# 登记列与宿主全集应当相等，不等说明码表生成物落后；已发列只数源码里的发码点。",
             "# 依据：参考件 §节号 / 仅宿主实现 / 待核（说明列写明缺哪一条款）；非缺项记 -。",
             "# 由 bootstrap/tools/parity.py 生成，勿手改；只许缩小。",
             "码\t宿主\t自举登记\t自举已发\t状态\t依据"]
    missing = []
    for code in sorted(host_codes | emitted):
        host_side = "1" if code in host_codes else "0"
        reg = "1" if code in registered else "0"
        sent = "1" if code in emitted else "0"
        if code not in host_codes:
            state = "自举多出"
        else:
            state = "一致" if sent == "1" else "缺"
        cell = "-"
        if state == "缺":
            entry = basis.get(code)
            if entry is None:
                missing.append(code)
            else:
                cell = entry[0]
        lines.append(f"{code}\t{host_side}\t{reg}\t{sent}\t{state}\t{cell}")
    if missing:
        fail(f"诊断依据表缺行：{', '.join(missing)}")
        sys.exit(2)
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 程序表

DIAG_LOCATED = re.compile(r":(\d+):(\d+): .*?\[(E[0-9]-[0-9]{3})\] ?(.*)")
DIAG_PLAIN = re.compile(r"\[(E[0-9]-[0-9]{3})\] ?(.*)")


def first_diagnostic(text):
    """取首条结构化诊断：码、行列、摘要。清单层的失败没有行列，故列可缺。

    路径前缀不进摘要，产物才可复现。
    """
    hit = DIAG_LOCATED.search(text)
    if hit:
        line, col, code, message = hit.groups()
        return code, line, col, message.strip()
    hit = DIAG_PLAIN.search(text)
    if hit:
        code, message = hit.groups()
        return code, "", "", message.strip()
    return "", "", "", ""


def attribute(leg, code):
    """按首条诊断的域段归因：E1/E2 语法，E3/E4/E5 语义，腿本身定性其余两种。"""
    if leg == "check":
        if code[:2] in ("E1", "E2"):
            return "语法"
        return "语义" if code else "待核"
    return "降载" if leg == "lower" else "发射"


# 归因按修复落点判：解析器不认的写法无论报在语法期还是语义期，都归缺语法构造。
SYMBOL_CODES = ("E3-001", "E3-002", "E3-003")

SITES = (
    ("无效的顶级声明", "缺语法构造", "顶级声明分派"),
    ("缺少参数名", "缺语法构造", "形参位：self / own"),
    ("实际得到?", "缺语法构造", "类型注解的前置 ?"),
    ("实际得到=", "缺语法构造", "元组元素的标签位"),
    ("未定义名字：outer", "缺语法构造", "标签控制流：标签位未进解析面"),
    ("未定义名字：Optional", "缺符号", "值位内建名：类型名作限定构造"),
    ("未定义名字：Error", "缺符号", "值位内建名：内建错误构造器"),
    ("未定义名字：joinAll", "缺符号", "值位内建名：并发自由函数"),
    ("未定义名字：joinWithin", "缺符号", "值位内建名：并发自由函数"),
    ("类型未声明：T", "缺符号", "类型参数注册"),
    ("未定义名字：句柄", "缺判定", "对象字段裸名"),
    ("跳出或继续", "缺判定", "控制流判定"),
    ("成员不存在", "缺判定", "成员查找"),
    ("实参类型不匹配", "缺判定", "函数类型可赋值性"),
    ("空返回带值", "缺判定", "跨文件签名装配"),
    ("缺少实参标签", "缺判定", "标签面：声明补 `_` 前缀"),
)


def attribute_kind(leg, code, summary):
    """三类归因按修复落点判，不按诊断码域段。

    夹具未就绪单列待核，不让它混进语言缺口。
    """
    if leg == "lower":
        return ("降载缺口", "-")
    if leg == "emit":
        return ("发射缺口", "-")
    if not code:
        return ("待核", "无结构化诊断")
    if code == "E3-011":
        return ("待核", "夹具未就绪：需先 build")
    for key, kind, site in SITES:
        if key in summary:
            return (kind, site)
    if code[:2] in ("E1", "E2"):
        return ("缺语法构造", "解析器")
    if code in SYMBOL_CODES:
        return ("缺符号", "符号注册面")
    return ("缺判定", "检查规则")


EXCEPTIONS = OUT / "attribution-exceptions.tsv"


def attribution_exceptions():
    """人工复核的归因例外：只记与规则推断不同的项，条目必须仍在失败集。"""
    table = {}
    if not EXCEPTIONS.is_file():
        return table
    for line in EXCEPTIONS.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) >= 3:
            table[cols[0]] = (cols[1], cols[2])
    return table


def first_gap(text):
    """取首条缺口：驱动以「缺口」开头逐条列出，取第一条作摘要。"""
    for line in text.splitlines():
        if line.startswith("缺口 "):
            return line[3:].strip()
    return ""


def lower_errors(text):
    """降载错误数：驱动打 `lower-ok 函数数 错误数 空体数 类型错数`，第二个数即错误数。"""
    for line in text.splitlines():
        if line.startswith("lower-ok "):
            cols = line.split()
            if len(cols) >= 3 and cols[2].isdigit():
                return int(cols[2])
    return 0


def programs_table():
    binary = bootstrap_binary()
    overrides = attribution_exceptions()
    entries = []
    for path in sorted(EXAMPLES.iterdir()):
        if path.name in ("golden", "README.md", "gate-baseline.tsv"):
            continue
        if path.is_file() and path.suffix == ".pini":
            entries.append((path.stem, path, "单文件"))
        elif path.is_dir() and (path / "pini.toml").is_file():
            entries.append((path.name, path, "目录"))
    lines = ["# 程序表：examples 逐个过 check / lower / emit。归因按首条诊断的域段，不按措辞。",
             "# 归因列按域段：E1/E2 语法、E3/E4/E5 语义、lower 腿降载、emit 腿发射；无码记待核。",
             "# 归因类列按修复落点：缺符号进注册面，缺判定进检查规则，缺语法构造进解析器。",
             "# 示例违规与夹具未就绪单列，不进三类；例外见 attribution-exceptions.tsv。",
             "# 入口即示例路径本身：单文件与目录都由编译器直接收，脚本不包工作区、不复制源码。",
             "# 由 bootstrap/tools/parity.py --full 生成，勿手改；只许缩小。",
             "程序\t形态\tcheck\tlower\temit\t归因\t归因类\t修复落点\t首条诊断\t摘要"]
    for name, path, shape in entries:
        root = str(path.relative_to(ROOT))
        if shape == "目录":
            # 目录夹具先预备生成模块：翻译归宿主工具，自举只按计划消费生成物。
            # 这里不判红——build 失败时后续 check 腿会报出缺哪个产物，归因指向真因。
            run([host_binary(), "build", root])
        legs = {}
        where = "-"
        summary = "-"
        reason = "通过"
        kind = ("通过", "-")
        for leg in ("check", "lower", "emit"):
            status, out, err = run([binary, leg, root])
            # 四条失败信号：退出码、驱动的 plan / check 失败行、降载错误数、发射缺口。
            failed = status != 0 or "workspace-check-failed" in out or "workspace-plan-failed" in out
            if leg == "lower" and lower_errors(out) > 0:
                failed = True
            if leg == "emit" and "emit-gaps" in out:
                failed = True
            legs[leg] = "fail" if failed else "ok"
            if failed:
                code, line, col, message = first_diagnostic(out + err)
                if leg == "lower" or leg == "emit":
                    message = first_gap(out) or message
                reason = attribute(leg, code)
                where = (f"{code}@{line}:{col}" if line else code) or "-"
                summary = message[:48] or "-"
                kind = attribute_kind(leg, code, summary)
                if name in overrides:
                    kind = overrides[name]
                break
        for leg in ("check", "lower", "emit"):
            legs.setdefault(leg, "-")
        lines.append(
            f"{name}\t{shape}\t{legs['check']}\t{legs['lower']}\t{legs['emit']}\t{reason}"
            f"\t{kind[0]}\t{kind[1]}\t{where}\t{summary}"
        )
    return "\n".join(lines) + "\n"


def failed_names_from_table(text):
    """从程序表取失败集：归因类不是「通过」的行。"""
    names = set()
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) >= 7 and cols[6] != "通过":
            names.add(cols[0])
    return names


def check_exceptions(failed):
    """例外表只许缩小：条目必须仍在失败集，某条转绿即红并提示删行。"""
    stale = sorted(name for name in attribution_exceptions() if name not in failed)
    if stale:
        fail(f"归因例外已失效：{', '.join(stale)}；删掉 attribution-exceptions.tsv 对应行")
        return False
    return True


# ---------------------------------------------------------------- 入口

def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--check", action="store_true", help="只校验盘上产物是否最新")
    parser.add_argument("--full", action="store_true", help="校验时连程序表一起重取")
    args = parser.parse_args()

    commands, host, mine = commands_table()
    channels = channels_table()
    diagnostics = diagnostics_table()
    produced = {
        "commands.tsv": commands,
        "channels.tsv": channels,
        "diagnostics.tsv": diagnostics,
    }
    if args.full or not args.check:
        produced["programs.tsv"] = programs_table()

    if args.check:
        stale = []
        for name, text in produced.items():
            path = OUT / name
            if not path.is_file() or path.read_text(encoding="utf-8") != text:
                stale.append(name)
        if stale:
            fail(f"表已过期：{', '.join(stale)}；重跑 python3 bootstrap/tools/parity.py")
            return 1
        table = OUT / "programs.tsv"
        failed = failed_names_from_table(table.read_text(encoding="utf-8")) if table.is_file() else set()
        if not check_exceptions(failed):
            return 1
        print(f"差异普查通过：{len(produced)} 张表与盘上一致")
        return 0

    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in produced.items():
        (OUT / name).write_text(text, encoding="utf-8")

    counts = {}
    for name, text in produced.items():
        body = [line for line in text.splitlines() if not line.startswith("#")]
        rows = max(len(body) - 1, 0)
        counts[name] = rows
    print("差异普查已重取：" + "，".join(f"{name} {rows} 行" for name, rows in counts.items()))
    print(f"宿主命令 {len(host)} 条，自举命令 {len(mine)} 条")
    return 0


if __name__ == "__main__":
    sys.exit(main())
