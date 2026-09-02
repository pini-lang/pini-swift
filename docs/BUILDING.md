# 构建指南（BUILDING）

> 本指南面向**从源码构建 Pini 宿主实现（pini-swift）**的用户。分发策略为**源码分发、用户自行构建**（决议 2026-08-29，ADR-022）：项目当前仅支持 macOS，不提供预编译二进制。

## 1. 系统要求

| 依赖 | 版本要求 | 用途 |
|------|---------|------|
| macOS | 26.x（随 Swift 6.2+ 工具链） | 必需 |
| Swift 工具链 | **6.2+**（`swift-tools-version:6.2`；本机验证：Apple Swift 6.3.3） | 必需，随 Xcode 或 swift.org 安装 |
| Git | 任意近期版本 | 获取源码 |
| clang / lli（LLVM） | 系统自带或 brew 安装 | **可选**——仅 `compile` / `run-llvm` / `emit` 后端需要 |

注意：纯解释器功能（`run` / `check` / `test` / `repl` / `lsp` / `debug` / `dap`）**不依赖 LLVM**，无 LLVM 环境可完整使用。

## 2. 获取源码

```bash
git clone <仓库地址> pini-swift
cd pini-swift
```

## 3. 构建

```bash
# 开发构建（快，未优化，适合改代码自测；约 1-2 分钟，增量秒级）
swift build --disable-sandbox

# 发布构建（推荐日常使用；O 优化，约 3-8 分钟）
# 内存提示：峰值可达数 GB——构建期间建议关闭其他重负载任务，
# 并保持单实例构建（并行两个 swift build 会导致内存换页，2026-08-29 实测教训）
swift build -c release --disable-sandbox
```

产物位于 `.build/<debug|release>/`：

| 产物 | 说明 |
|------|------|
| `pini` | CLI 可执行文件（本指南的主角） |
| `libPiniRuntime.dylib` | 集合运行时动态库——**仅 LLVM 后端**（`compile`/`run-llvm`）需要；与 `pini` 同目录自动被定位 |

`--disable-sandbox` 是本项目惯例（沙箱会阻断构建期文件访问；具体原因见仓库历史）。

## 4. 冒烟验证

```bash
# debug 构建冒烟
.build/debug/pini version        # 输出版本号
.build/debug/pini run examples/hello.pini
# 预期输出：Hello, World! / 欢迎使用Pini语言

.build/debug/pini check examples/array-basic.pini
.build/debug/pini test .         # 全量 |test 块（当前 10/10）

# release 构建冒烟（把 debug 换成 release）
.build/release/pini run examples/hello.pini
```

## 5. 使用与安装（可选）

### 直接使用

构建产物无需安装即可使用——`.build/release/pini` 就是完整 CLI。每次输入全路径即可：

```bash
.build/release/pini run 你的程序.pini
```

### 加入 PATH（两种方式）

**方式 A：直接把构建目录加入 PATH**（升级 = 重新 build，最省心）

```bash
export PATH="$PATH:$(pwd)/.build/release"   # 建议写进 shell 配置
```

**方式 B：拷贝到固定目录**（注意：`libPiniRuntime.dylib` 必须与 `pini` **同目录**——CLI 按可执行文件同级定位它；仅用解释器功能时不拷贝也可）

```bash
mkdir -p ~/.local/bin
cp .build/release/pini .build/release/libPiniRuntime.dylib ~/.local/bin/
export PATH="$PATH:$HOME/.local/bin"
```

### 环境变量

| 变量 | 作用 | 默认 |
|------|------|------|
| `PINI_RUNTIME_LIB` | 显式指定 `libPiniRuntime.{dylib,so}` 路径 | 可执行文件同级目录 |
| `PINI_LLVM_BIN` | LLVM 工具（clang/lli）所在目录 | 系统 `PATH` |

## 6. 子命令速览

| 命令 | 用途 |
|------|------|
| `pini run <file\|module>` | 运行程序（单文件或含 `pini.toml` 的模块目录） |
| `pini check <file\|module>` | 类型检查（`build` 为别名） |
| `pini test [path]` | 收集并运行 `\|test` 块 |
| `pini tokens <file>` / `pini parse <file>` | 词法 / 语法分析输出（差分测试用） |
| `pini emit <file>` | 生成 LLVM IR（需 LLVM） |
| `pini compile <file>` / `pini run-llvm <file>` | 经 LLVM 编译运行 / JIT 运行（需 LLVM） |
| `pini lsp` / `pini repl` | 语言服务器 / 交互式解释器 |
| `pini debug <file>` / `pini dap <file>` | 源码级调试器 / DAP 适配器 |
| `pini version` / `pini help` | 版本 / 帮助 |

## 7. 自举演示（进阶）

宿主实现就绪后，可以体验 **Pini 语言自己实现的编译器**（自举，ADR-018）：

```bash
# 上级目录需同时存在 pini/（自举源码）仓库
.build/release/pini run ../pini        # 运行自举词法器（对拍驱动入口）
.build/release/pini test ../pini       # 自举端 |test 块（10/10）
```

自举词法器与宿主 `pini tokens` 的输出逐字节一致（`pini/tools/diff_tokens.sh` 差分门禁，含中文标识符语料）。

## 8. 故障排查

| 症状 | 原因与处理 |
|------|-----------|
| `swift build` 报 swift-tools-version 不支持 | Swift 工具链 < 6.2：升级 Xcode 或从 swift.org 安装最新工具链 |
| 构建中系统卡顿 / 换页 | release 构建峰值内存数 GB：关闭其他重负载；**不要并行第二个构建** |
| `compile`/`run-llvm` 报找不到 clang/lli | 安装 LLVM（`brew install llvm`）或设 `PINI_LLVM_BIN` 指向其 bin 目录；解释器功能不受影响 |
| LLVM 程序运行时报找不到运行时库 | `libPiniRuntime.dylib` 不在 `pini` 同级：设 `PINI_RUNTIME_LIB` 指向该 dylib |
| 下载的二进制被 Gatekeeper 拦截 | 本指南走源码构建路径，不产生此问题；下载他人构建产物时 `xattr -d com.apple.quarantine <file>` |

## 9. 分发策略（背景）

本项目当前**仅分发源码、用户自行构建**（决议 2026-08-29，ADR-022）：

- 仅支持 macOS；不提供预编译二进制——本地构建的产物不带 Gatekeeper 隔离标记，**无需签名/公证**；
- Linux（Swift static SDK 静态链接路线）与 Windows 在项目稳定后评估；
- 版本锚定与 CHANGELOG 重建为待办事项（当前 `pini version` 输出滞后于代码状态）。
