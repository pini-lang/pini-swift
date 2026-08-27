#!/usr/bin/env python3
"""Pini 解释器 vs LLVM 编译器后端 — 执行速度基准。

用法：
    python3 run_benchmarks.py            # 默认 3 次取中位数
    REPEAT=5 python3 run_benchmarks.py

输出两部分数据：
  A. 端到端墙钟（真实用户命令耗时）：
       run（解释器） / run-llvm（LLVM JIT） / compile（LLVM AOT）
  B. 纯执行 CPU 时间（剥离解析/编译/JIT/进程启动开销）：
       解释器单次 vs 机器码单次（进程内重复 R 次摊薄启动开销后取平均）

方法学要点：
  * 机器码单次执行仅 ~几毫秒，被进程启动（~0.4s）与 JIT/编译（~0.2s~2s）完全淹没。
    因此对机器码端生成「内部循环 R 次调用 compute()」的变体程序，用 CPU 时间（user+sys）
    除以 R 得到单次纯执行时间，避免 wall-clock 被启动开销污染。
  * 解释器端 CPU 时间 ≈ 墙钟时间（计算密集，几乎无 IO），故直接用 `run` 的 CPU 时间。
"""

import os
import subprocess
import sys
import tempfile
import time
import statistics
import resource

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PINI = os.environ.get("PINI_BIN", os.path.join(REPO, ".build", "debug", "pini"))
REPEAT = int(os.environ.get("REPEAT", "3"))
BENCH_DIR = os.path.dirname(os.path.abspath(__file__))

# benchmark：名称 / 文件名 / 单次期望输出 / 机器码重复次数 R（让机器码重复版 CPU 时间 > 0.5s）
BENCHMARKS = [
    ("fib(30) 递归",      "bench_fib.pini",    "832040",  200),
    ("loop 500万累加",     "bench_loop.pini",   "5000000", 100),
    ("primes(10万) 质数",  "bench_primes.pini", "9592",     50),
]

SINGLE_MAIN = "main|func() -> ()\n    print(compute())\n    return"


def repeat_main(r):
    return ("main|func() -> ()\n"
            "    var total = 0\n"
            "    var k = 0\n"
            f"    while k < {r}:\n"
            "        total = total + compute()\n"
            "        k = k + 1\n"
            "    print(total)\n"
            "    return")


def which(tool):
    p = subprocess.run(["which", tool], capture_output=True, text=True)
    return p.stdout.strip() or None


def run_wall(cmd, repeat=REPEAT):
    """wall-clock 计时，repeat 次，返回 (耗时列表, 最后输出)。"""
    times, out = [], ""
    for _ in range(repeat):
        t0 = time.perf_counter()
        r = subprocess.run(cmd, capture_output=True, text=True)
        times.append(time.perf_counter() - t0)
        out = (r.stdout or "").strip()
    return times, out


def run_cpu(cmd):
    """单次运行的 CPU 时间（user+sys，秒），返回 (cpu, 输出)。"""
    b = resource.getrusage(resource.RUSAGE_CHILDREN)
    r = subprocess.run(cmd, capture_output=True, text=True)
    a = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (a.ru_utime - b.ru_utime) + (a.ru_stime - b.ru_stime)
    return cpu, (r.stdout or "").strip()


def fmt_wall(times):
    return f"{statistics.median(times):.3f}" if times else "n/a"


def fmt_cpu(x):
    if x is None:
        return "n/a"
    return f"{x * 1000:.2f} ms" if x < 1.0 else f"{x:.3f} s"


def main():
    lli = which("lli")
    clang = which("clang")
    if not os.path.exists(PINI):
        print(f"[错误] 未找到 pini：{PINI}\n先 swift build 或用 PINI_BIN 指定。", file=sys.stderr)
        sys.exit(1)

    print("=" * 84)
    print("Pini 解释器 vs LLVM 编译器后端 — 执行速度基准")
    print(f"pini : {PINI}")
    print(f"lli     : {lli or '(缺失)'}")
    print(f"clang   : {clang or '(缺失)'}")
    print(f"端到端重复: {REPEAT} 次（wall-clock 取中位数）")
    print("=" * 84)

    end_to_end = []   # (label, interp_wall, jit_wall, aot_wall)
    pure = []         # (label, interp_cpu, lli_cpu, aot0_cpu, aot2_cpu)

    for label, filename, expected, R in BENCHMARKS:
        src = os.path.join(BENCH_DIR, filename)
        print(f"\n### {label}  ({filename}, 单次期望输出 {expected})")

        # ---- A. 端到端墙钟 ----
        itimes, iout = run_wall([PINI, "run", src])
        print(f"  [端到端] run(解释器)  : {fmt_wall(itimes)} s   输出={iout!r}")

        jtimes, ctimes = [], []
        jout = cout = ""
        if lli:
            jtimes, jout = run_wall([PINI, "run-llvm", src])
            print(f"  [端到端] run-llvm(JIT): {fmt_wall(jtimes)} s   输出={jout!r}")
        if clang:
            ctimes, cout = run_wall([PINI, "compile", src])
            print(f"  [端到端] compile(AOT) : {fmt_wall(ctimes)} s   输出={cout!r}")

        # ---- B. 纯执行 CPU 时间 ----
        # 解释器计算密集、几乎无 IO，wall-clock ≈ CPU 时间，直接复用端到端中位数，
        # 避免再跑一遍解释器（fib(30) 单次约 25s，重复测量代价高）。
        icpu = statistics.median(itimes)
        print(f"  [纯执行] 解释器单次    : {fmt_cpu(icpu)} (wall≈CPU)")

        jcpu = a0cpu = a2cpu = None
        with open(src) as f:
            code = f.read()
        assert SINGLE_MAIN in code, f"{filename} 缺少统一的 single main 模板"
        rep_code = code.replace(SINGLE_MAIN, repeat_main(R))
        rep_expected = str(int(expected) * R)

        with tempfile.TemporaryDirectory() as td:
            rep_file = os.path.join(td, "rep.pini")
            ir = os.path.join(td, "rep.ll")
            with open(rep_file, "w") as f:
                f.write(rep_code)

            e = subprocess.run([PINI, "emit", rep_file, ir], capture_output=True, text=True)
            if e.returncode != 0:
                print(f"  [错误] 重复版 IR 生成失败：{e.stderr.strip()[:120]}")
                continue

            if lli:
                cpu, out = run_cpu([lli, ir])
                if out == rep_expected:
                    jcpu = cpu / R
                    print(f"  [纯执行] lli JIT 单次  : {fmt_cpu(jcpu)} (CPU) [共 {R} 次]")
                else:
                    print(f"  [警告] lli 重复版输出 {out!r} != 期望 {rep_expected!r}")

            if clang:
                for opt, key in [("-O0", "a0"), ("-O2", "a2")]:
                    binp = os.path.join(td, f"rep_{key}")
                    c = subprocess.run([clang, opt, "-o", binp, ir], capture_output=True, text=True)
                    if c.returncode != 0:
                        print(f"  [纯执行] AOT {opt} 编译失败：{c.stderr.strip()[:80]}")
                        continue
                    cpu, out = run_cpu([binp])
                    if out == rep_expected:
                        if key == "a0":
                            a0cpu = cpu / R
                        else:
                            a2cpu = cpu / R
                        tag = "✓"
                    else:
                        tag = f"✗(输出{out!r})"
                    print(f"  [纯执行] AOT {opt} 单次  : {fmt_cpu(cpu / R)} (CPU) [共 {R} 次] {tag}")

        end_to_end.append((label, itimes, jtimes, ctimes))
        pure.append((label, icpu, jcpu, a0cpu, a2cpu))

    # ---- 汇总 A：端到端墙钟 ----
    print("\n" + "=" * 84)
    print("A. 端到端墙钟（真实命令耗时，秒，中位数）")
    print("=" * 84)
    print(f"{'benchmark':<20} | {'run 解释器':>12} | {'run-llvm JIT':>13} | {'compile AOT':>12}")
    print("-" * 70)
    for label, it, jt, ct in end_to_end:
        i = statistics.median(it) if it else float("nan")
        j = statistics.median(jt) if jt else float("nan")
        c = statistics.median(ct) if ct else float("nan")
        print(f"{label:<20} | {i:>12.3f} | {j:>13.3f} | {c:>12.3f}")

    # ---- 汇总 B：纯执行加速比 ----
    print("\n" + "=" * 84)
    print("B. 纯执行 CPU 时间（单次计算，剥离启动/编译开销）")
    print("=" * 84)
    print(f"{'benchmark':<20} | {'解释器':>12} | {'lli JIT':>12} | {'AOT -O0':>12} | {'AOT -O2':>12} | {'加速比':>10}")
    print("-" * 90)
    for label, icpu, jcpu, a0cpu, a2cpu in pure:
        spd = ""
        if icpu and a0cpu and a0cpu > 0:
            spd = f"{icpu / a0cpu:,.0f}x"
        elif icpu and a0cpu == 0:
            spd = "∞(被优化)"
        print(f"{label:<20} | {fmt_cpu(icpu):>12} | {fmt_cpu(jcpu):>12} | {fmt_cpu(a0cpu):>12} | {fmt_cpu(a2cpu):>12} | {spd:>10}")

    print("\n说明：")
    print("  - 加速比 = 解释器单次 CPU / AOT -O0 单次 CPU。")
    print("  - AOT -O2 常因常量折叠/死代码消除把纯函数结果直接算好（单次≈0），")
    print("    体现编译器后端相对解释器还有额外的优化红利。")
    print("=" * 84)


if __name__ == "__main__":
    main()
