# 内存模型对账读数

本件是交付证据，不是筹划载体：差集、五片与判据写在 `docs/plans/2026-11-12-self-hosting-plan.md`
的 **内存模型** 一节，这里只存本次对账用到的探针与原始读数。

注意 读数易腐。它们绑定当次的机器、工具链、构型与语料规模；实现一变即失去可比性，引用时只可作
「当时差多少」的依据，不可当作验收判据。

注意 三处差集已随内存模型批次清零：下面「对账」表记的是开工前的读数，保留作对照，不再代表现状。

## 环境

| 项 | 值 |
|---|---|
| 机器 | macOS 27.2.1，arm64 |
| 宿主编译器 | `.build/release/pini`，Apple Swift 6.4.2（swiftlang-6.4.2.1.9） |
| 自举编译器 | `bootstrap/.build/release/bin/pini-bootstrap`，同源首代产物 |
| LLVM 工具 | Homebrew clang 23.1.5 |
| 构型 | release |
| 语料 | 探针五条，均走单文件通道 |

两侧读数一律取 `run-llvm`（发射、链接、运行），不拿宿主的解释通道比自举的 LLVM 通道。自举侧无
`run` 子命令，`--stdlib` 必须给绝对路径，给相对路径会按程序基准解析并报「标准库源不存在」。

## 对账

「有」= 行为可观测且两侧一致；「缺」= 行为缺失；「未验」= 有实现但没有判据覆盖。

| 项 | 宿主编译通道 | 宿主解释通道 | 自举 | 锚点 |
|---|---|---|---|---|
| 析构调用点 | 有 | 有 | 缺 | `backend-llvm/src/_internal/bodies.pini` 的 `appendFieldGlue`，sweep 段只逐字段归还再 `free` |
| 析构形状校验 E4-040 | 有 | 有 | 缺 | `semantics/src/api/register.pini` 的 `registerTypeMembers` 按普通方法登记，无生命周期分派 |
| 析构体不归还 self | 有 | 有 | 缺 | `backend-llvm/src/api/emit.pini` 的 `seedParams` 把 self 登记成被调方持有 |
| 写时分裂 COW | 有 | 有 | 未验 | 行为已对上，缺常驻判据；`examples/cow.pini` |
| 展开 `unroll` | 有 | 有 | 有 | 已交付 |
| 值语义拷贝 | 有 | 有 | 有 | 已交付 |
| 释放胶水 | 有 | 有 | 有 | 已交付 |
| 弱引用 | 有 | 有 | 有 | 已交付 |
| 无主引用 | 有 | 有 | 有 | 已交付 |
| 导出面 `\|c` | 有 | 有 | 有 | 已交付 |
| 尾表达式与丢弃值 | 有 | 有 | 有 | 已交付 |
| `asyncDeinit` 调度 | 无 | 无 | 无 | 保留差异 |
| 结构化作用域退出 | 无 | 无 | 无 | 保留差异 |

## 探针一 析构执行

```pini
{资源}
名: String = "资源"

{{资源}}
deinit|self() -> ():
    print("析构")
    return

main|func() -> ():
    var r = 资源()
    print("体")
    return
```

| 侧 | 命令 | 输出 |
|---|---|---|
| 宿主 | `pini run-llvm` | `体` / `析构` |
| 自举 | `pini-bootstrap run-llvm` | `体`（缺 `析构`，退出码 0，无缺口报出） |

## 探针二 形状校验

同一文件放三处非法声明：`deinit` 挂在 struct 上、带一个形参、写成 `=>` 异步。

| 侧 | 命令 | 读数 |
|---|---|---|
| 宿主 | `pini check` | 三条 `E4-040`，位置指向各自的声明头 |
| 自举 | `pini-bootstrap check` | `workspace-ok 1 true`，零诊断 |

## 探针三 发射文本

自举侧同一探针的 IR，取关键行：

```
define void @__release_box_4(ptr %box) {      ; sweep 段
sweep:
  %f0 = getelementptr %object._u8D44_u6E90, ptr %box, i32 0, i32 4
  %v0 = load ptr, ptr %f0
  call void @bk_str_release(ptr %v0)
  call void @free(ptr %box)                   ; 无 deinit 调用
}

define void @deinit___u8D44_u6E90(ptr %p0) {  ; 函数存在
  ...
  %t1 = load ptr, ptr %s0
  call void @__release_box_4(ptr %t1)         ; 出口把 self 还给胶水
}
```

宿主同探针：

```
define void @__release_object._u8D44_u6E90(ptr %box) {
sweep:
  %t3 = bitcast ptr %box to %object._u8D44_u6E90*
  call void @deinit___u8D44_u6E90(%object._u8D44_u6E90* %t3)   ; 先析构
  ...                                                          ; 再逐字段清扫
}

define void @deinit___u8D44_u6E90(%object._u8D44_u6E90* %self) {
  ...
  ret void                                                    ; 不还 self
}
```

两处差异合起来才是完整的卡点：只补调用点时，`deinit` 出口那次归还落在已归零的箱上。

## 探针四 写时分裂

`examples/cow.pini` 的十行输出，宿主 `run-llvm` 与自举 `run-llvm` 都与
`examples/golden/cow.pini.out` 逐行相同，覆盖数组别名、字典改写、容器嵌套、内层快照与混合嵌套。

```
[1, 2, 3]
[99, 2, 3]
{a: 1}
{a: 9}
[42, 2]
[[1, 2]]
[[99, 2], [3, 4]]
[[1, 2], [3, 4]]
[{k: 9}, {k: 2}]
[{k: 1}, {k: 2}]
```

## 探针五 显式调用与异步析构

显式写 `r.deinit()`：

| 侧 | 输出 |
|---|---|
| 宿主 | `析构一次` / `体` / `析构一次`（显式一次 + 计数归零一次） |
| 自举 | `析构一次` / `体`（只有显式那一次） |

`asyncDeinit|self() => ()`：两侧 `check` 都通过，运行都只出 `体`，异步清理永不触发。
