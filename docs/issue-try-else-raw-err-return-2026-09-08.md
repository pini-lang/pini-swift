# Issue：handler 内 `return err`（`^e` 糖 err 路径）返回裸错误载荷（类型洞）

- 状态：**Open（2026-09-08，M5 G1 差分 fixture 设计中由探针发现）**
- 发现渠道：G1 差分 fixture `testDiffTryElseSugar`——`(^String,)` 函数体内
  `let x = ^失败(标志)`（= `try 失败 else err: return err`）走 err 路径时，
  解释器从函数返回的是**裸 String 载荷**（`err` 绑定值 = payload 本身，
  `Interpreter.evaluateExpression` tryExpression 分支：`ev.associatedValues.first`），
  而非 `err(payload)` Result 值；下游 `try` 消费该函数返回值即报
  E5-003「expected Result, got String」。返回类型声明 `(^String,)` 对此**无静态拦截**。
- 语义两难（裁决后收敛）：
  - 解释器现状 = 裸载荷流出（返回位类型洞，静默）；
  - 「正确」形态应是 re-box 为 `err(e)`（与声明类型一致），但那是语言级语义
    变更，须走 spec §1.3 提议流程。
- LLVM 管线处置（本工单登记时同步落地）：HIRLowerer 对「bare error binding
  自 Result 返回位流出」**fail-loud 门控**（提示本缺陷），不做猜测性 re-box，
  避免双后端分歧。差分 fixture 因此只覆盖 `^e` 的 ok 路径。
- 排期：~~随 M5 收口提交裁决请求~~ ⇒ ⚠️ **2026-09-18 订正：该排期已过期** ——
  **M5 已收口**（`docs/issue-llvm-rewrite-plan-2026-09-07.md` 状态行：M5 分格扩张批 `G1`–`G15`
  全部完成并回填），而**裁决请求未见任何留档**。
  现状态 = **无主待裁**（§1.3 提议：re-box vs 维持裸载荷 + 声明位收紧）；裁决前解释器行为不动。
  ⚠️ 另实测：本单在 `docs/` + `tools/` + `hooks/` 的**入向引用 = 0 处**（在册件里最孤立的一份）
  ⇒ 处置时须**先定归属**再动手。
- 关联：`docs/issue-llvm-rewrite-plan-2026-09-07.md` M5 G1 批次回填；
  ADR-032（try-else 唯一原语）。
