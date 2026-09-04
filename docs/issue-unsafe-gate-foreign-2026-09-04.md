# Issue: 安全上下文调用 foreign 函数无 unsafe 门禁（F5 缺陷立案，2026-09-04）

- **状态**：LANDED（2026-09-04 批 A 当批修复，见文末验收；原状态 Open）
- **来源**：`docs/spec/issue/archive/issue-draft-impl-syntax-audit-2026-08-28.md` F5（2026-08-31 审计复检发现）；该工单于 2026-09-04 内容收编后删除，本文件为其唯一活跃落点（用户裁决：单列独立缺陷工单）。
- **关联**：ADR-015（FFI Phase 2a：`unsafe <expr>` 消耗点 / `&` 取址门禁 / `|unsafe` 修饰符）、spec §2.7（FFI 与 unsafe）、spec §A.2.2（foreign-decl：**块内函数自动 `|unsafe`**）。

---

## 一、缺陷陈述

`[X|foreign]` 块内声明的函数按 spec §A.2.2 **自动视为 `|unsafe`**；按 ADR-015 的设计意图，不安全操作只应出现在 unsafe 上下文（`|unsafe` 函数体或 `unsafe <expr>` 消耗点）内。但**调用**这类 foreign 函数时，静态层与运行时均不强制任何 unsafe 上下文——安全代码（如 `main|func`）可以裸调 foreign 函数并拿到裸指针，绕过「最小不安全范围」原则。

## 二、实测复现（2026-09-04，探针在案）

```pini
package "f5probe"

[ffilib|foreign]
ffi_malloc(size: U64,) -> (*U8,)

main|func() -> ():
    let p = ffi_malloc(16)    ; 无 unsafe 消耗点，裸调
    print(p)
```

`pini run .` 结果：**正常执行**，输出 `*U8@0x00000001054877f0`——静态无报错、运行时无拦截。

## 三、门禁位点定位（代码级）

现行 unsafe 上下文门禁集中在 `Sources/PiniCore/Type/TypeChecker.swift` 的 `checkExpression`：

| 表达式位 | 门禁 | 现状 |
|---|---|---|
| `.addressOf`（`&` 取址） | `unsafeContextDepth > 0`，否则报错 | ✅ 已门禁 |
| `.unary(.forceUnwrap)`（`!`） | `unsafeContextDepth > 0`，否则报错 | ✅ 已门禁 |
| `.unsafe`（消耗点） | 进入时 `unsafeContextDepth += 1` | ✅ 语义正确 |
| **foreign 函数调用（`.call` 分派到 foreignDecl 符号）** | **无** | ❌ 本缺陷 |

修复方向（供排期参考，不在本工单裁决）：在调用解析确认被调符号为 foreignDecl（或具 `|unsafe` 修饰）时检查 `unsafeContextDepth`；注意与 ADR-028 D-4 裁决的相容性——「`unsafe` 许可是『允许』而非『要求』」，空消耗点无害通过；本缺陷是反向缺口（**该消耗而未消耗**），与 ADR-028 裁决正交。

## 四、影响面

- 解释器端（Phase 2a/2b）全量受影响；LLVM 端 FFI 显式 unsupported（ADR-015 D1），不受影响。
- 现有语料（examples/ffi_module、FFITests）均按安全封装模式书写（unsafe 内核 + 单消耗点），**未被本缺陷污染**；修复后预计无需大规模迁移，但须回归 `FFIModuleTests` 与 examples/ffi_module golden。

## 验收记录（2026-09-04 批 A）

- 门禁：`TypeChecker` 新增 `foreignFunctionNames`（foreignDecl 注册时并行登记）+ 调用位 `unsafeContextDepth == 0` 拦截，报错样式对齐 `&`/`!`（mismatch，E4-001）。
- spec §2.7 新增「foreign 调用门禁（F5）」钉定行（含与 ADR-028 D-4 正交性声明）。
- 迁移面：全仓实测仅 `examples/ffi_module/cstring.pini` 比较测试 1 行裸调 `ffi_strcmp` → 加 `unsafe` 消耗点（与该文件 §④ 注释自述的推荐写法一致）；`ffi.pini` 裸调全在 `|unsafe` 体内、不受影响（实测保持绿）。
- 实测：E-110 复现件（main 裸调 ffi_malloc）现报 E4-001；`pini test examples/ffi_module/cstring.pini` 2/2；`pini run examples/ffi.pini` 正常。
- 测试：testCheckForeignCallRequiresUnsafeContext（TypeCheckerTests）。
