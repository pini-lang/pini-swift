# ADR-022: 分发策略——源码分发、用户自行构建

## Status

Accepted（2026-08-29，用户裁决）

## Context

pini-swift 仅有 `v0.48.4` 一个 tag，其后 31 个提交未发版；无预编译产物、无安装脚本；`pini version` 硬编码 `0.48.4` 且落后于代码状态；宿主仓自身缺失 CHANGELOG.md（仅有 `.pini/toolchain/` vendored 副本）。用户裁决：项目未进入稳定阶段，**当前仅分发 macOS、以源码分发为主、用户自行构建**，因此转向编写构建指南而非二进制发布流水线。

## Decision

1. **源码分发、用户自行构建**：交付物 = 构建指南（`docs/BUILDING.md`），覆盖工具链要求（Swift 6.2+）、debug/release 双构建、冒烟验证、PATH/安装（含 `libPiniRuntime.dylib` 同级目录规则与 `PINI_RUNTIME_LIB`/`PINI_LLVM_BIN`）、子命令速览、自举演示、故障排查。
2. **平台范围：仅 macOS**。Linux（Swift static SDK 静态路线）与 Windows 在项目稳定后评估；WASM 记录不排期。
3. **零签名**：本地构建产物不带 Gatekeeper 隔离标记，无签名/公证需求；签名议题仅在未来「挂网分发预编译二进制」时重启（届时选项：ad-hoc + `xattr` 文档 / Developer ID 公证）。
4. **LLVM 后端随宿主仅 macOS**：解释器功能是自举刚需与跨平台主体，LLVM 依赖（clang/lli + dylib）是跨平台复杂度的主要来源——Linux 首版只考虑解释器子集。
5. **自举可移植性跟随宿主**：pini/ 自举链完全运行在宿主解释器上，宿主可移植性决定自举可移植性。

## Consequences

**变容易**：无发布流水线/签名/公证负担；构建指南即分发文档；`libPiniRuntime` 同级目录规则天然支持绿色使用。

**挂账**：① 版本锚定——`pini version` 硬编码 `0.48.4` 落后 31+ 提交，需单一来源常量 + 重建宿主仓缺失的 `docs/CHANGELOG.md`（建议值 `0.49.0`，待用户确认）；② Homebrew tap / 预编译二进制推迟至稳定阶段；③ 构建指南需随工具链版本演进维护（当前锚定 Swift 6.2 / Apple Swift 6.3.3 实测）。
