# 对象句柄的 C-ABI：不透明指针与符号契约

- 状态：方向暂缓（2026-11-08），未开工。三项裁决见「结论」，未定项见「尚未定」。
- 状态补充：对象解读成指针需附加一层 ARC 语义，成本过重；当前工作转到 `2026-11-08-raw-pointer-hardening-plan.md`。本件保留为将来真要做对象 C-ABI 时的路线，裁决与分片不废止。
- 基线：`33739b1`（`main`，与 `origin/main` 一致）。
- 上承：`docs/spec/c-interop-design.md`。语言语义以 `docs/spec/pini-reference.md` 为准，IR 节点语义以 `docs/spec/ir-contract.md` 为准，运行时符号台账以 `docs/spec/runtime-abi.md` 为准。
- 性质：实现计划。不改 `*T` 语义，不把对象布局交给 C，不新增语言级类型标注。
- 范围：仅对象块（`[名|object]`）、仅导出面的 `|c` 条目、C 侧只搬不透明指针。结构块、给定块、枚举、集合与元组不动。
- 取证口径：本轮是源码与规范原文的静态取证，未跑编译器探针。运行期读数由「分片」里的**证据**片补齐，开工后先做。

## 结论

| 待决 | 裁决 | 代价 |
|---|---|---|
| 指针形态 | 不透明句柄：C 侧只有一个不透明指针，不解读箱头与字段 | C 不能直读字段，读写只能经 Pini 导出的函数 |
| 稳定边界 | 只冻符号与句柄契约：头文件只发原型与不透明类型，不发布局、不发偏移量断言 | 没有零调用开销的字段访问 |
| 覆盖清单 | 仅对象块 | 首版能力有限，其余按后续分片排 |

一句话：把「稳定」锁在「库对外有哪些符号、句柄怎么收账」上，而不是锁在「对象在内存里长什么样」上。对象布局此后可自由演进，C 侧不受影响。

三条既有裁决保持不动：给定块字段区直连（`docs/spec/c-interop-design.md`:405）继续只在给定块上成立；`docs/spec/runtime-abi.md`:64 的「不透明句柄只搬指针、不解读布局」从容器推广到对象；`docs/spec/c-interop-design.md`:474 的三通道一致性仍是一条硬判据。

`docs/spec/c-interop-design.md`:530 写「Pini 不得把 ARC 对象的地址交出去」。句柄路线不能绕过这句话，只能满足它：**交出去的是运行时段另分配的句柄箱地址，不是名义箱地址**。如何做到见「裁决」里的**载体**段。

## 现状取证

| 事实 | 位置 | 对计划的约束 |
|---|---|---|
| 对象在 IR 里已经是指针：`nominal(name:isObject:)` 发成 `%object.<名字>*`，头四格是强计数、弱计数、类型标识、弱引用旁表，字段从第四槽起，无虚表 | `Sources/PiniIR/IR/IRNode.swift:44-49`、`Sources/PiniIR/IR/IRNode.swift:589`、`Sources/PiniIR/IR/IRLayout.swift:5-24`、`docs/spec/ir-contract.md`:349-371 | 不需要新的降载形态，缺的只是 C 面的契约 |
| C 面明确拒绝对象 | `docs/spec/c-interop-design.md`:472、`docs/spec/c-interop-design.md`:474、`docs/spec/c-interop-design.md`:530、`docs/spec/pini-reference.md`:404-406、`docs/spec/pini-reference.md`:2712-2713、`Sources/PiniSyntax/AST/Types/Type.swift:43-45` | 拒绝理由是生命周期与三通道一致，不是缺指针；放行要连理由一起处理 |
| 导出面与导入面各有一张类型判据，不是同一份 | 导入面 `Sources/PiniSemantics/Common/FFIType.swift:36-71`；导出面 `Sources/PiniSemantics/Type/TypeChecker.swift:613-661` | 新增形状要决定各加一支还是收口，不能只改一处 |
| 导出的函数签名原样落到 `IRExportFunction`，头文件把认不出的类型一律写成 `void*` | `Sources/PiniIR/IR/IRLowerer.swift:904-952`、`Sources/PiniIR/IR/IRModule.swift:212-235`、`Sources/PiniBackends/CHeaderBackend.swift:181-205` | C 侧拼写几乎不用改；要改的是准入与份额 |
| 导出转发体只做搬运，返回位直接 `ret` | `Sources/PiniBackendLLVM/CodeGen/IREmitter.swift:3581-3670` | 返回对象时没有 retain，C 拿到的是悬空风险 |
| `bk_nominal_retain` 只是头格 `+= 1`，非原子；`bk_nominal_release` 只减头格并返回是否归零，不释放字段也不 `free` | `Sources/PiniRuntime/PiniRuntime.swift:2172-2190` | 这两个符号不能直接交给 C 当句柄入口 |
| 真正的回收在发射层按类型合成的释放胶水里，归零才逐字段 sweep 并 `free` | `Sources/PiniBackendLLVM/CodeGen/IREmitter.swift:4082-4123`、`Sources/PiniBackendLLVM/CodeGen/IREmitter.swift:3886-3895`、`Sources/PiniBackendLLVM/CodeGen/IREmitter.swift:3897-3914` | 归还必须经过胶水，句柄要能找到对应类型的那份 |
| 字符串句柄已经走通「不透明类型 + 五个入口 + 仅 LLVM」这条路 | `docs/spec/c-interop-design.md`:208-236、`Sources/PiniBackends/CHeaderBackend.swift:45-67`、`docs/spec/runtime-abi.md`:100-105 | 头文件、冻结登记、通道提醒都有可照抄的模板 |
| `pini` 解释器进程不带 `bk_*` 符号，字符串句柄与变参因此只在 LLVM 通道可用；导出面本来只存在于 `build --shared` 产物 | `Package.swift`:10-11、`Package.swift`:88-90（`PiniCLI` 只依赖 `PiniCore`，CLI 自身不 import 运行时）；`docs/spec/c-interop-design.md`:598-601 | 导出面不需要给解释器补 shim |
| 运行时符号台账是冻结的，改动要走语言级变更流程，等式由器械校验 | `docs/spec/runtime-abi.md`:28-33、`docs/spec/runtime-abi.md`:121-128、`tools/runtime-abi-check.py:42-44` | 新增 `bk_*` 入口等于动台账，量级不小 |

注意 台账里的读数不一致，写文档或改表格前先认准口径：`docs/spec/runtime-abi.md`:24 与 `docs/spec/runtime-abi.md`:35 写 109，`docs/spec/runtime-abi.md`:58 合计 119，实测 `Sources/PiniRuntime/PiniRuntime.swift` 的 `@_cdecl("bk_…")` 是 119。`tools/runtime-abi-check.py:22-24` 的说明串还留着 99 与 97 的旧读数，`docs/spec/c-interop-design.md`:598 的 97→102 也是历史读数。计划不引用这些数字做基线，改台账时同批订正。

## 裁决

### 句柄形状

C 侧只有一个不透明指针，头文件写 `typedef struct bk_object_handle bk_object_handle;`，不给结构体定义、不写 `sizeof` 或 `offsetof` 断言。理由与 `docs/spec/runtime-abi.md`:64 一致：调用方只搬指针，不解读布局。对象字段可以是任意 Pini 类型——串、集合、其他对象、元组都不设限，因为 C 根本看不到字段区；这与给定块「字段须全部 C 兼容」（`docs/spec/c-interop-design.md`:424）形成明确分工。

不改 `*T`：`docs/spec/pini-reference.md`:404-406 的「与 ARC 完全隔离」是原始指针的语义，放宽它会同时破掉指针算术与 `unsafe 加载` 的前提。也不新增 `StringHandle` 那样的语言级类型名——导出条目的右端本来就是本模块符号，作者写对象块名即可，不要求他记一个边界专用拼写。

### 载体

句柄箱由运行时段另分配，内部持有名义箱指针与该类型释放胶水的函数地址；C 拿到的指针指向句柄箱，不是名义箱。`docs/spec/c-interop-design.md`:530 的禁令因此字面成立：ARC 对象的地址从未交出去。

调用链是这样闭合的：

| 方向 | 动作 |
|---|---|
| Pini 返回对象 | 转发桩先对名义箱 retain 一次，再建句柄箱，把箱指针与释放胶水地址交给它，返回句柄箱指针 |
| C 保存 | 调句柄的 retain 入口，计数归 C 自己；C 不 release 就是泄漏，与字符串句柄同规 |
| C 归还 | 调句柄的 release 入口；运行时段把名义箱交给那份释放胶水，由胶水减头格、归零才 sweep 并 `free`，最后释放句柄箱 |
| C 传回 Pini | 转发桩从句柄箱取回名义箱指针，按引用语义交给 Pini 函数；C 那份份额不动 |

「C 传回 Pini」是能力闭环，不是放开导入面：`|c` 导出函数接收对象类型作形参仍属导出面，`[..|foreign]` 块里声明对象形参不在本计划范围。

注意 释放胶水由发射层按静态类型合成，运行时段类型无关（`Sources/PiniRuntime/PiniRuntime.swift:2182-2183`）。把函数地址随句柄箱存下来，是让「运行时段不必知道类型」与「归还要走到类型专属胶水」同时成立的唯一接缝；按箱头类型标识去查全局注册表会引入跨模块状态，不选。

### 份额归属

份额只看谁分配谁交出，与 `docs/spec/runtime-abi.md`:65-67 同规。Pini 侧返回时那次 retain 是把一份份额交给 C，不是复制对象；C 侧传回时 Pini 不额外 retain，若 Pini 把引用存进字段，那份 +1 由编译器既有的 `adoption` 路径负责（`Sources/PiniIR/IR/IRShare.swift:61-74`）。空句柄按空引用处理——`bk_nominal_release(null)` 返回 0，胶水对空字段安全（`Sources/PiniBackendLLVM/CodeGen/IREmitter.swift:3897-3899`）。

### 稳定边界

冻结的是三样：`bk_object_handle_*` 符号名与签名、`<块>_init` / `<块>_shutdown` 已有的生命周期约定、`|c` 条目的对外名转写（`Sources/PiniSemantics/Common/CName.swift:6-17`）。不冻对象字段顺序、不冻箱头宽度、不冻类型标识的取值。

类型标识按类型声明顺序分配（`Sources/PiniBackendLLVM/CodeGen/IREmitter.swift:543-546`），加一个类型就会挤动后面的值，因此它绝不能进 C 面；句柄箱里存的是释放胶水地址，不是类型标识。这也意味着「只冻符号与句柄契约」是有实质的：布局与内部编号随便改，C 侧看到的头文件逐字不变。

### 裁决记录

| 主题 | 场景 | 决策 | 理由 | 代价 | 状态 |
|---|---|---|---|---|---|
| 句柄面 | 对象要不要进 C 面 | 不透明句柄，只搬指针 | 与 `docs/spec/runtime-abi.md`:64 同规；布局改动不破 ABI | C 无字段直读，读写多一次函数调用 | 已接受 |
| 布局面 | 备选：按给定块先例发 `typedef` 与 `_Static_assert` | 不采用 | 会冻住箱头与字段顺序，且与 `docs/spec/c-interop-design.md`:530 的 ARC 禁令正面冲突 | 省下的调用开销换不来跨版本稳定 | 已否决 |
| 双字复合指针 | 备选：数据指针加元数据指针随值走 | 不采用 | 元数据表要按类型发常量，等于把类型布局换一种形式外借 | 符号面与类型面同时膨胀 | 已否决 |

## 落点

| 文件 | 改什么 |
|---|---|
| `Sources/PiniSemantics/Type/TypeChecker.swift:613-661` | `cExportRejection` 的 `.simple` 分支认对象块名：形参与返回放行、字段位仍拒；复用既有 `typeFieldsByName` 与引用类型集合判据，不新开一份白名单 |
| `Sources/PiniSemantics/Common/FFIType.swift:36-71` | 若**尚未定**里的通道裁决选了「导入面也认」，这里补一支；否则不动，并在注释里写明导出面的对象形状不归这张表管 |
| `Sources/PiniIR/IR/IRLowerer.swift:904-966` | `lowerExportBlock` 记下对象形参/返回位的类型信息，供发射层挑释放胶水；`IRExportFunction` 现有字段够用则不加字段 |
| `Sources/PiniIR/IR/IRModule.swift:212-235` | `IRExportFunction` 若需携带「返回/形参是对象句柄」标记，在这里加，不塞进 `IRType`——`IRType` 是 IR 类型，不是 C 面角色 |
| `Sources/PiniBackendLLVM/CodeGen/IREmitter.swift:3581-3670` | 导出函数返回位插 retain 与句柄箱构造；形参位插取箱；复用 `ensureReleaseFunction`（`:4085`）拿胶水符号，不为句柄另造一套释放逻辑 |
| `Sources/PiniBackends/CHeaderBackend.swift:14-43` | 按需发不透明类型与句柄入口声明，仿 `stringHandleDeclarations()`（`:57-67`）；`cType` 的 `default: void*` 不用改 |
| `Sources/PiniRuntime/PiniRuntime.swift` | 新增句柄箱族；头格计数的原子性问题见「风险」 |
| `docs/spec/runtime-abi.md` | 新增一族、订正 109 与 119 的读数、更新零调用点登记与互补表 |
| `tools/runtime-abi-check.py`、`tools/builtin-inventory-check.py` | 前者只按正则数 `@_cdecl("bk_…")`，逻辑不用改，只改说明串的旧读数；后者的 92 与 21 互补关系要跟着新族重算 |
| `Sources/PiniSemantics/Resources/Diagnostics.zh.toml`、`Sources/PiniSemantics/Resources/Diagnostics.en.toml` | 新增负例码位，两份同批改 |
| `docs/spec/c-interop-design.md`、`docs/spec/pini-reference.md` | 前者补「对象句柄」一节与类型映射表的那一行；后者补 C 面句柄的所有权约定，不动第 3 章的 `*T` 约束 |

## 分片

| 分片 | 内容 | 验收 |
|---|---|---|
| 证据 | 补跑运行期探针：现有 `|c` 函数返回对象时 `check` 报什么、`cType` 落什么、共享库里该符号长什么样；记下全量测试基线读数 | 探针表逐条带路径与行号，读数是实测不是推断；基线与 `git status` 一起留档 |
| 判据 | 导出面准入放开对象块名，形参与返回都成立；字段位、泛型、`^T` 载荷位仍拒 | 正例两条、负例逐条对码；未放行类型的一条都不许漏过 `check` |
| 载体 | 运行时段新增句柄箱族，与字符串句柄同构；符号名、份额归属、空句柄行为先写进台账再落实现 | `tools/runtime-abi-check.py` 的等式绿；空句柄不陷阱；句柄箱不暴露名义箱地址 |
| 归位 | 导出转发体插 retain、建句柄、取箱；归还走类型专属释放胶水 | 一条 C 调用方跑「建对象 → 传回 Pini 改字段 → 再读 → 归还」全链；归还后无残留计数 |
| 头文件 | 发不透明类型与入口声明，不发结构体定义、不发布局断言 | 头文件里搜不到 `offsetof` 与字段拼写；未用句柄的库头文件与基线逐字相同 |
| 诊断 | 对象写进给定块字段、写进 `[..|foreign]`、以及解释器通道碰到句柄的提醒 | 码值取落地时 `Sources/PiniSemantics/Resources/Diagnostics.zh.toml` 的下一个空位，两份语言件同号 |
| 台账 | 订正 109 与 119、更新零调用点登记与互补关系，补冻结条款 | `tools/runtime-abi-check.py` 与 `tools/builtin-inventory-check.py` 双绿；`tools/check-doc-links.sh` 绿 |
| 回归 | C 调用方 `cc caller.c -l<库>` 端到端；`examples/golden` 与全量测试 | 全量测试数以**证据**片留档的基线为准，只许不减；`build --shared` 在 Darwin 与 Linux 各跑一条 |
| 收口 | 补 `docs/spec/c-interop-design.md` 与 `docs/spec/pini-reference.md`；按 `GIT_WORKFLOW.md` 走特性分支与提交类型 | `hooks/pre-commit` 的注释门禁、格式门禁、文档链接门禁三条都过 |

判据先落：载体、归位、头文件三片都要读同一个句柄形状，形状没定就各自猜。证据片与判据片互不依赖，可并行。回归片最后收。

## 诊断

| 情形 | 码位 | 要点 |
|---|---|---|
| 对象类型写在给定块的导出字段位 | 新 | 字段区是布局直连，句柄没有可落的形状；指回 `|c` 函数条目 |
| 对象类型写在 `[..|foreign]` 的符号位 | 新 | 导入面不在本计划范围，文案给「改成导出函数形参」这条出路 |
| `^T` 载荷位写对象类型 | 新 | 结果降级走标量出参，载荷没有 C 形状 |
| 句柄出现在非 `|c` 上下文 | 沿用 `E4-035` 的写法，另取新码 | 与 `StringHandle` 同规，但对象句柄没有语言级类型名，触发点是导出条目而非类型标注 |

码值一律以落地时 `Sources/PiniSemantics/Resources/Diagnostics.zh.toml` 与 `Sources/PiniSemantics/Resources/Diagnostics.en.toml` 的下一个空位为准；现表最大是 E4-035、E5-020、E7-007。文案要把「为什么不行」与「该怎么写」一起给，不写「不支持」了事。

## 风险

| 风险 | 说明 | 处置 |
|---|---|---|
| 计数的原子性 | `bk_nominal_retain` 是非原子的 `+= 1`（`Sources/PiniRuntime/PiniRuntime.swift:2178`），C 多线程同时 retain 会数据竞争；`docs/spec/pini-reference.md`:2057-2062 只承诺单任务非原子、跨任务原子 | 句柄箱自己的计数用原子操作；名义箱那一次 retain 落在转发桩内单线程路径。C 跨线程共享句柄前须自己 retain 一次，头文件注释写清 |
| 跨库句柄误用 | C 把甲库的句柄交给乙库的归还入口，释放胶水地址来自甲库，乙库无从校验 | 句柄箱记生成它的库的标识，归还入口不匹配即 `bk_panic`；不静默忽略，静默会让泄漏变成难查的悬空 |
| 延迟释放队列 | `docs/spec/pini-reference.md`:2055 要求计数归零时入队迭代释放，避免析构风暴；发射层胶水当前是同步逐字段 sweep（`Sources/PiniBackendLLVM/CodeGen/IREmitter.swift:4104-4123`） | 开工前先核这一条是否已有队列接线；若没有，列为**证据**片的探针，不擅自改变既有释放时序 |
| 弱引用与旁表 | C 只持强份额，不参与弱引用；旁表由最后一个弱引用撤销时释放 | C 侧不提供弱句柄，头文件写明句柄是强份额；不把旁表指针外借 |
| 泄漏 | C 不调归还入口就泄漏，编译器查不到 | 与字符串句柄同规，头文件注释与 `docs/spec/c-interop-design.md` 的生命周期节并列写 |
| 符号撞名 | 无隐式前缀，短名字与别的库撞 | 句柄入口带 `bk_` 前缀走运行时台账，`<块>_*` 沿用 `docs/spec/c-interop-design.md`:616 的命名建议 |
| 台账读数漂移 | 109 与 119、99 与 97 这几处旧读数会让新增族的对账失去基准 | **台账**片一次订正，不分散到各片顺手改 |
| 文档引用失准 | `tools/check-doc-links.sh` 校验反引号里的 `.md` 与 `.toml` 引用，裸 basename 会被判「路径过时」 | 本件一律写仓根相对路径；改 `docs/spec/c-interop-design.md` 时同样遵守 |

## 尚未定

**载体选型**（唯一需要点头的一项）。建议形状是句柄箱：不碰 `docs/spec/c-interop-design.md`:530 的禁令，C 拿不到名义箱地址，代价是新增一族 `bk_*` 符号、`docs/spec/runtime-abi.md` 台账与冻结流程、`tools/builtin-inventory-check.py` 的互补表，涉及四个文件加两份文档。备选是箱指针直出：C 直接拿 `%object.<名字>*`，省掉整族符号，但要把 `docs/spec/c-interop-design.md`:530 与 `docs/spec/pini-reference.md`:2712-2713 一起修订为「不得交出未经 retain 的地址」，并把归还做成库级 `<块>_release` 按类型分派，语言级变更流程与符号冻结两样都躲不掉。两版都不破三通道一致性；建议取句柄箱，理由是它把「对象布局」与「C 面契约」彻底解耦，正是**稳定边界**要的东西。若改选箱指针直出，**载体**与**归位**两片要重写，**台账**片反而变轻。

**导入面是否放行**。本计划按上承文档的单向假设定稿：`[..|foreign]` 里不认对象类型，C 只能把句柄传回 `|c` 导出函数。要放开就得在 `Sources/PiniSemantics/Common/FFIType.swift` 补一支，并处理解释器通道缺 `bk_*` 符号的限制——那是一片独立工作，不是本计划的收尾。

**句柄入口的粒度**。建议只发 retain / release / 取箱三个，不发按字段访问器：`docs/spec/c-interop-design.md`:427 否决访问器的理由是 API 面小，句柄路线里字段名一旦进符号就等于把结构信息换一种形式冻住。字段读写交给作者自己导出的 Pini 函数。

**首版不做**：弱句柄、跨库句柄互认、对象作为 `^T` 载荷、泛型对象块的特化导出、C 侧构造对象。这几项都不是技术做不到，是会各自带出一份新的冻结契约，等首版的符号面跑稳再逐条评估。
