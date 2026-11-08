# 原始指针加固：*T 的 C 面不透明通道

- 状态：方向与形状已定（2026-11-08）；全片已落。分片见「分片」，提交序见「细化」，未定项见「尚未定」，放宽的承接见「后续方向」。
- 基线：`33739b1`（`main`，与 `origin/main` 一致）。
- 上承：`docs/spec/c-interop-design.md`、`docs/spec/ir-contract.md`、`docs/spec/pini-reference.md`；运行时符号以 `docs/spec/runtime-abi.md` 为准。
- 旁证：`2026-11-08-object-c-abi-plan.md`（对象 C-ABI 路线，暂缓，见该件状态补充）。
- 性质：实施计划。现状判定收在「现状取证」章，不另立审计报告；本件不修源码、不跑加固。
- 范围：只加固 `*T` 及其 C 面形状。不做对象 C-ABI、不新增 `bk_*` 符号族、不改 `docs/spec/runtime-abi.md` 冻结台账、不放宽 `*T` 的 ARC 隔离语义——本计划要修的正是这道隔离。
- 取证口径：静态清点加实测探针，探针留在 `/tmp/pini-probe-*.pini`，不入仓；每支读 `check` / `run` / `run-llvm` 三面，门禁读数取自当次运行。

## 结论

| 裁决 | 内容 | 代价 |
|---|---|---|
| 目标 | 把 `*T` 加固成 C 侧可搬的不透明字节地址，无份额、无 ARC 语义 | 不能承载对象生命周期，不是对象 C-ABI 的等价替代 |
| 形状 | 定名：`*U8` 即 C 面不透明字节指针，`void*` 收窄为内部 IR 类型的兜底 | C 侧拿 `uint8_t*` 要显式转换——是既有事实，不是新增成本 |
| 次序 | 先立表与补校验，再归一判据，再收形状，最后补差分 | 放宽分支不在本计划内排期，由「后续方向」承接 |
| 边界 | 不动运行时台账、不引入新符号族 | 拿不到句柄箱的跨版本稳定性，只拿到字节地址 |

一句话：把现有 `*T` 的纪律补严，让它能安全地被 C 搬来搬去；对象那层 ARC 语义不在此计划内。

注意 这与 `2026-11-08-object-c-abi-plan.md` 不是同一件事。那份要的是「对象跨边界后仍活着」，本件要的是「C 能搬一个 Pini 不解读的地址」。前者要份额、归还与生命周期，后者只要求地址在约定期间有效且无人误用。

## 现状取证

### 静态清点

| 事实 | 位置 | 对计划的约束 |
|---|---|---|
| `*T` 在 IR 与 LLVM 层是不透明 `ptr`，份额归 `inert` | `Sources/PiniIR/IR/IRNode.swift`:69-72, 174-175；`Sources/PiniIR/IR/IRShare.swift`:54 | 不透明指针的机械零件已齐，不需要新表示 |
| 三张并存的类型判据：导入面、导出面、声明级 | `Sources/PiniSemantics/Common/FFIType.swift`:36-71, 118-131；`Sources/PiniSemantics/Type/TypeChecker.swift`:613-661, 1671-1736 | 同一目标三种结论，归一前不能谈放宽 |
| 标量集合五份且互不一致 | `Sources/PiniSemantics/Type/TypeChecker.swift`:1769-1780（14 个）、`:414`（7 个）；`Sources/PiniSemantics/Common/FFIType.swift`:134-148；`Sources/PiniHost/Interpreter/Value.swift`:328-343；`Sources/PiniHost/Runtime/RuntimeOps.swift`:320-334, 387-416 | 收口判据要连集合一起收，不能只收函数 |
| `void*` 退路存在但检查期不可达 | `Sources/PiniBackends/CHeaderBackend.swift`:199-203；`Sources/PiniSemantics/Type/TypeChecker.swift`:626-632；`Tests/PiniTests/CInteropExportTests.swift`:264-284 | C 面形状没有唯一答案，是「开退路」要处理的对象 |
| 头文件把 `*T` 写成具体 `T*`，T 限 C 标量 | `Sources/PiniBackends/CHeaderBackend.swift`:199-203；`docs/spec/c-interop-design.md`:464, 474 | 「不透明」只在 IR 层成立，措辞分层要写明 |
| `bk_ptr_*` 六符号零调用点，发射层内联 load/store 指令 | `Sources/PiniRuntime/PiniRuntime.swift`:986-988；`Sources/PiniBackendLLVM/CodeGen/IREmitter.swift`:3227-3267；`docs/spec/runtime-abi.md`:113 | 本计划不动这一族，也不改台账 |
| `addressOfVar` 三通道偏离，文档自述已知 | `Sources/PiniBackendLLVM/CodeGen/IREmitter.swift`:3271-3275；`Sources/PiniHost/Runtime/RuntimeOps.swift`:633-645；`docs/spec/ir-contract.md`:152 | 差分用例要先钉住现状，再谈修或登记 |
| `RawPointerValue.advanced(by:)` 零调用点；对象引用与原始指针无互转 | `Sources/PiniHost/Interpreter/Value.swift`:291, 299-326, 416-425 | 文档承诺的指针算术不存在，对象也没有裸地址可借 |
| 内建清单实测 98 条，台账文字写 92 条 | `docs/spec/runtime-abi.md`:118；`tools/builtin-inventory-check.py` 当次输出 | 数字漂移要在门禁片订正 |

### 实测探针

| 探针 | `pini check` 读数 | 结论 |
|---|---|---|
| `*String` 作函数形参 | 检查通过 | `TypeChecker.swift`:1745 对未登记 simple 名保守放行；`docs/spec/pini-reference.md`:2708-2718 明确禁 String |
| `*计数对象` 作函数形参 | `E4-001` 拒绝（通用 mismatch，非指针专用码） | 声明级 ARC 隔离在签名位生效 |
| `*计数对象` 写在函数体 `var p: *计数对象` | 检查通过，仅 `E7-001` 未使用变量警告 | 同一文件同一类型换位置即放行；`docs/spec/pini-reference.md`:2902 的承诺在局部声明失守 |
| 三项门禁 | ABI 台账 119 / 119、IR 契约 73 节点三锚全覆盖、内建清单 98 加零调用点 21 等于 119，全绿 | 门禁只校验存在性与计数，挡不住语义漏洞 |

注意 这四行是读数基线：**补校验**落地后，第一行（`*String`）与第三行（函数体局部 `*计数对象`）要由通过变为拒绝，第二行保持拒绝，门禁那一行是环境的体检读数、不是探针。

### 补充探针

细化阶段补跑的六支，读数改变了两处判断：漏洞不止在「检查期放行」，有些一直漂到执行期才报。

| 探针 | `pini check` | 执行期 | 结论 |
|---|---|---|---|
| `*Foo` 未登记名作形参 | 通过 | `run` 报 `E6-004`「lacks a resolvable scalar type」 | 未知名不是静默通过，是把失败推给执行期，且文案不指名字 |
| `*I16` / `*CChar` 作形参 | 通过 | `run` 报同一条 `E6-004` | 检查期认的宽度 IR 构不出来，检查期与执行期判据不一致 |
| `*点` 纯值 struct 作局部声明 | 通过 | `run` 报 `E6-004`「non-scalar annotation」 | 错误文案里「纯值结构体」这条承诺，三条通道都没实现 |
| `**I64` 局部声明 | 通过 | `run` 报 `E5-006`（无文件行号）；`run-llvm` 打印 7 | 取址在指针上退化成「不复制」，二级指针只在 LLVM 成立 |
| `p + 1` | 报「type mismatch: expected , got I32」 | 同左 | `expected` 是空串：`typeName(from:)` 的 `""` 漏进文案 |
| `&x` 后改 `x` 再 `load` | 通过 | `run` 打 7、`run-llvm` 打 9 | 文档自述的 `addressOfVar` 偏离可复现，且差分基线为空 |

注意 `examples/` 里只出现 `*U8`，收紧未知名不会让示例变红。会红的是 `Tests/PiniTests/CInteropExportTests.swift`:264-284 与 `:286-306` 的文案断言——声明级先于导出面跑，`*状态` 会先撞新码。

## 裁决

### 先修后放

**局部漏检**与**未知放行**是同一道隔离的两个破口，且都在「放宽目标」的上游。若先放宽 `*T` 的目标集合再补校验，等于在校验最松的时候给 ARC 对象开一条无人看管的路；若先补校验，放宽与否都安全。这条次序不是偏好，是依赖：所有后续分片都读同一张判据。

注意 补校验会改变现有语义——未登记名放行收紧后，拼写错误的类型名会从「静默通过」变成硬错误。这是期望结果，但诊断文案要点名「未登记的类型名」，不能只答「不兼容」。

### 三张判据归一

导入面 `FFIType.resolve`、导出面 `cExportRejection`、声明级 `validateDeclPointerTypes` 各自回答「这个 `*T` 能不能成立」。归一不是合并成一个函数，而是**一张共享的白名单加三处位置规则**：形状判定只有一份，形参位、返回位、字段位各自的额外约束留在各处。标量集合同样收成一份，`RawPointerValue.stride` 与 `RuntimeOps` 的解码宽度是运行时事实，按同一张表生成或加一致性断言。

注意 声明级现在只判 struct / object / enum / func / trait / extension / given 这七类，foreign 声明归导入面独占。归一后要保持这条分工：两个判据抢同一个标注时，先跑的那个会盖掉更精确的码。

### C 面形状

形状已裁：取**正名**。不放宽 `*T` 的目标集合，`*U8` 就是 C 面不透明字节指针，`void*` 收窄为内部 IR 类型的兜底，文档写清「C 面不透明指针不用 `void*`」。

选它的理由不只是省事，是细化阶段的实测把**放宽**的代价抬高了一档。`*点`（纯值 struct，判据文案与语言参考都明写允许）在 `check` 通过、`run` 报 `E6-004`，因为 `IRType(from:)`（`Sources/PiniIR/IR/IRLowerer.swift`:6028-6076）是纯函数、拿不到类型表，指针目标只收内建标量。真要放宽，得补三层：`IRType` 能解析用户类型、`RawPointerValue.stride` 按结构体布局算、LLVM 发 `%struct` 指针。那不是撤一条判据，是开一条管线，量级不小于其余各片之和。这条管线已裁要兑现，方向写在「后续方向」；本计划只落正名，不碰它。

正名的落地只有两处：`cType` 的 `.pointer` 分支只认标量目标，`default: void*` 继续服务其它 IR 类型；不变式用一句 `precondition` 钉住，不静默退 `void*`。另一处是措辞——`*U8` 的定名写进两份权威文档，与 `docs/spec/c-interop-design.md`:129 和 `Sources/PiniSemantics/Resources/Diagnostics.zh.toml`:156-157 的既有推荐对齐，同一个地址不许有两种 C 拼写。

### 边界

本计划不引入份额。`*T` 在 `IRShare` 里归 `inert`（`Sources/PiniIR/IR/IRShare.swift`:54），C 拿到的地址何时有效由分配者与调用约定决定，编译器不替它收账。对象、集合、串这类有生命周期的值仍不进 `*T` 的目标集合；`docs/spec/c-interop-design.md`:530 的禁令保持不动。

## 落点

| 文件 | 改什么 |
|---|---|
| `Sources/PiniSemantics/Common/CPointerTarget.swift`（新建） | 白名单本体：IR 可构造的标量集、`*U8` 定名、`reason(for:)` 给拒绝理由。三处判据与两处运行时宽度都读它 |
| `Sources/PiniSemantics/Type/TypeChecker.swift`:1671-1736, 2360, 2945 | 局部声明 `:2360` 与匿名函数签名 `:2945` 各挂一次 `validatePointerAnnotations`——标注只有这两个可写位置，泛型实参位解析器已拒 `*T`；`cCompatibilityFailure` 的未登记名分支从放行改为拒绝；`visiting` 只 insert 不 remove 的写法按标准 DFS 收口 |
| `Sources/PiniSemantics/Type/TypeChecker.swift`:613-661, 1769-1780, 2345-2354 | 导出面与 `isCScalarType` 改吃归一后的白名单，`.pointer` 分支保留位置规则；`typeName(from:)` 的 `.pointer` 返回拼写而不是空串 |
| `Sources/PiniSemantics/Common/FFIType.swift`:36-71, 118-148 | 导入面改吃同一张白名单；`widthsOutsideIR` 与标量集合的边界写清，不靠两处硬编码对齐 |
| `Sources/PiniBackends/CHeaderBackend.swift`:181-218 | `.pointer` 只认标量目标，非标量在这里 `preconditionFailure`（导出面已先拒）；`default: void*` 留给非指针类型；`cSizeAndAlign` 的指针宽度改取 `MemoryLayout<UnsafeMutableRawPointer>` |
| `Sources/PiniHost/Interpreter/Value.swift`:328-343、`Sources/PiniHost/Runtime/RuntimeOps.swift`:320-334, 387-416, 634-636 | 解码宽度与 `CChar` 不可达按归一表处理；`snapshotPointer` 已裁不修（`&x` 登记为 `debt`）；不改 `RawPointerValue` 的所有权语义 |
| `Sources/PiniSemantics/Resources/Diagnostics.zh.toml`、`Sources/PiniSemantics/Resources/Diagnostics.en.toml` | 指针专用码位与文案，两份同批改；码位从 `E4-036` 起取空位 |
| `Tests/PiniTests/PointerSurfaceTests.swift`（新建） | 差分语料与负例：`**T`、指针上的 `&`、`p + 1`、未知名、局部声明各一组 |
| `docs/spec/pini-reference.md`、`docs/spec/c-interop-design.md`、`docs/spec/ir-contract.md` | 按实现订正文档：纯值 struct、禁止表、四种指针算术、内建名、`addressOfVar` 偏离、`*U8` 定名 |
| `docs/spec/runtime-abi.md`、`tools/runtime-abi-check.py` | 只订正 109 / 119 / 92 的读数，不动符号清单 |
| `tools/` 下门禁 | 补两份诊断表的 key 集合一致性判据、标量集合一致性判据、内建清单空族判据 |

## 分片

| 分片 | 内容 | 验收 |
|---|---|---|
| 补校验 | **立表**（不改行为）→ **补局部**（函数体标注收集）→ **收未知名**（点名拒绝）三个提交；`visiting` 收口 | 立表后探针读数一律不动；补局部后局部声明、匿名函数形参、泛型嵌套三处翻红；收未知名后 `*Foo`、`*String`、`*I16`、`*CChar` 检查期即拒；签名位 `*计数对象` 仍被拒；`examples/` 全量 `check` 不新增红 |
| 收口判据 | 三张判据归一到一张白名单，标量集合归一；拼写留各层 | 同一个 `*纯值struct` 在导入面、导出面、声明级得到同一结论，各一条用例；标量表与两处取名由单测对账 |
| 开退路 | 按已裁的正名收窄 `void*` 死分支，给 C 面不透明指针唯一形状 | 头文件里非标量目标不再有拼写；未用不透明目标的库头文件与基线逐字相同；`CInteropExportTests.swift`:264-284 的既有负例按裁决更新或保留 |
| 差分补测 | `**T` 嵌套与 `addressOfVar` 两条差分；`RawPointerValue` 宽度由收口片的单测覆盖；指针算术四种形式不在本片（「首版不做」），声明级负例已由补校验覆盖；基线扩成四列 | 每条差分用例在 `run` 与 `run-llvm` 上同值或登记为通道差异；登记必须写清处置（`declared` / `debt`）与理由；全量测试数只许不减 |
| 门禁 | 诊断表 key 集合与占位符、标量集合、空族、台账读数四项判据 | `tools/diagnostics-parity-check.py`、`tools/scalar-set-check.py`、`tools/builtin-inventory-check.py`、`tools/runtime-abi-check.py` 各自带自检且全绿 |
| 文档收口 | 订正三份权威文档的事实错误，未实现处加 `TODO` 标记：纯值 struct 与四种指针算术、`*U8` 定名、`addressOfVar` 记为 `debt`；按 `GIT_WORKFLOW.md` 走特性分支 | `hooks/pre-commit` 的注释、格式、文档链接门禁三条都过；文档里每个指针形状都能指回一处源码判据 |

补校验先落：收口判据、开退路、差分补测三片都读同一张判据，判据没定就各自猜。门禁片与文档收口片最后收，不分散到各片顺手改。

## 细化

八个提交单元，按依赖排。`补校验` 拆三个，其余一片一提交。分支 `dev-agent-pini-raw-pointer-hardening`，身份 `Pini Dev <dev@pini.local>`（注册表在册）；每笔提交前过注释与格式门禁，并回前过容器 CI。

已落八笔：立表、补局部、收未知名、收口判据、开退路、差分补测、门禁、文档收口。收未知名删掉 `isCScalarType` 的十四名表，收口判据又删掉 `cExportScalars` 与两处运行时宽度 switch，只余「表 + `FFIType` 取名 + 运行时编解码」三处，这三处由 `tools/scalar-set-check.py` 对账。开退路只删掉头文件里那条 `void*` 死分支，合法模块的产物逐字不变。差分补测把基线扩成四列，新增的差距从此必须写明处置与理由。门禁片补了两份一致性脚本与 `family-empty`，并把台账三处旧读数订正。

文档收口没有按本表原写的「按实现订正」执行：删掉承诺会把「未兑现」写成「已取消」。实际做法是**保留原文、加 TODO 标记**——`TODO(聚合值指针)` 八处，分别标在 §3.2 的纯值 struct 与算术、§3.2 示例、§9.2 与 §9.6 的示例、§9.3 的允许表与算术、§9.7 的 `Raw` 表前。标量范围这类**事实错误**直接订正（I16 / U16 / U32 / F32 没有 IR 对应类型），不归 TODO。

注意 「纯值结构体可作 `*T` 目标」在本计划期不成立：声明级不再顺字段递归，三面一律拒绝。这不是取消承诺，是把兑现推迟到「后续方向」；当下作者得先把值搬进 `*U8` 缓冲。文档已按这一口径落：原文保留，未实现处标 `TODO(聚合值指针)`，不写「已取消」。

| 提交单元 | 改哪里 | 判据（现读数 → 期望读数） |
|---|---|---|
| 补校验·立表 | 新建 `Sources/PiniSemantics/Common/CPointerTarget.swift`：IR 可构造的标量集、`*U8` 定名、拒绝理由。纯新增，不改行为 | 单测断言表等于 `IRType(from:)` 可构造集；`swift test` 总数不减；六支补充探针读数一律不动 |
| 补校验·补局部 | `TypeChecker.swift`:2360 的 `.varDecl` 与 `:2945` 的 `.funcLiteral` 各挂一次 `validatePointerAnnotations`（标注只有这两个可写位置；泛型实参位解析器已拒 `*T`）；`:2345-2354` 的 `.pointer` 返回拼写而不是空串 | 局部 `*计数对象`、匿名函数形参 `*计数对象`、`[*计数对象]` 三处由通过改为拒；`p + 1` 的 `expected` 不再是空串；签名位读数不变 |
| 补校验·收未知名 | `TypeChecker.swift`:1745 的 `else { return nil }` 改为点名返回 | `*Foo`、`*String`、`*I16`、`*CChar` 由「通过、执行期报 `E6-004`」改为检查期即拒；结论与 `ForeignTypeSurfaceTests.swift`:91 的导入面一致 |
| 收口判据 | `CPointerTarget` 收成一份标量表加一张宽度表；`cExportRejection`、`FFIType.pointerTarget`、`pointerTargetFailure` 读同一份；`cExportScalars` 删除；`RawPointerValue.stride` 与 `RuntimeOps.encode/decode` 改读宽度表；`pointerTargetFailure` 不再顺结构体字段递归 | 同一个 `*纯值struct` 三面同一句；表里七个标量在运行时编解码同值、表外名字被运行时拒绝；`CInteropExportTests` 两处断言随措辞更新；全量测试只增不减 |
| 开退路 | `CHeaderBackend.cType` 的 `.pointer` 只认标量目标，非标量 `preconditionFailure`；`cSizeAndAlign` 的指针宽度改取 `MemoryLayout` | 七个标量目标各写出自己的 C 拼写（`int8_t*` 到 `bool*`），头文件里不出现 `void*`；既有头文件断言零改动通过 |
| 差分补测 | 新建 `Tests/PiniTests/PointerSurfaceTests.swift`（CLI 两条通道）；`examples/pointer-address.pini` 作探针语料；基线改四列 | `&x` 钉 7 / 9、`**I64` 钉 `E5-006` / 7；探针输出 `baseline: 1 known gap(s)（debt 1）` 且退出 0 |
| 门禁 | 新建 `tools/diagnostics-parity-check.py`（key / 字段 / 占位符）与 `tools/scalar-set-check.py`（表 vs 导入面 vs 运行时编解码）；`builtin-inventory-check.py` 加 `family-empty`；`docs/spec/runtime-abi.md` 的 109 两处改 119、92 改 98；CI 加两步 | 两侧各带 `--self-test`；空族只在有零调用点登记时放行；台账 119 / 119 / 98+21，四条一致 |
| 文档收口 | `docs/spec/pini-reference.md` 的术语表与 §3.2、§9.1、§9.2、§9.3、§9.6、§9.7；`docs/spec/c-interop-design.md` 的取址注意；`docs/spec/ir-contract.md` §2.7 与已知偏离表 | `tools/check-doc-links.sh` 通过；八处 `TODO(聚合值指针)` 可 grep；承诺段不出现「已取消」一类措辞 |

注意 差分补测的裁定已落：**改基线规矩**。基线由两列扩成四列（fixture / verdict / 处置 / 理由），处置只收 `declared`（文档规定两通道本就不同）与 `debt`（实现待修）；缺列、错处置、空理由各自判红，由 `--self-test` 覆盖。`&x` 登记为 `debt`，理由沿用 `docs/spec/ir-contract.md` §2.7 已裁的「统一到真引用」，本轮不动 `snapshotPointer`。`**T` 不进 examples（`run` 会失败），改由 `PointerSurfaceTests` 钉住 `E5-006` 与 7。

注意 补校验三笔各自可回滚：立表不改行为，补局部只碰函数体，收未知名只碰一个分支。挤成一笔时，语料变红分不清是哪条判据放的。

## 诊断

| 情形 | 码位 | 要点 |
|---|---|---|
| 未登记类型名作 `*T` 目标 | 新 | 点名该名字，说明它不在 C 兼容白名单里，别只答「不兼容」 |
| 局部声明的 `*T` 指向 ARC 对象 | 新 | 与签名位同一句文案，位置不同不改判据 |
| 三张判据结论不一致 | 门禁失败而非用户诊断 | 属于实现漂移，不该让作者看到 |

码值一律以落地时 `Sources/PiniSemantics/Resources/Diagnostics.zh.toml` 与 `Sources/PiniSemantics/Resources/Diagnostics.en.toml` 的下一个空位为准；现表最大是 E4-035、E5-020、E7-007。现有 `*计数对象` 失败走通用 `E4-001`，收口后应落到指针专用码。

## 风险

| 风险 | 说明 | 处置 |
|---|---|---|
| 收紧放行让语料变红 | 未登记名放行改成拒绝后，拼写错误与 `CChar` 这类半接线类型会显形。`examples/` 只有 `*U8`，不会红；红的是 `CInteropExportTests` 的两条文案断言 | **补校验**片同批跑 `examples/` 全量 `check`，逐条判定是修语料还是补白名单，不静默加例外 |
| 差分用例暴露既有偏离 | `addressOfVar` 的解/LLVM 分叉是文档自述的已知偏离，补 parity 会让它变成红灯；`tools/ir-parity-baseline.tsv` 为空，连登记位都没有现成的 | 先钉住现状读数，再裁「修」还是「登记为通道差异」；不要在补测片里顺手改语义 |
| 死分支处理影响兜底 | `cType` 的 `default: void*` 同时服务多种 IR 类型，收窄可能让别处失去拼写 | **开退路**片先列全所有会落到 `default` 的调用点，再动分支 |
| 文档与实现二选一 | 纯值 struct、禁止表、四种指针算术、内建名四处矛盾。纯值 struct 这一条实测确认不可执行，兑现它要开一条 `IRType` 到用户类型的管线 | 已裁**完整兑现**：本计划把承诺标成未兑现并指向「后续方向」，兑现归新计划；其余三处按实现订正 |
| 类型名比较漏项 | `typeName(from:)` 的 `.pointer` 返回 `""`（`Sources/PiniSemantics/Type/TypeChecker.swift`:2345-2354），`p + 1` 实测报出「expected , got I32」 | **补校验·补局部**同批修，返回类型拼写 |
| 台账读数漂移 | 109 / 119 / 92（实测 98）并存，会让新增判据失去基准 | **门禁**片一次订正，不改符号清单本身 |
| 两份诊断表静默回退 | `Sources/PiniSemantics/Common/DiagnosticResources.swift`:59, 66 缺 en 项时回退 zh，无门禁 | 已补：`tools/diagnostics-parity-check.py` 对 key / 字段 / 占位符三条 |

## 尚未定

**专用诊断码**。是否给 `*T` 单独一个码位，还是复用 `E4-028` 加一句更细的文案。建议一码两理由：码位取 `E4-036`，位置无关，理由串分「指向 object（ARC 隔离）」与「未登记的名字」两种——两个码会把同一句判据拆成两份维护，而这两种情形作者要做的事是同一件：换掉目标类型。

**偏离处置**。`addressOfVar` 的分叉已裁：不动解释器语义，登记为通道差异，处置写 `debt`（`docs/spec/ir-contract.md`:152 已裁统一到真引用，解释器侧待修）。基线表已加一行，理由写在该行；`snapshotPointer` 本轮不动。

**原计划归档时点**。`2026-11-08-object-c-abi-plan.md` 已标注暂缓，何时归档或重启取决于是否重新需要对象跨边界的生命周期语义；本计划不设触发条件，也不替它决定。

**首版不做**：对象、集合、串作 `*T` 目标；指针算术四种形式的实现；`bk_ptr_*` 六符号接线；`StringHandle` 与 `*T` 的通道合并。这几项各自会带出一份新的语义契约或台账变更，等判据归一跑稳再逐条评估。纯值 struct 不在此列——它的方向已裁，见「后续方向」。

## 后续方向：聚合值指针

本计划把 `*T` 的目标集收成「七个标量或另一层指针」，`*纯值struct` 在三面一律被拒。这是**本计划期**的裁决，不是终局：纯值 struct 作目标的承诺已裁「完整兑现」，兑现由下一份计划承接。本节只写方向，不写提交单元、不估工量；细化留到新计划立项时做，本件不因此增章。

### 为什么要单独立项

`*纯值struct` 不是松开一条判据，是补一条从语义层穿到两个引擎的管线。四处卡点各有代价，且互相有依赖：

| 卡点 | 位置 | 现状 |
|---|---|---|
| 归一无表 | `Sources/PiniIR/IR/IRLowerer.swift`:6028-6044 | `IRType.init?(from:)` 的 `.simple` 分支只认内建名，其余返回 `nil`：拿不到类型种类，`*点` 连 IR 都生成不了 |
| 拼写带星 | `Sources/PiniIR/IR/IRNode.swift`:158-159 | `.nominal` 的 `llvmSpelling` 是 `%struct.<mangled>*`，本身已是指针；把它当「结构体值」用，`load` 读出一个指针而不是结构体 |
| 单值读写 | `Sources/PiniBackendLLVM/CodeGen/IREmitter.swift`:3227-3237、`:3242-3267` | 指针读写各按单一 `element.llvmSpelling` 发一条 load/store，元素是结构体时没有整块搬运这条路 |
| 解码无布局 | `Sources/PiniHost/Runtime/RuntimeOps.swift`:314-340、`Sources/PiniHost/Interpreter/Value.swift`:331-339 | 解释器只按标量名解码；`stride` 对结构体返回 `nil`（按 1 字节走），字段偏移与对齐没有来源 |

先定**取值形态**：`load(p)` 的元素是结构体时返回什么。现在的 IR 值模型里，结构体值就是「指向存储的指针」，没有一个可复制的聚合值；不先答这一问，另外三处都没有目标可对。

注意 这与本计划的**正名**不冲突。正名裁 C 面拼写（`*U8` 而非 `void*`），聚合值指针裁目标集合。前者已落，后者是本计划刻意留下的缺口，也是「先修后放」里「放」的那一半。

### 分片方向

五片，按依赖排。这里只给顺序与判据方向，不给提交单元。

| 分片 | 做什么 | 判据方向 |
|---|---|---|
| 定取值 | 裁**取值形态**：`load` / `store` 在聚合元素上的语义，写进 `docs/spec/ir-contract.md`；同时定结构体值是引用还是可复制值 | 文档先于实现：另外三处都按这一条设计，改动前后都能引用同一句 |
| 扩归一 | `IRType.init?(from:)` 接类型表，能解出 `.nominal` 与 `.enumeration`；`.pointer` 分支不再只认标量 | `*点` 能生成 IR；既有标量读数逐字不变 |
| 补布局 | 结构体布局（字段偏移、对齐、总宽）有唯一来源；`stride` 与运行时编解码读它 | 嵌套 struct 与含指针字段的 struct 各有宽度断言 |
| 改读写 | 发射层按元素总宽发整块搬运；解释器同步；`&x` 的 `debt` 一并收 | 三条通道同值：构造、`load`、`store` |
| 开目标 | 三面白名单扩到纯值 struct；导出面与头文件为它生成 C 类型名与指针拼写；导入面放行 | `*点` 在声明级、导入面、导出面同一结论；C 侧能编译 |

`swift test` 与示例门禁的基线以立项时读数为准，只许不减。

### 新计划的边界

- 对象作目标仍不在内：ARC 隔离不动，跨边界的生命周期归 `2026-11-08-object-c-abi-plan.md`。
- 集合、串作目标仍不在内：它们的值表示是句柄，不是可搬的聚合值。
- 指针算术的四种形式仍不在内，除非**取值形态**裁出步长语义。
- 若要新增运行时符号，`docs/spec/runtime-abi.md` 的冻结台账按增补流程走，不沿用本计划的「只订读数」口径。

注意 新计划的立项时点排在「文档收口」之后：文档先把承诺写成「未兑现、已有方向」，新计划立项时引用一句现成的话，不必重新论证一遍为什么做不到。
