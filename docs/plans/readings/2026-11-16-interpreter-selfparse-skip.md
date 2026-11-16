# 解释器自解析跳过的读数

本件是交付证据，不是筹划载体：决策、判据与恢复条件写在 `docs/plans/2026-11-12-self-hosting-plan.md` 的 **解释器自解析搁置** 一节，这里只存那次取舍用到的原始读数。

注意 读数易腐。它们绑定当次的机器、工具链、构型与测试集规模；测试项会增删，实现会变快变慢，任一项变动都让下列数字失去可比性。引用本件时只可作「当时差多少」的依据，不可当作性能基线或验收判据。

## 环境

| 项 | 值 |
|---|---|
| 机器 | macOS 27.2.1，arm64 |
| Swift | Apple Swift 6.4.2（swiftlang-6.4.2.1.9） |
| clang | Homebrew clang 23.1.5 |
| 构型 | debug（`.build/debug/pini`，未加优化） |
| 测试集 | 自举工作区 9 个包，543 条测试函数 |

## 命令与读数

每次测量单跑，前台独占，不与其他构建并行。

| 命令 | 项数 | 墙钟 |
|---|---|---|
| `pini test bootstrap` | 543 | 156.34 秒 |
| `pini test bootstrap --filter 自解析` | 1 | 68.74 秒 |
| `pini test bootstrap --filter 缺清单报错` | 1 | 9.41 秒 |
| `pini test bootstrap --skip 自解析` | 542 | 94.81 秒 |
| `pini test-llvm bootstrap/packages/syntax --filter 自解析` | 1 | 5.17 秒 |
| `pini test-llvm bootstrap/packages/syntax` | 91 | 5.54 秒 |
| `pini test-llvm bootstrap/packages/syntax --skip 自解析` | 90 | 4.69 秒 |

## 怎么读这几行

- 工作区装配底噪取「一条轻用例」那一行：`--filter` 只命中一条时，装载九包清单与降载仍会发生，9.41 秒里绝大部分是它。故 `自解析` 的净耗时约为 68.74 − 9.41 ≈ 59 秒，占全量 156.34 秒的近四成。
- 原生那一行含发射与链接：运行本体 0.47 秒，其余四秒七是 clang 与落盘。比较两条通道时不能用 68.74 对 0.47，那比的是两个不同阶段。
- 跳过之后省 61.5 秒（156.34 → 94.81），与单条 68.74 秒扣除重复计入的装配底噪大致吻合。
- `syntax` 全包 91 条走原生只要 5.54 秒：同一份判据在原生上既更快，又额外验证了发射与运行。

## 复现

```sh
swift build --disable-sandbox
/usr/bin/time -p .build/debug/pini test bootstrap
/usr/bin/time -p .build/debug/pini test bootstrap --skip 自解析
/usr/bin/time -p .build/debug/pini test-llvm bootstrap/packages/syntax
```

注意 重跑前先确认测试集规模未变：条数一变，上面所有数字都不再可比，须整组重取，不要拿旧数字补新差。
