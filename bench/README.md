# Pini 性能基准（bench/）

测量 **解释器前端**（`pini run`）与 **LLVM 编译器后端**（`lli` JIT / `clang` AOT）之间的执行速度差距。

## 文件

| 文件 | 说明 |
|------|------|
| `bench_fib.pini` | 递归斐波那契 `fib(30)` —— 函数调用密集 |
| `bench_loop.pini` | `while` 循环累加 500 万次 —— 循环 + 算术，无函数调用 |
| `bench_primes.pini` | 试除法统计 10 万以内质数 —— 嵌套循环 + 取模 + 分支 |
| `run_benchmarks.py` | 自动化测量脚本（Python 标准库，无第三方依赖） |

三个 benchmark 均用**英文标识符**（LLVM IR 后端不支持非 ASCII 标识符），且统一结构为
`compute|func() -> (I32,)` + 单次 `main`，便于脚本自动生成「内部重复 R 次」的变体来摊薄启动开销。

## 用法

```bash
# 先构建（本机需 --disable-sandbox）
cd Pini && swift build --disable-sandbox

# 运行基准（默认每个命令重复 3 次取中位数）
python3 bench/run_benchmarks.py

# 自定义重复次数
REPEAT=5 python3 bench/run_benchmarks.py
```

前置条件：`clang` / `lli` 在 PATH（或设置 `PINI_LLVM_BIN`）。缺失时脚本自动跳过对应后端。

## 方法学（为什么不能只看 `time`）

机器码执行一次 fib(30) 仅 **几毫秒**，会被以下固定开销完全淹没：

- 进程启动 + `printf`/libc 加载 ≈ **0.35~0.4 s**（实测 `print(0)` 空程序也要这么久）；
- `lli` JIT 编译 ≈ 0.15~0.3 s；
- `clang` 编译 ≈ 0.6~2 s。

因此脚本分**两个维度**测量，避免把「编译/JIT 启动成本」误当成「执行速度」：

1. **端到端墙钟** —— 直接计时三个真实命令 `run` / `run-llvm` / `compile`，
   反映用户实际体验（短程序被启动开销主导，长程序被真实执行主导）。
2. **纯执行 CPU 时间** —— 对机器码端生成「内部循环 R 次调用 `compute()`」的变体，
   用 CPU 时间（user+sys）除以 R 得单次纯执行时间；解释器端因计算密集、几乎无 IO，
   wall-clock ≈ CPU 时间，直接取 `run` 中位数。

## 已知口径

- 解释器端到端含词法/语法解析，但解析开销约几毫秒，相对 15~26s 的执行时间可忽略。
- `AOT -O2` 常因常量折叠 / 死代码消除把纯函数结果直接预计算（单次≈0），
  这是编译器后端相对解释器的**额外优化红利**，不代表 `-O0` 下的基础差距。
- `lli` 默认 JIT 代码生成质量可能高于 `clang -O0`，故 JIT 单次耗时偶见低于 AOT `-O0`。
