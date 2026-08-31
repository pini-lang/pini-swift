import Foundation

// 完整 CPS 化（ADR-009 / B-2 完整版）：把「语句游标重跑」模型升级为闭包即续体的可恢复求值器。
//
// 核心思想：
// - 挂起点只有 `.join`（由 `await`/`wait` 关键字前缀产生，ADR-012）。`evalK` 对含 `.join` 的表达式做 CPS 组合（闭包捕获剩余计算），
// 无 `.join` 的子树直接复用现有同步 `evaluateExpression`（快速路径，语义与同步路径逐字节一致）。
// - `.join` 遇未决 Future：把当前续体存入 `SuspendTaskCPS.cursorCont`，登记 `whenResolved` 后**返回**
// （释放 OS 线程）；Future resolve 后经 `SuspendScheduler` 重新进入 driver，还原上下文、执行续体。
// - 调用链：用户同步函数体含 `.join` 时，`callUserFunctionK` 以 CPS 执行其体（return 信号按帧捕获），
// 因此 `outer → inner` 链上任意深度的 `await`/`wait` 都能精确恢复，不重跑任何已执行语句/子表达式（副作用零重复）。
// - 上下文（(3) MUST 五项）：driver 每次进入还原 `{currentEnv, currentFuture, deferStack,
// debugDepth, callStackNames}`，退出时快照回 task；`currentEnv` 快照的是**挂起点 innermost env**
// （每次 callUserFunctionK 的完成续体会把 env 还原回调用方），resume 精确回到挂起点帧。
//
// 探针边界：match/try/泛型构造内的 `await`/`wait`、for 迭代式内的 `await`/`wait`、labeled 实参重排 报「挂起模式暂不支持」；
// 严格控制不静默出错（containsJoin 保守扫描，命中未支持构造即显式抛错）。

extension Interpreter {

 // MARK: - containsJoin 静态扫描（判定子树是否含 `.join`）

 func containsJoin(_ expr: Expression) -> Bool {
 switch expr {
 case .join: return true
 case .binary(let l, _, let r, _): return containsJoin(l) || containsJoin(r)
 case .unary(_, let o, _): return containsJoin(o)
 case .call(let c, let args, _): return containsJoin(c) || args.contains { containsJoin($0.expression) }
 case .member(let o, _, _): return containsJoin(o)
 case .tupleIndex(let o, _, _): return containsJoin(o)
 case .resultUnwrap(let o, _): return containsJoin(o)
 case .subscript(let e, let i, _): return containsJoin(e) || containsJoin(i)
 case .tuple(_, let els, _): return els.contains { containsJoin($0) }
 case .arrayLiteral(let els, _): return els.contains { containsJoin($0) }
 case .setLiteral(let els, _): return els.contains { containsJoin($0) }
 case .dictionaryLiteral(let entries, _): return entries.contains { containsJoin($0.key) || containsJoin($0.value) }
 case .stringInterpolation(let segs, _): return segs.contains { seg in
 if case .expression(let e) = seg { return containsJoin(e) }
 return false
 }
 case .funcLiteral(let decl, _): return decl.body.map { containsJoin($0) } ?? false
 case .genericConstruct(_, _, let args, _): return args.contains { containsJoin($0.expression) }
 default: return false
 }
 }

 func containsJoin(_ stmt: Statement) -> Bool {
 switch stmt {
 case .varDecl(_, _, let initExpr, _, _): return initExpr.map { containsJoin($0) } ?? false
 case .varDestructure(_, _, let initExpr, _, _): return initExpr.map { containsJoin($0) } ?? false
 case .assign(let target, let value, _): return containsJoin(target) || containsJoin(value)
 case .returnStatement(let v, _): return v.map { containsJoin($0) } ?? false
 case .ifStatement(let c, let tb, let elifs, let eb, _, _):
 return containsJoin(c) || containsJoin(tb)
 || elifs.contains { containsJoin($0) }
 || eb.map { containsJoin($0) } ?? false
 case .whileStatement(let c, let b, let s, _, _):
 return containsJoin(c) || containsJoin(b) || s.map { containsJoin($0) } ?? false
 case .forStatement(_, let it, let b, let s, _, _):
 return containsJoin(it) || containsJoin(b) || s.map { containsJoin($0) } ?? false
 case .matchStatement(let v, let cases, _):
 return containsJoin(v) || cases.contains { containsJoin($0.block) }
 case .tryStatement(let e, let tb, let excepts, _):
 return containsJoin(e) || containsJoin(tb) || excepts.contains { containsJoin($0.body) }
 case .expressionStmt(let e, _): return containsJoin(e)
 case .detachStatement(let e, _): return containsJoin(e)
 case .deferStatement(let d, _): return containsJoin(d)
 case .scopedBlock(_, let body, _): return containsJoin(body)
 case .breakStatement, .continueStatement, .passStatement, .captureStatement: return false
 }
 }

 func containsJoin(_ block: Block) -> Bool {
 block.statements.contains { containsJoin($0) }
 }

 func containsJoin(_ target: AssignTarget) -> Bool {
 switch target {
 case .identifier: return false
 case .member(let o, _): return containsJoin(o)
 case .subscript(let e, let i): return containsJoin(e) || containsJoin(i)
 }
 }

 func containsJoin(_ elif: ElifBranch) -> Bool {
 containsJoin(elif.condition) || containsJoin(elif.block)
 }

 // MARK: - containsCall / maySuspend（调用感知：调用可能导向含 `await`/`wait`（.join）的函数体）

 /// 子树是否含任何 `.call`/`.genericConstruct` 节点。调用的**目标函数体**可能含 `.join`，
 /// 静态扫描无法解析标识符——因此「快速路径」（复用同步求值器）必须对调用保守：
 /// 含调用的子树一律走 CPS 派发（`dispatchCallK` 解析 callee 后决定 CPS 执行函数体或同步调用）。
 func containsCall(_ expr: Expression) -> Bool {
 switch expr {
 case .call, .genericConstruct: return true
 case .binary(let l, _, let r, _): return containsCall(l) || containsCall(r)
 case .unary(_, let o, _): return containsCall(o)
 case .member(let o, _, _): return containsCall(o)
 case .tupleIndex(let o, _, _): return containsCall(o)
 case .resultUnwrap(let o, _): return containsCall(o)
 case .subscript(let e, let i, _): return containsCall(e) || containsCall(i)
 case .tuple(_, let els, _): return els.contains { containsCall($0) }
 case .arrayLiteral(let els, _): return els.contains { containsCall($0) }
 case .setLiteral(let els, _): return els.contains { containsCall($0) }
 case .dictionaryLiteral(let entries, _): return entries.contains { containsCall($0.key) || containsCall($0.value) }
 case .stringInterpolation(let segs, _): return segs.contains { seg in
 if case .expression(let e) = seg { return containsCall(e) }
 return false
 }
 case .funcLiteral(let decl, _): return decl.body.map { containsCall($0) } ?? false
 case .join(let inner, _): return containsCall(inner)
 default: return false
 }
 }

 func containsCall(_ stmt: Statement) -> Bool {
 switch stmt {
 case .varDecl(_, _, let initExpr, _, _): return initExpr.map { containsCall($0) } ?? false
 case .varDestructure(_, _, let initExpr, _, _): return initExpr.map { containsCall($0) } ?? false
 case .assign(let target, let value, _): return containsCall(target) || containsCall(value)
 case .returnStatement(let v, _): return v.map { containsCall($0) } ?? false
 case .ifStatement(let c, let tb, let elifs, let eb, _, _):
 return containsCall(c) || containsCall(tb)
 || elifs.contains { containsCall($0) }
 || eb.map { containsCall($0) } ?? false
 case .whileStatement(let c, let b, let s, _, _):
 return containsCall(c) || containsCall(b) || s.map { containsCall($0) } ?? false
 case .forStatement(_, let it, let b, let s, _, _):
 return containsCall(it) || containsCall(b) || s.map { containsCall($0) } ?? false
 case .matchStatement(let v, let cases, _):
 return containsCall(v) || cases.contains { containsCall($0.block) }
 case .tryStatement(let e, let tb, let excepts, _):
 return containsCall(e) || containsCall(tb) || excepts.contains { containsCall($0.body) }
 case .expressionStmt(let e, _): return containsCall(e)
 case .detachStatement(let e, _): return containsCall(e)
 case .deferStatement(let d, _): return containsCall(d)
 case .scopedBlock(_, let body, _): return containsCall(body)
 case .breakStatement, .continueStatement, .passStatement, .captureStatement: return false
 }
 }

 func containsCall(_ block: Block) -> Bool {
 block.statements.contains { containsCall($0) }
 }

 func containsCall(_ target: AssignTarget) -> Bool {
 switch target {
 case .identifier: return false
 case .member(let o, _): return containsCall(o)
 case .subscript(let e, let i): return containsCall(e) || containsCall(i)
 }
 }

 func containsCall(_ elif: ElifBranch) -> Bool {
 containsCall(elif.condition) || containsCall(elif.block)
 }

 /// 快速路径闸门：子树含 `.join` **或** 任何调用（可能导向含 `await`/`wait`（.join）的函数体）→ 必须走 CPS。
 private func maySuspend(_ expr: Expression) -> Bool { containsJoin(expr) || containsCall(expr) }
 private func maySuspend(_ stmt: Statement) -> Bool { containsJoin(stmt) || containsCall(stmt) }

 // MARK: - 挂起任务状态（闭包即续体）

 /// CPS 挂起任务：`cursorCont` 是「下一次要执行的续体」（挂起点之后的一切）。
 final class SuspendTaskCPS {
 let future: FutureValue
 let fv: FunctionValue
 let args: [Value]
 let callEnv: Environment
 /// 挂起后的续体（nil = 首次运行）。续体可能再次挂起（重设 cursorCont 并返回）。
 var cursorCont: (() throws -> Void)? = nil
 /// resume 时还原的 env：挂起点的 innermost env（非 callEnv——调用帧可嵌套）。
 var savedEnv: Environment?
 var deferStack: [[Statement]] = []
 var debugDepth: Int = 0
 var callStackNames: [String] = []
 /// 调用帧返回处理栈：`callUserFunctionK` 进入时压入、正常完成/return 时弹出。
 /// 原生帧会在挂起时展开（unwind），**return 边界必须随续体持久**——否则 inner 的
 /// return 信号在 resume 后无人按帧捕获，会被 driver 误当外层任务体 return。
 struct ReturnFrame {
 let cont: (Value) throws -> Void
 let savedEnv: Environment
 }
 var returnStack: [ReturnFrame] = []
 /// 循环控制帧栈：`break`/`continue` 信号在挂起后原生帧已展开，须按此栈路由到最近的
 /// 匹配循环帧（与 returnStack 同理；break/continue 发生于 resume 时无原生 catch 可依）。
 struct LoopControl {
 let label: String?
 let onBreak: () throws -> Void
 let onContinue: () throws -> Void
 }
 var loopStack: [LoopControl] = []

 init(future: FutureValue, fv: FunctionValue, args: [Value], callEnv: Environment) {
 self.future = future
 self.fv = fv
 self.args = args
 self.callEnv = callEnv
 }
 }

 // MARK: - driver（每次进入 = 首次运行或 resume）

 /// 完整 CPS 化挂起任务执行器。每次进入还原五项上下文（(3) MUST），
 /// 运行续体（或首次从语句 0 驱动），退出时快照上下文回 task 并还原「进入前」。
 func runSuspendableBodyCPS(future: FutureValue, fv: FunctionValue, args: [Value]) throws -> Value {
 let key = ObjectIdentifier(future)
 // B-3 双续体防护：cancel 与 resolve 竞态下先到者终结、后到者空跑。
 if future.isFinished { return .null }

 let task: SuspendTaskCPS
 let firstRun: Bool
 suspendTaskLock.lock()
 if let t = cpsTasks[key] {
 task = t
 firstRun = false
 } else {
 let callEnv = Environment(enclosing: fv.closure)
 for (i, p) in fv.params.enumerated() {
 callEnv.define(name: p.name, value: args[i], isMutable: true)
 }
 let t = SuspendTaskCPS(future: future, fv: fv, args: args, callEnv: callEnv)
 t.deferStack = [[]] // 函数体级 defer scope（终结时 pop 执行 defer）
 cpsTasks[key] = t
 task = t
 firstRun = true
 // B-3：本任务一旦被取消，立即唤醒 resume（即使等待的 future 永不 resolve / 不在取消树内）。
 future.onCancel { [weak self] in
 self?.scheduler.spawn(future) { [weak self] in
 try self?.runSuspendableBodyCPS(future: future, fv: fv, args: args)
 return .null
 }
 }
 }
 suspendTaskLock.unlock()

 // 还原五项上下文；env 用挂起点的 savedEnv（首次用 callEnv）。
 let prevEnv = currentEnv
 let prevFuture = currentFuture
 let prevDeferStack = deferStack
 let prevDebugDepth = debugDepth
 let prevCallStack = callStackNames
 currentEnv = task.savedEnv ?? task.callEnv
 currentFuture = future
 deferStack = task.deferStack
 debugDepth = task.debugDepth
 callStackNames = task.callStackNames
 defer {
 // 把任务最新上下文快照回 task（挂起/完成时线程被释放，下次 resume 从这里还原）。
 task.savedEnv = currentEnv
 task.deferStack = deferStack
 task.debugDepth = debugDepth
 task.callStackNames = callStackNames
 // 还原进入前上下文（线程永不被本任务污染）。
 currentEnv = prevEnv
 currentFuture = prevFuture
 deferStack = prevDeferStack
 debugDepth = prevDebugDepth
 callStackNames = prevCallStack
 }

 do {
 try checkCancellation()
 if firstRun {
 try execBlockK(task, task.fv.body?.statements ?? [], 0, .null) { result in
 try self.finalizeSuspendResult(task, result)
 }
 } else if let c = task.cursorCont {
 task.cursorCont = nil
 try c()
 }
 return .null
 } catch let signal as ControlSignal {
 // 统一控制流路由循环：return / break / continue 可能相互嵌套触发（如 break 处理器的
 // cont 里又遇 return），逐个信号循环处理，绝不逃逸出 driver（否则被调度器吞掉 → 挂起）。
 var sig = signal
 while true {
 // 1) return：沿 returnStack 逐帧路由（每帧 cont 可能再抛任何 ControlSignal）。
 if case .returnSignal(let v) = sig {
 var retVal = v
 var reentered = false
 while let frame = task.returnStack.last {
 task.returnStack.removeLast()
 try? popDeferScope() // 弹返回帧的 defer scope（执行其 defer）
 currentEnv = frame.savedEnv // 还原调用方 env（帧完成路径语义）
 do {
 try frame.cont(retVal ?? .null)
 return .null
 } catch let next as ControlSignal {
 if case .returnSignal(let v2) = next {
 retVal = v2
 continue
 }
 sig = next
 reentered = true
 break // 非 return 信号 → 回外层循环处理 break/continue
 }
 }
 if reentered { continue }
 // 任务体自身 return：收口。
 try finalizeSuspendResult(task, retVal ?? .null)
 return .null
 }
 // 2) break / continue：按 loopStack 路由（无标签匹配最近帧；带标签沿栈向上找匹配帧，
 // 越过的内层帧随之弹出——它们被该控制流越过）。
 guard let frame = task.loopStack.last else { throw sig }
 let match: Bool
 switch sig {
 case .breakSignal(let l): match = (l == nil) ? true : (l == frame.label)
 case .continueSignal(let l): match = (l == nil) ? true : (l == frame.label)
 default: match = false
 }
 if match {
 do {
 if case .breakSignal = sig {
 try frame.onBreak()
 } else {
 try frame.onContinue()
 }
 return .null
 } catch let next as ControlSignal {
 sig = next // 处理器内又抛控制信号（如 cont 里的 return）→ 重新路由
 continue
 }
 }
 task.loopStack.removeLast()
 }
 } catch let e as SuspendSignal {
 // 理论不可达（evalK 内部处理挂起）；兜底：视为挂起，登记续体重试。
 e.future.whenResolved { [weak self] _ in
 self?.scheduler.spawn(future) { [weak self] in
 try self?.runSuspendableBodyCPS(future: future, fv: fv, args: args)
 return .null
 }
 }
 return .null
 } catch {
 try? popDeferScope()
 suspendTaskLock.lock(); cpsTasks[key] = nil; suspendTaskLock.unlock()
 future.closeScope()
 future.reject(Interpreter.coerceRuntimeError(error))
 return .null
 }
 }

 /// 任务完成收口：pop 函数体级 defer → 单一 scope 收口（closeScope+flipIfLeaked）→ resolve。
 private func finalizeSuspendResult(_ task: SuspendTaskCPS, _ result: Value) throws {
 try? popDeferScope()
 let key = ObjectIdentifier(task.future)
 suspendTaskLock.lock(); cpsTasks[key] = nil; suspendTaskLock.unlock()
 let leaked = task.future.closeScope()
 task.future.resolve(flipIfLeaked(result, leaked: leaked))
 }

 // MARK: - 表达式级 CPS（闭包即续体）

 private typealias EvalK = (Value) throws -> Void

 private func evalK(_ task: SuspendTaskCPS, _ expr: Expression, _ cont: @escaping EvalK) throws {
 // 无挂起风险（无 `.join` 且无调用——调用可能导向含 `await`/`wait`（.join）的函数体）→ 直接复用现有同步
 // 求值器（语义逐字节一致，零重复实现）。
 if !maySuspend(expr) {
 try cont(try evaluateExpression(expr))
 return
 }
 switch expr {
 case .join(let inner, let loc):
 try evalK(task, inner) { v in
 guard case .future(let fut) = v else {
 throw RuntimeError.invalidOperation(
 reason: "`await`/`wait` 仅接受 Future 值（挂起模式 CPS）",
 location: loc
 )
 }
 if self.suspendMode && !fut.isFinished {
 // 真正挂起：保存续体（精确恢复点）、登记唤醒、释放 OS 线程。
 task.cursorCont = { try cont(self.joinFuture(fut)) }
 fut.whenResolved { [weak self] _ in
 self?.scheduler.spawn(task.future) { [weak self] in
 try self?.runSuspendableBodyCPS(future: task.future, fv: task.fv, args: task.args)
 return .null
 }
 }
 } else {
 try cont(self.joinFuture(fut))
 }
 }
 case .binary(let l, let op, let r, _):
 try evalK(task, l) { lv in
 try self.evalK(task, r) { rv in
 try cont(try self.evaluateBinaryOp(lv, op, rv))
 }
 }
 case .unary(let op, let operand, _):
 try evalK(task, operand) { v in
 try cont(try self.evaluateUnaryOp(op, v))
 }
 case .call(let callee, let arguments, let loc):
 try evalK(task, callee) { cval in
 try self.evalArgsK(task, arguments, 0, []) { argVals in
 try self.dispatchCallK(task, cval, argVals, arguments, loc, cont)
 }
 }
 case .member(let object, let name, let loc):
 try evalK(task, object) { ov in
 try cont(try self.evaluateMember(ov, memberName: name, location: loc))
 }
 case .tupleIndex(let object, let index, let loc):
 // 草稿 A2（批次 1）：先 CPS 求值 object（可能含 `await`/`wait` 挂起），再取元组元素。
 try evalK(task, object) { ov in
 try cont(try self.evaluateTupleIndex(ov, index: index, location: loc))
 }
 case .resultUnwrap(let operand, let loc):
 // 草稿 A2（批次 1.4，D2）：`^` 解包进入 CPS 仅当 operand 含挂起/调用；
 // 含 `await`/`wait` 的组合暂不支持（探针边界，与泛型构造一致）；否则同步求值（无挂起则结果相同）。
 if containsJoin(operand) {
 throw RuntimeError.invalidOperation(
 reason: "挂起模式暂不支持 `^` 解包内含有 `await`/`wait`",
 location: loc
 )
 }
 try cont(try evaluateExpression(expr))
 case .subscript(let containerExpr, let indexExpr, let loc):
 try evalK(task, containerExpr) { cv in
 try self.evalK(task, indexExpr) { iv in
 try cont(try SubscriptReadStrategy.read(container: cv, index: iv, location: loc))
 }
 }
 case .tuple(let labels, let elements, _):
 // 草稿 A2（批次 1.3，D1）：命名元组字面量把标签传入运行时值。
 try evalElementsK(task, elements, 0, []) { vs in try cont(.tuple(labels: labels, elements: vs)) }
 case .arrayLiteral(let elements, _):
 try evalElementsK(task, elements, 0, []) { vs in try cont(.array(vs)) }
 case .setLiteral(let elements, _):
 try evalElementsK(task, elements, 0, []) { vs in try cont(.set(vs)) }
 case .dictionaryLiteral(let entries, _):
 try evalDictEntriesK(task, entries, []) { pairs in try cont(.dictionary(pairs)) }
 case .stringInterpolation(let segments, _):
 try evalSegmentsK(task, segments, "") { s in try cont(.string(s)) }
 case .funcLiteral(let decl, _):
 // 构造函数值是同步动作（body 只是存储；其内 `await`/`wait` 在调用时经 callUserFunctionK 处理）。
 let fv = FunctionValue(
 name: decl.name, params: decl.params, returnTypes: decl.returnTypes,
 body: decl.body, decl: decl, closure: currentEnv
 )
 try cont(.function(fv))
 case .genericConstruct:
 // 实参含 `.join` → 探针边界显式报错；否则（仅因含调用而进入 CPS）同步求值。
 if containsJoin(expr) {
 throw RuntimeError.invalidOperation(
 reason: "挂起模式暂不支持泛型构造实参内的 `await`/`wait`",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 try cont(try evaluateExpression(expr))
 default:
 // containsJoin 为 false 的节点不会走到这（已在快速路径同步求值）；兜底。
 try cont(try evaluateExpression(expr))
 }
 }

 private func evalArgsK(_ task: SuspendTaskCPS, _ args: [CallArgument], _ index: Int, _ acc: [Value], _ cont: @escaping ([Value]) throws -> Void) throws {
 if index >= args.count { try cont(acc); return }
 try evalK(task, args[index].expression) { v in
 try self.evalArgsK(task, args, index + 1, acc + [v], cont)
 }
 }

 private func evalElementsK(_ task: SuspendTaskCPS, _ els: [Expression], _ index: Int, _ acc: [Value], _ cont: @escaping ([Value]) throws -> Void) throws {
 if index >= els.count { try cont(acc); return }
 try evalK(task, els[index]) { v in
 try self.evalElementsK(task, els, index + 1, acc + [v], cont)
 }
 }

 private func evalDictEntriesK(_ task: SuspendTaskCPS, _ entries: [DictEntry], _ acc: [(Value, Value)], _ cont: @escaping ([(Value, Value)]) throws -> Void) throws {
 if entries.isEmpty { try cont(acc); return }
 let e = entries[0]
 try evalK(task, e.key) { kv in
 try self.evalK(task, e.value) { vv in
 try self.evalDictEntriesK(task, Array(entries.dropFirst()), acc + [(kv, vv)], cont)
 }
 }
 }

 private func evalSegmentsK(_ task: SuspendTaskCPS, _ segments: [InterpolationSegment], _ acc: String, _ cont: @escaping (String) throws -> Void) throws {
 if segments.isEmpty { try cont(acc); return }
 let seg = segments[0]
 switch seg {
 case .literal(let s):
 try self.evalSegmentsK(task, Array(segments.dropFirst()), acc + s, cont)
 case .expression(let e):
 try evalK(task, e) { v in
 try self.evalSegmentsK(task, Array(segments.dropFirst()), acc + self.stringify(v), cont)
 }
 }
 }

 // MARK: - 调用派发（调用链挂起）

 private func dispatchCallK(_ task: SuspendTaskCPS, _ cval: Value, _ argVals: [Value], _ arguments: [CallArgument], _ loc: SourceLocation, _ cont: @escaping EvalK) throws {
 guard case .function(let fv) = cval else {
 throw RuntimeError.notCallable(location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 // labeled 实参重排（与 evaluateExpression .call 的 hasLabeledArgs 逻辑一致，探针边界已收窄）。
 var finalArgs = argVals
 if arguments.contains(where: { $0.label != nil }) {
 var ordered: [Value] = Array(repeating: .null, count: fv.params.count)
 for (i, arg) in arguments.enumerated() {
 if let label = arg.label {
 guard let idx = fv.params.firstIndex(where: { $0.name == label }) else {
 throw RuntimeError.invalidOperation(reason: "未知参数名: \(label)", location: loc)
 }
 ordered[idx] = argVals[i]
 } else if i < ordered.count {
 ordered[i] = argVals[i]
 }
 }
 finalArgs = ordered
 }
 // 用户同步函数且函数体含 `await`/`wait`（.join） → CPS 执行其体（调用链任意深度挂起可精确恢复）。
 // 内建（body == nil）、异步（走 spawn）、类型/枚举构造（body == nil）均走既有 callFunctionValue。
 if let body = fv.body, containsJoin(body), !fv.isAsync {
 try callUserFunctionK(task, fv, finalArgs, cont)
 return
 }
 try cont(try callFunctionValue(fv, args: finalArgs))
 }

 /// CPS 执行用户同步函数体：建 callEnv → 压入 return 帧 → execBlockK 驱动。
 /// return 信号经 driver 按 returnStack 路由到本帧（挂起后原生帧已展开，靠栈持久）；
 /// 正常完成（块自然结束）时弹帧 + 还原 env + 把结果喂给调用方 cont。
 private func callUserFunctionK(_ task: SuspendTaskCPS, _ fv: FunctionValue, _ args: [Value], _ cont: @escaping EvalK) throws {
 let callEnv = Environment(enclosing: fv.closure)
 for (i, p) in fv.params.enumerated() {
 callEnv.define(name: p.name, value: args[i], isMutable: true)
 }
 let savedEnv = currentEnv
 currentEnv = callEnv
 pushDeferScope()
 task.returnStack.append(.init(cont: cont, savedEnv: savedEnv))
 try execBlockK(task, fv.body?.statements ?? [], 0, .null) { result in
 // 正常完成：弹本帧 + 弹 defer scope + 还原 env + 喂结果给调用方。
 task.returnStack.removeLast()
 try? self.popDeferScope()
 self.currentEnv = savedEnv
 try cont(result)
 }
 }

 // MARK: - 语句级 CPS

 private func execBlockK(_ task: SuspendTaskCPS, _ stmts: [Statement], _ index: Int, _ lastValue: Value, _ cont: @escaping EvalK) throws {
 if index >= stmts.count {
 try cont(lastValue)
 return
 }
 let stmt = stmts[index]
 if !maySuspend(stmt) {
 // 无挂起风险 → 同步执行整条语句（与 executeFunctionBody 语义一致）。
 if case .expressionStmt(let expr, _) = stmt {
 let v = try runExpressionStatement(expr)
 try execBlockK(task, stmts, index + 1, v, cont)
 } else {
 try executeStatement(stmt)
 try execBlockK(task, stmts, index + 1, lastValue, cont)
 }
 return
 }
 try execStmtK(task, stmt) { v in
 try self.execBlockK(task, stmts, index + 1, v, cont)
 }
 }

 private func execStmtK(_ task: SuspendTaskCPS, _ stmt: Statement, _ cont: @escaping EvalK) throws {
 switch stmt {
 case .varDecl(let name, _, let initializer, let isMutable, _):
 if let initExpr = initializer {
 try evalK(task, initExpr) { v in
 self.currentEnv.define(name: name, value: self.copyIfStruct(v), isMutable: isMutable)
 try cont(.null)
 }
 } else {
 currentEnv.define(name: name, value: .null, isMutable: isMutable)
 try cont(.null)
 }
 case .varDestructure(let names, _, let initializer, let isMutable, let location):
 // 草稿 A1（批次 1）：CPS 求值右值元组后逐分量绑定（`_` 占位跳过）。
 guard let initExpr = initializer else {
 throw RuntimeError.invalidOperation(reason: "解构声明缺少初始值", location: location)
 }
 try evalK(task, initExpr) { v in
 guard case .tuple(_, let elements) = v else {
 throw RuntimeError.typeMismatch(
 expected: "tuple",
 got: self.describeValueKind(v),
 location: location
 )
 }
 guard names.count == elements.count else {
 throw RuntimeError.invalidOperation(
 reason: "解构分量数不匹配：声明 \(names.count) 个，元组 \(elements.count) 个",
 location: location
 )
 }
 for (i, name) in names.enumerated() where name != "_" {
 try self.currentEnv.define(name: name, value: self.copyIfStruct(elements[i]), isMutable: isMutable)
 }
 try cont(.null)
 }
 case .expressionStmt(let expr, _):
 try evalK(task, expr) { v in try cont(v) }
 case .detachStatement(let expr, let detachLoc):
 // 任务 #13：CPS 路径同样支持 `detach <expr>`——求值后剪枝（fire-and-forget）。
 try evalK(task, expr) { v in
 guard case .future(let fut) = v else {
 throw RuntimeError.typeMismatch(
 expected: "Future<T, Error>",
 got: self.describeValueKind(v),
 location: detachLoc
 )
 }
 fut.detachFromParent()
 try cont(.null)
 }
 case .returnStatement(let value, _):
 if let v = value {
 try evalK(task, v) { rv in throw ControlSignal.returnSignal(rv) }
 } else {
 throw ControlSignal.returnSignal(nil)
 }
 case .assign(let target, let value, let location):
 if containsJoin(target) {
 throw RuntimeError.invalidOperation(
 reason: "挂起模式暂不支持赋值目标内的 `await`/`wait`",
 location: location
 )
 }
 switch target {
 case .identifier(let name):
 try evalK(task, value) { v in
 try self.currentEnv.assign(name: name, value: self.copyIfStruct(v))
 try cont(.null)
 }
 case .member(let obj, let name):
 try evalK(task, value) { v in
 try self.evalK(task, obj) { ov in
 try self.performMemberAssign(objValue: ov, objExpr: obj, name: name, value: v, location: location)
 try cont(.null)
 }
 }
 case .subscript(let containerExpr, let indexExpr):
 try evalK(task, value) { v in
 let idx = try self.evaluateExpression(indexExpr)
 try self.writeSubscript(target: containerExpr, index: idx, newValue: v, location: location)
 try cont(.null)
 }
 }
 case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
 try evalK(task, condition) { cv in
 if try self.isTruthy(cv) {
 try self.execBlockK(task, thenBlock.statements, 0, .null, cont)
 } else {
 try self.evalIfBranchesK(task, elifs, elseBlock, cont)
 }
 }
 case .whileStatement(let condition, let body, let step, let label, _):
 // 压入整个 while 的循环帧（break→退出、continue→step+重估条件）；正常结束/break 时弹出。
 // 注意：continue **不**弹帧（帧跨迭代持久，直到 break 或条件为假退出）。
 let frame = SuspendTaskCPS.LoopControl(
 label: label,
 onBreak: {
 task.loopStack.removeLast()
 try cont(.null)
 },
 onContinue: {
 try self.execWhileContinueK(task, condition, body, step, label, cont)
 }
 )
 task.loopStack.append(frame)
 try evalWhileCondK(task, condition, body, step, label, cont)
 case .deferStatement(let dstmt, _):
 guard !deferStack.isEmpty else {
 throw RuntimeError.invalidOperation(
 reason: "defer 必须在块作用域内使用",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 deferStack[deferStack.count - 1].append(dstmt)
 try cont(.null)
 case .passStatement(_):
 try cont(.null)
 case .captureStatement:
 try cont(.null)
 case .forStatement(let pattern, let iterable, let body, let step, let label, let loc):
 // 迭代式先 CPS 求值（可含 `await`/`wait`（.join））；行展开同步（decomposePatternRow 复用），逐行 execBlockK。
 try evalK(task, iterable) { iterValue in
 try self.execForK(task, pattern: pattern, iterValue: iterValue, body: body, step: step, label: label, location: loc, cont)
 }
 case .matchStatement(let value, let cases, let loc):
 try evalK(task, value) { matchValue in
 try self.execMatchK(task, matchValue: matchValue, cases: cases, location: loc, cont)
 }
 case .tryStatement(let expression, let tryBlock, let exceptClauses, _):
 try evalK(task, expression) { result in
 try self.execTryK(task, result: result, tryBlock: tryBlock, exceptClauses: exceptClauses, cont)
 }
 default:
 // break/continue 无表达式（maySuspend=false → 走同步路径），不会到这儿；兜底显式报错。
 throw RuntimeError.invalidOperation(
 reason: "挂起模式暂不支持该语句构造内的 `await`/`wait`",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }

 // MARK: - for / match / try 的 CPS 版（探针边界收窄）

 /// for：迭代式已求值（可含挂起），行展开 + 逐行 body/step（可含挂起），break/continue 按标签捕获。
 private func execForK(_ task: SuspendTaskCPS, pattern: [String], iterValue: Value, body: Block, step: Block?, label: String?, location: SourceLocation, _ cont: @escaping EvalK) throws {
 var rows: [[Value]] = []
 switch iterValue {
 case .array(let els):
 rows = try els.map { try decomposePatternRow($0, patternCount: pattern.count, location: location) }
 case .set(let els):
 rows = try els.map { try decomposePatternRow($0, patternCount: pattern.count, location: location) }
 case .dictionary(let pairs):
 guard pattern.count == 2 else {
 throw RuntimeError.typeMismatch(expected: "字典迭代需 2 字段模式元组 (k, v)", got: "\(pattern.count) 字段", location: location)
 }
 rows = pairs.map { [$0.0, $0.1] }
 default:
 throw RuntimeError.typeMismatch(expected: "可迭代集合（数组/字典/集合）", got: "\(iterValue)", location: location)
 }
 try execForRowsK(task, rows, 0, pattern, body, step, label, cont)
 }

 private func execForRowsK(_ task: SuspendTaskCPS, _ rows: [[Value]], _ index: Int, _ pattern: [String], _ body: Block, _ step: Block?, _ label: String?, _ cont: @escaping EvalK) throws {
 if index >= rows.count { try cont(.null); return }
 let row = rows[index]
 let loopEnv = Environment(enclosing: currentEnv)
 for (idx, name) in pattern.enumerated() where name != "_" {
 loopEnv.define(name: name, value: row[idx], isMutable: true)
 }
 let savedEnv = currentEnv
 currentEnv = loopEnv
 // 本行压入循环帧：break→退出循环、continue→step+下一行（break/continue 经 driver 按 loopStack 路由）。
 let frame = SuspendTaskCPS.LoopControl(
 label: label,
 onBreak: {
 task.loopStack.removeLast()
 try cont(.null)
 },
 onContinue: {
 task.loopStack.removeLast()
 try self.execForStepK(task, rows, index, pattern, body, step, label, savedEnv: savedEnv, cont)
 }
 )
 task.loopStack.append(frame)
 try execBlockK(task, body.statements, 0, .null) { _ in
 task.loopStack.removeLast() // 正常完成：弹本行帧
 self.currentEnv = savedEnv // 迭代结束，还原外层 env
 try self.execForStepK(task, rows, index, pattern, body, step, label, savedEnv: savedEnv, cont)
 }
 }

 /// 迭代间 step（可选）→ 下一行。
 private func execForStepK(_ task: SuspendTaskCPS, _ rows: [[Value]], _ index: Int, _ pattern: [String], _ body: Block, _ step: Block?, _ label: String?, savedEnv: Environment, _ cont: @escaping EvalK) throws {
 if let step = step {
 try execBlockK(task, step.statements, 0, .null) { _ in
 try self.execForRowsK(task, rows, index + 1, pattern, body, step, label, cont)
 }
 } else {
 try execForRowsK(task, rows, index + 1, pattern, body, step, label, cont)
 }
 }

 /// match：value 已 CPS 求值；模式匹配同步（matchCaseMatches 复用）；命中 case 建 caseEnv 后 execBlockK。
 private func execMatchK(_ task: SuspendTaskCPS, matchValue: Value, cases: [MatchCase], location: SourceLocation, _ cont: @escaping EvalK) throws {
 for matchCase in cases {
 if matchCaseMatches(matchCase.pattern, matchValue) {
 let caseEnv = Environment(enclosing: currentEnv)
 if case .enumCase = matchCase.pattern, case .enumValue(let ev) = matchValue {
 for (bindingIndex, binding) in matchCase.bindings.enumerated() {
 let boundValue: Value
 if let paramName = binding.paramName {
 if let idx = ev.paramNames.firstIndex(where: { $0 == paramName }), idx < ev.associatedValues.count {
 boundValue = ev.associatedValues[idx]
 } else {
 boundValue = .null
 }
 } else {
 boundValue = bindingIndex < ev.associatedValues.count ? ev.associatedValues[bindingIndex] : .null
 }
 caseEnv.define(name: binding.varName, value: boundValue, isMutable: true)
 }
 }
 let savedEnv = currentEnv
 currentEnv = caseEnv
 try execBlockK(task, matchCase.block.statements, 0, .null) { _ in
 self.currentEnv = savedEnv
 try cont(.null)
 }
 return
 }
 }
 // D3①：case _: 已作为 wildcard case 进入 cases（循环自然兜底）；到达此处 = 无命中。
 if case .enumValue(let ev) = matchValue {
 throw RuntimeError.matchNotExhaustive(value: ev.caseName, location: location)
 }
 try cont(.null)
 }

 /// try：expression 已 CPS 求值；错误元组提取同步；成功 → tryBlock，错误 → 首个 except 子句。
 private func execTryK(_ task: SuspendTaskCPS, result: Value, tryBlock: Block, exceptClauses: [ExceptClause], _ cont: @escaping EvalK) throws {
 var errorValue: Value = .null
 var hasErrorTuple = false
 if case .tuple(_, let elements) = result, elements.count >= 2 {
 hasErrorTuple = true
 errorValue = elements[1]
 }
 if case .null = errorValue {
 try execBlockK(task, tryBlock.statements, 0, .null) { _ in try cont(.null) }
 return
 }
 if case .string(let s) = errorValue, s.isEmpty {
 try execBlockK(task, tryBlock.statements, 0, .null) { _ in try cont(.null) }
 return
 }
 if hasErrorTuple || !exceptClauses.isEmpty {
 if let clause = exceptClauses.first {
 let exceptEnv = Environment(enclosing: currentEnv)
 exceptEnv.define(name: clause.errorVar, value: errorValue, isMutable: true)
 let savedEnv = currentEnv
 currentEnv = exceptEnv
 try execBlockK(task, clause.body.statements, 0, .null) { _ in
 self.currentEnv = savedEnv
 try cont(.null)
 }
 return
 }
 }
 try cont(.null)
 }

 private func evalIfBranchesK(_ task: SuspendTaskCPS, _ elifs: [ElifBranch], _ elseBlock: Block?, _ cont: @escaping EvalK) throws {
 if elifs.isEmpty {
 if let eb = elseBlock {
 try execBlockK(task, eb.statements, 0, .null, cont)
 } else {
 try cont(.null)
 }
 return
 }
 let elif = elifs[0]
 try evalK(task, elif.condition) { cv in
 if try self.isTruthy(cv) {
 try self.execBlockK(task, elif.block.statements, 0, .null, cont)
 } else {
 try self.evalIfBranchesK(task, Array(elifs.dropFirst()), elseBlock, cont)
 }
 }
 }

 private func evalWhileCondK(_ task: SuspendTaskCPS, _ condition: Expression, _ body: Block, _ step: Block?, _ label: String?, _ cont: @escaping EvalK) throws {
 try evalK(task, condition) { cv in
 if try self.isTruthy(cv) {
 try self.execBlockK(task, body.statements, 0, .null) { _ in
 try self.execWhileContinueK(task, condition, body, step, label, cont)
 }
 } else {
 // 循环正常结束：弹 while 帧。
 task.loopStack.removeLast()
 try cont(.null)
 }
 }
 }

 /// while 的 step（可选）+ 重估条件（body 正常完成 / continue 共用）。
 private func execWhileContinueK(_ task: SuspendTaskCPS, _ condition: Expression, _ body: Block, _ step: Block?, _ label: String?, _ cont: @escaping EvalK) throws {
 if let step = step {
 try execBlockK(task, step.statements, 0, .null) { _ in
 try self.evalWhileCondK(task, condition, body, step, label, cont)
 }
 } else {
 try evalWhileCondK(task, condition, body, step, label, cont)
 }
 }

 private func isTruthy(_ v: Value) throws -> Bool {
 guard case .bool(let b) = v else {
 throw RuntimeError.typeMismatch(
 expected: "bool",
 got: "\(v)",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 return b
 }
}
