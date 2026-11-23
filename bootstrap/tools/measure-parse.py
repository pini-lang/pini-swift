#!/usr/bin/env python3
"""解析吞吐测量：生成临时测量模块，按截断阶梯跑原生通道，扣底噪并拟合指数。

只做进程调用与读数汇总，不含编译逻辑；被测代码是 bootstrap 的 syntax 包本身。
阶梯取 parser.pini 的八分之一、四分之一、二分之一与整份，另有两档只走词法，末尾两档覆盖全工作区。
"""

import argparse
import math
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / ".build" / "release" / "pini"
SYNTAX = ROOT / "bootstrap" / "packages" / "syntax"
PACKAGES = ROOT / "bootstrap" / "packages"

# 每档：(名字, 相对 syntax 的源文件, 分母, 模式, 重复次数)；全工作区档的源文件为 None。
RUNGS = [
    ("底噪", "src/api/parser.pini", 2, "prep", 3),
    ("八分之一", "src/api/parser.pini", 8, "parse", 3),
    ("四分之一", "src/api/parser.pini", 4, "parse", 2),
    ("二分之一", "src/api/parser.pini", 2, "parse", 1),
    ("全文件", "src/api/parser.pini", 1, "parse", 1),
    ("扫半", "src/_internal/scan.pini", 2, "parse", 2),
    ("词四分之一", "src/api/parser.pini", 4, "lex", 2),
    ("词二分之一", "src/api/parser.pini", 2, "lex", 1),
    ("全工作区只读", None, 1, "read", 1),
    ("全工作区", None, 1, "parse", 1),
]

MODULE_TOML = """[package]
name = "measure"

[lib]
name = "measure"
entry = "src/api/probe.pini"

[[test]]
name = "measure-tests"
entry = "tests"
"""

PROBE = """; 探测：确认测量模块可加载。
probeReady|func() -> (Bool,):
    return true
"""

# 取段：切行后切片再拼接；逐行累加会自己引入二次方，不能用。
# 每条尺子单列一个用例，靠 --filter 选择，保证编译与启动成本在各档之间相同。
HARNESS = """[throughput_test|import]
_syntax = "{syntax}"

; 取前 1/divisor 行：切行后切片再拼接，避免逐行累加带来的二次方准备开销。
取段|func(_path: String, _divisor: I32,) -> (String,):
    let lines = readFile(_path).split("\\n")
    let keep = len(lines) / _divisor
    return lines.slice(start = 0, end = keep).join("\\n")

; 底噪：只做准备不解析，用来扣掉读文件与切行拼接的开销。
尺底噪|test() -> ():
    let text = 取段("{parser}", 2)
    assert(len(text) > 0, "有内容")
    return

; 全文件行数的八分之一。
尺八|test() -> ():
    let text = 取段("{parser}", 8)
    let result = parseText(text)
    assert(result.ast.itemCount() > 0, "有顶层声明")
    return

; 全文件行数的四分之一。
尺四|test() -> ():
    let text = 取段("{parser}", 4)
    let result = parseText(text)
    assert(result.ast.itemCount() > 0, "有顶层声明")
    return

; 全文件行数的二分之一。
尺半|test() -> ():
    let text = 取段("{parser}", 2)
    let result = parseText(text)
    assert(result.ast.itemCount() > 0, "有顶层声明")
    return

; 整份文件：阶梯的最高档，用来核对外推。
尺全|test() -> ():
    let text = 取段("{parser}", 1)
    let result = parseText(text)
    assert(result.ast.itemCount() > 0, "有顶层声明")
    return

; 跨文件对照：scan.pini 的前一半。
尺扫半|test() -> ():
    let text = 取段("{scan}", 2)
    let result = parseText(text)
    assert(result.ast.itemCount() > 0, "有顶层声明")
    return

; 只走词法：四分之一与二分之一两档，用来把词法代价从整链里切开。
尺词四|test() -> ():
    let text = 取段("{parser}", 4)
    let result = lexText(text)
    assert(result.tokenCount() > 0, "有记号")
    return

; 只走词法：二分之一档。
尺词半|test() -> ():
    let text = 取段("{parser}", 2)
    let result = lexText(text)
    assert(result.tokenCount() > 0, "有记号")
    return

; 全工作区：逐文件装载并解析，声明总数用来确认真的解析过。
尺整解|test() -> ():
    let 文件: Array<String> = [{ws_list}]
    var i = 0
    var 声明数 = 0
    while i < len(文件):
        let result = parseText(readFile(文件[i]))
        声明数 = 声明数 + result.ast.itemCount()
        i = i + 1
    assert(声明数 > 0, "有声明")
    return

; 全工作区只读：同一批文件只装载不解析，作为 I/O 底数。
尺整读|test() -> ():
    let 文件: Array<String> = [{ws_list}]
    var i = 0
    var 总长 = 0
    while i < len(文件):
        总长 = 总长 + len(readFile(文件[i]))
        i = i + 1
    assert(总长 > 0, "有内容")
    return
"""

# 档名到用例名的映射；`--filter` 是子串匹配而非整名匹配，
# 故各用例名之间不得互为前缀，否则一次会命中多条、读数含义随之漂移。
CASE = {
    "底噪": "尺底噪",
    "八分之一": "尺八",
    "四分之一": "尺四",
    "二分之一": "尺半",
    "全文件": "尺全",
    "扫半": "尺扫半",
    "词四分之一": "尺词四",
    "词二分之一": "尺词半",
    "全工作区": "尺整解",
    "全工作区只读": "尺整读",
}


def workspace_files():
    return sorted(PACKAGES.rglob("*.pini"))


def build_module(workdir: Path) -> None:
    (workdir / "src" / "api").mkdir(parents=True, exist_ok=True)
    (workdir / "tests").mkdir(parents=True, exist_ok=True)
    (workdir / "pini.toml").write_text(MODULE_TOML, encoding="utf-8")
    (workdir / "src" / "api" / "probe.pini").write_text(PROBE, encoding="utf-8")
    ws_list = ", ".join(f'"{p.as_posix()}"' for p in workspace_files())
    harness = HARNESS.format(
        syntax=SYNTAX.as_posix(),
        parser=(SYNTAX / "src" / "api" / "parser.pini").as_posix(),
        scan=(SYNTAX / "src" / "_internal" / "scan.pini").as_posix(),
        ws_list=ws_list,
    )
    (workdir / "tests" / "throughput_test.pini").write_text(harness, encoding="utf-8")


# 结果行形如「结果: 7 通过, 0 失败」；通过项数是判据，退出码靠不住。
RESULT_LINE = re.compile(r"结果:\s*(\d+)\s*通过,\s*(\d+)\s*失败")


def run_once(module: Path, case: str, expect: int = 1) -> float:
    """跑一条用例，返回墙钟秒数。

    成功判据取结果行的通过项数，不取退出码：筛选未命中时退出码仍为 0，
    只看退出码会把空跑当成读数。通过项数须等于登记值，失败项数须为零。
    """
    start = time.monotonic()
    proc = subprocess.run(
        [str(BIN), "test-llvm", str(module), "--filter", case],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    elapsed = time.monotonic() - start
    match = RESULT_LINE.search(proc.stdout)
    if match is None:
        print(proc.stdout, file=sys.stderr)
        raise SystemExit(f"用例 {case}: 输出无结果行，读数作废")
    passed, failed = int(match.group(1)), int(match.group(2))
    if failed != 0 or passed != expect:
        print(proc.stdout, file=sys.stderr)
        raise SystemExit(
            f"用例 {case}: 期望 {expect} 项通过、0 失败，"
            f"实得 {passed} 项通过、{failed} 项失败，读数作废"
        )
    return elapsed


def line_count(path: Path, divisor: int) -> int:
    return len(path.read_text(encoding="utf-8").split("\n")) // divisor


def fit_exponent(points):
    """最小二乘拟合 log(耗时) 对 log(行数) 的斜率，即增长指数。"""
    xs = [math.log(n) for n, _ in points]
    ys = [math.log(t) for _, t in points]
    mx = sum(xs) / len(xs)
    my = sum(ys) / len(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den = sum((x - mx) ** 2 for x in xs)
    return num / den


def workspace_totals():
    """全工作区的文件数、行数与字节数。"""
    files = workspace_files()
    lines = 0
    size = 0
    for path in files:
        text = path.read_text(encoding="utf-8")
        lines += len(text.split("\n"))
        size += len(text.encode("utf-8"))
    return len(files), lines, size


def measure_of(name: str, rel, divisor: int) -> int:
    """档位对应的行数：全工作区档取全量行数。"""
    if rel is None:
        return workspace_totals()[1]
    return line_count(SYNTAX / rel, divisor)


def main() -> int:
    parser = argparse.ArgumentParser(description="解析吞吐测量（原生通道，截断阶梯）")
    parser.add_argument("--reps", type=int, default=0, help="统一覆盖每档重复次数")
    parser.add_argument("--only", nargs="*", default=[], help="只跑指定档（底噪总是跑）")
    args = parser.parse_args()

    if not BIN.exists():
        print(f"缺少可执行文件 {BIN}；先 swift build -c release --disable-sandbox", file=sys.stderr)
        return 1

    wanted = [name for name in args.only if name != "底噪"] or None
    selected = [r for r in RUNGS if r[0] == "底噪" or wanted is None or r[0] in wanted]

    raw = {}
    with tempfile.TemporaryDirectory(prefix="pini-measure.") as tmp:
        module = Path(tmp)
        build_module(module)
        for name, rel, divisor, mode, reps in selected:
            runs = [run_once(module, CASE[name]) for _ in range(args.reps or reps)]
            raw[name] = (statistics.median(runs), runs, measure_of(name, rel, divisor))

    noise = raw["底噪"][0]
    print(f"底噪（准备 + 编译 + 启动）：{noise:.2f}s")
    print()
    print("| 档 | 模式 | 行数 | 墙钟中位数 | 扣底噪 | 单行耗时 | 读数 |")
    print("|---|---|---|---|---|---|---|")
    for name, rel, divisor, mode, reps in selected:
        if mode == "prep":
            continue
        med, runs, lines = raw[name]
        net = med - noise
        shown = " / ".join(f"{r:.2f}" for r in runs)
        print(f"| {name} | {mode} | {lines} | {med:.2f}s | {net:.2f}s | {net / lines * 1000:.1f}ms | {shown} |")

    ladder = [(raw[n][2], raw[n][0] - noise) for n in ("八分之一", "四分之一", "二分之一") if n in raw]
    if len(ladder) >= 2:
        print()
        print(f"解析增长指数（log-log 斜率）：{fit_exponent(ladder):.2f}（1 为线性，2 为二次方）")
    if len(ladder) == 3:
        print(
            f"相邻档倍率：{ladder[1][1] / ladder[0][1]:.2f}x / {ladder[2][1] / ladder[1][1]:.2f}x"
            "（输入每次翻倍；判据上限 2.4x）"
        )

    lex_ladder = [(raw[n][2], raw[n][0] - noise) for n in ("词四分之一", "词二分之一") if n in raw]
    if len(lex_ladder) >= 2:
        print(f"词法增长指数：{fit_exponent(lex_ladder):.2f}")
    if ladder and lex_ladder:
        half_parse = raw["二分之一"][0] - noise
        half_lex = raw["词二分之一"][0] - noise
        print(f"二分之一档：词法 {half_lex:.2f}s，整链 {half_parse:.2f}s，词法占比 {half_lex / half_parse * 100:.0f}%")

    if "全工作区" in raw:
        files, lines, size = workspace_totals()
        net = raw["全工作区"][0] - noise
        io = raw["全工作区只读"][0] - noise if "全工作区只读" in raw else 0.0
        吞吐 = size / 1024 / 1024 / net if net > 0 else 0.0
        print()
        print(f"全工作区：{files} 个文件、{lines} 行、{size / 1024 / 1024:.2f} MB")
        print(f"装载加解析净耗时：{net:.2f}s（只读 {io:.2f}s，纯解析 {net - io:.2f}s），吞吐 {吞吐:.2f} MB/s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
