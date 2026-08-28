# Pini 示例总目录

> 本目录是「示例即文档」的落地处：每个 `.pini` 文件演示一个（或一组紧密相关的）语言构造，
> 且**必须真实可运行、真实触发它所声明的特性**（不得只 `print("X 运行成功")`）。
>
> 自动化护栏：
> - `Tests/PiniTests/ExamplesConformanceTests.swift` —— 全部示例必须零错误通过 `check`（解析+语义+类型）。
> - `Tests/PiniTests/ExamplesRunTests.swift` —— 精选子集断言 `run` 输出 == 黄金输出，并守卫「占位 print」死灰复燃。

## 命名约定

- **类型 / 构造用中文**（契合语言定位）：`(点)` / `[形状]` / `{计数对象}` / `(盒<T>)`。
- **函数 / 变量**可用中文或英文，但**同一文件内保持一致**。
- 入口统一为 `main|func() -> ()`；顶级内容顶格，仅控制流子块才缩进。
- 每个示例头部含三要素：**① 演示什么 ② 运行命令 ③ 预期输出**（见各文件头部注释）。

## 示例映射表

| 文件 | 演示构造 | 预期输出（节选） | 稳定性 |
|------|----------|------------------|--------|
| `hello.pini` | 入门 Hello World | `Hello, World!` / `欢迎使用Pini语言` | Stable |
| `comments.pini` | `;` 行注释 | `Pini` | Stable |
| `lexical.pini` | 词法补全（数值进制 / 科学计数 / 字符串转义 / 插值 `\(...)`） | `255 / 10 / 15 / 1500` / 转义 / 插值 | Provisional |
| `control_if.pini` | `if` / `elif` / `else` | `大于5` | Stable |
| `control_while.pini` | `while` + `break`/`continue`/`scope 块标签` | `0 1 2` / `1 3 5` / `0 1` | Stable |
| `step.pini` | `while step` 步进块（每轮后执行 / `break` 跳过 / `continue` 仍触发） | `0 step 1 step 2 step` / `0 步进块 1 步进块 2` | Provisional |
| `for.pini` | `for-in` 迭代（数组/字典/集合 + `_` 占位 + `step:` + `scope 块标签` + 嵌套集合，G36） | `6 / 55 / 10 / 3 / 9 / 3 / 10` | Provisional |
| `compound_assign.pini` | 复合赋值 `+= -= *= /= %=` | `15 / 12 / 24 / 6 / 2 / 8 / 9 / 10 / 40 / 20` | Stable |
| `operators.pini` | 算术 / 比较运算符 | `30 / 10 / 200 / 2` | Stable |
| `defer.pini` | `defer` 延迟执行（LIFO） | `bodyfirstmiddlelast` / `blockinnerouter` | Stable |
| `lambda.pini` | 匿名函数 `func (x,) -> (I32,): return …` 绑定与调用 | `42` | Stable |
| `lambda-typed.pini` | 匿名函数双向类型推断（变量绑定自底向上 + 内联实参自顶向下） | `6 / 5 / 10` | Stable |
| `higher-order.pini` | 高阶函数（函数作实参 + 调用函数类型参数 + 匿名函数调用） | `10 / 21 / 36` | Provisional |
| `closures.pini` | 闭包（捕获 / 高阶 / 具名函数作值，双后端对齐） | `36 / 15 / 105 / 42 / 49 / 103` | Provisional |
| `match.pini` | 模式匹配 `match`/`case`（标量·字面量·通配） | `78.53975 / 12.0 / 6.0` | Stable |
| `composition.pini` | 内嵌组合 / 默认实现复用 | `2 / 1 / 默认` | Stable |
| `object.pini` | 引用类型 `object`（ARC） | `3` | Stable |
| `struct.pini` | 结构块值类型（字段+方法） | `3.0 / 4.0 / 5.0` | Stable |
| `enum.pini` | 枚举 enum（关联值 + `match`） | `12.56636 / 12.0` | Stable |
| `generic.pini` | 泛型类型 `盒<T>` | `7 / 泛型值` | Stable |
| `generic-func.pini` | 泛型函数 | `100 / 泛型函数` | Stable |
| `trait.pini` | 特征 `trait`（默认实现） | `旺财` | Stable |
| `collections.pini` | 数组 / 字典 / 集合、下标、`len` | `[1, 2, 3, 4, 5]` / `{Alice: 30, ...}` | Stable |
| `array_basic.pini` | 数组基础（构造 / 下标读 / 下标写 / 复合写 `a[i]+=k`） | `20 3 world 3 true 3 b 10 7` | Stable |
| `cow.pini` | 集合 COW 写时复制值语义（数组 / 字典 / 集合 / 嵌套写） | `[1, 2, 3] [99, 2, 3] {a: 1} {a: 9}` | Provisional |
| `dict_set_d2.pini` | 字典 / 集合（构造 / 键读 / 键写 / `len`） | `25 3 26 99 5 3` | Provisional |
| `stdlib.pini` | 标准库 字符串方法 + 数学函数 | `HELLO, WORLD` / `42 / 3 / 9 / 5.0` | Stable |
| `access.pini` | 字段访问 vs 方法访问 | `秒表 / 60 / 60` | Stable |
| `try.pini` | 错误处理 `try`/`except`（返回元组） | `读取失败` | Stable |
| `tuple.pini` | 元组 多返回值分组与整体传参 | `[3, 2]` | Provisional |
| `recursion.pini` | 递归（阶乘 / 斐波那契） | `120 / 55` | Stable |
| `optional.pini` | `Optional.some`/`none`（裸 `none` 字面量）+ `match` 解构 | `42 / none` | Experimental |
| `optional-sugar.pini` | `nil` 关键字（= `Optional.none` 等效常量）、`?T` 可选类型糖（= `Optional<T>`）与 `Optional` 双向互通 + `match case nil:` | `none / none / matched-nil / none / q-none / q-assign` | Provisional |
| `io.pini` | 文件 IO `writeFile`/`readFile` | `name: ...` / `hello from pini` | Provisional |
| `concurrency.pini` | 真并发 `=>` / `wait`（同步阻塞 join / 错误传播） | A/B 交错，`done` | Provisional |
| `concurrency-cancel.pini` | `cancel` / `joinWithin` / `isCancel` | `已超时取消 / 已手动取消` | Provisional |
| `concurrency-joinall.pini` | `joinAll` 聚合多 Future | `[2, 4]` | Provisional |
| `syntax-async-decl.pini` | 语法点：`=>` 声明处标记异步、体内同步写法、`ok`/`err` 承载 | `42` | Provisional |
| `syntax-await.pini` | 语法点：`wait` 值级等待（前缀） | `1 / 2` | Provisional |
| `syntax-arrow-dual.pini` | 语法点：`=>`（异步声明）、`wait`（等待）与 `<=`（纯比较） | `true / 7` | Provisional |
| `syntax-future-handle.pini` | 语法点：Future 句柄即普通值（cancel / joinWithin / detach / isCancel） | `已被取消 / 已超时` | Provisional |
| `syntax-async-contagion-end.pini` | 语法点：异步传染性终点（同步函数也可 `wait` 落地） | `10` | Provisional |
| `enum-namespacing.pini` | 跨枚举同名 case（命名空间化） | 见文件 | Stable |
| `validated-match.pini` | match 穷尽性（D3①：case 缩进子块、`case _:` 通配兜底） | 见文件 | Stable |
| `multifile/`（目录） | 多文件模块（跨文件共享命名空间） | `5 / 25 / 0` | Provisional |
| `package-demo/`（目录） | 可见性 / 模块化（4 级约定制） | 见目录 | Provisional |

## 进阶语法参考（非独立示例文件）

以下构造已实现或设计中，但**不适合作为「可独立 run 的小示例」**展示，故以语法参考形式记录：

### 跨模块 `import` / `export`
- 同模块（含 `pini.toml` 的目录）内符号按「文件 / 目录 `_` 前缀」4 级可见性共享，**无需 import**（见 `package-demo/`）。
- 跨模块边界语法（草案，见 spec）：
  - `[名称|import]` —— 绑定包路径到用例标识符（全导入）。
  - `[类型名称|export]` —— 显式覆盖默认导出：`_StructB = StructB` 提升私有为公开，`_C = StructC` 降为不导出。
- **状态**：跨包依赖解析属 P6+ 范畴（见各 `pini.toml` 的 `# 依赖解析属 P6+ 范畴` 注释），当前 CLI 以目录为入口运行多文件模块；真正的跨包加载尚未实现，故未提供可运行示例。

### LLVM 后端用法
解释器之外，提供 LLVM IR 后端（需本机 `clang`/`lli` 在 PATH，或设置 `PINI_LLVM_BIN`）：
- `pini emit examples/hello.pini` —— 输出 LLVM IR（`.ll`）到 stdout 或 `-o` 文件。
- `pini compile examples/hello.pini` —— 经 clang 编译并运行。
- `pini run-llvm examples/hello.pini` —— 经 LLVM JIT（`lli`）运行。
- 仅解释器执行可用 `pini run`；LLVM 后端需工具链，未纳入示例运行测试门。

## 已知静态限制（暂未提供示例）

以下特性**解释器已支持、可实际运行**，但当前静态类型/语义管线尚不能校验，
故无法作为「必须通过 `check`」的 `examples/` 示例存在（会破坏示例一致性测试门）。
列为已知缺口，待语言静态层补齐后可补示例：

- **内联匿名函数作实参**：`应用(func (n,) -> (I32,): return n * 2, 5)` 单行体形式已支持（spec G29 落地）。
  旧 `应用((n) => n*2, 5)` 的 `=>` 轻量内联写法不成立——`=>` 箭头专用于并发任务；匿名函数统一为
  `func` + 块体（含 async `=>`）后，内联实参用单行体 `func (n,) -> (T,): return 表达式`（见 `lambda-typed.pini`）。
- **匿名函数类型推断（已闭合）**：匿名函数绑定变量传强类型函数参数，`TypeInference.inferFuncLiteral`
  做双向推断：参数优先读标注 `p.typeAnnotation`、否则体运算符自底向上、再否则调用点期望自顶向下；
  返回优先读 `decl.returnTypes`（见 `lambda-typed.pini` / `FuncLiteralTests`）。
- **匿名函数统一（已落地 v0.31.0，spec G29）**：匿名函数放弃 `lambda` 关键字，统一为 `func` 关键字 + 块体，
  与具名函数基本一致——含 async（`=>`/`wait`/`await`）与参数标注（`(n: I32,)`，`inferFuncLiteral` 消费标注、
  调用点校验实参）。旧 `lambda` 关键字与 `Expression.lambda`/`Statement.lambdaDecl` 均已移除。
- **match 子块结构（D3①，2026-08-23 落地）**：`case` 缩进进 `match` 子块，通配兜底统一为 `case _:`；`default:` 与 `match 值:` 后 `pass` 通配子块一次性移除（G28 更新）。穷尽性检查内建（R1）：枚举 match 缺变体且无 `case _:` → `nonExhaustiveMatch`。

## 稳定性分级说明
- **Stable**：语法与语义已钉定，示例长期有效。
- **Provisional**：语法已定但细节（如元组元素访问、高阶函数类型推导）可能随 RFC/ADR 调整。
- **Experimental**：解释器已实现但 spec 未完全定义，语义后续可能变动（如 `Optional`）。
