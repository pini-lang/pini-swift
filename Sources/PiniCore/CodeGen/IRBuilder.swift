import Foundation

// MARK: - SSA 值（从 IRGenerator 提升为共享值类型）

/// LLVM IR 中的 SSA 值：类型 + 名字（`%tN` / 全局名 / 标签）。
/// #46-A 起作为 codegen 各层（IRGenerator 及未来的 Emitters）共享的值类型，
/// 取代原先散落在 IRGenerator 内的私有 `struct IRValue`。
public struct IRValue: Hashable, CustomStringConvertible {
 public let llvmType: String
 public let ssaName: String

 public init(llvmType: String, ssaName: String) {
 self.llvmType = llvmType
 self.ssaName = ssaName
 }

 public var description: String { "\(llvmType) \(ssaName)" }
}

// MARK: - IR 构建器（#46-A）

/// #46-A IR 构建器：集中所有「手写字符串 IR」的格式，消除 GEP-i8 字节偏移 / phi 误用 /
/// 类过早闭合类 typo（设计依据见 ADR-008）。
///
/// 设计要点：
/// - **不持有 IR 缓冲区**。调用方（IRGenerator）仍持有 `ir` 并以 `emitLine` 落盘；
/// 本构建器仅产出**字节级确定**的指令行字符串（与迁移前内联插值逐字符一致），
/// 保证现有 golden IR 零差异、回归被字节级门禁拦死。
/// - **temp/label 计数器由本构建器独占**，为全局唯一编号源；IRGenerator 经
/// `freshTemp` / `nextTemp`（Int 兼容） / `freshLabel` 取用，杜绝双计数源漂移。
/// - 字段 GEP 统一经 `fmtGEP`（强制 `i32 0, i32 N` 模式），与 `fmtGEPByteOffset`
/// （显式 `i8*` 指针算术）严格区分，从类型系统层面消除「字段偏移误用 i8 字节」类 bug。
public struct IRBuilder {

 private var tempCounter = 0
 private var labelCounter = 0

 public init() {}

 // MARK: - 命名（全局唯一编号源）

 /// 返回形如 `%t5` 的临时名并自增计数（迁移站点直接使用）。
 public mutating func freshTemp() -> String {
 tempCounter += 1
 return "%t\(tempCounter)"
 }

 /// 返回临时序号 Int（供遗留 `nextTemp()` 包装，保持 `"%t\(nextTemp())"` 调用形态）。
 public mutating func freshTempIndex() -> Int {
 tempCounter += 1
 return tempCounter
 }

 /// 返回标签序号 Int（供遗留 `nextLabel()` 包装）。
 public mutating func freshLabel() -> Int {
 labelCounter += 1
 return labelCounter
 }

 /// 重置编号（对齐迁移前 `tempCounter = 0` / `labelCounter = 0` 的逐函数/逐模块语义）。
 public mutating func reset() {
 tempCounter = 0
 labelCounter = 0
 }

 // MARK: - 指令格式（返回 padded 行，等价于迁移前 `emitLine(" " + ...)`）

 /// 字段/元素 GEP：集中 `i32 0, i32 N` 模式，杜绝 i8 字节偏移误用。
 public func fmtGEP(name: String, aggregate: String, base: String, indices: [Int]) -> String {
 let idxList = indices.map { "i32 \($0)" }.joined(separator: ", ")
 return " \(name) = getelementptr \(aggregate), ptr \(base), \(idxList)"
 }

 /// 字节偏移 GEP（仅用于 `i8*` 指针算术，如字符串切片）：显式偏移类型，与字段 GEP 区分。
 /// `offset` 为索引表达式文本（编译期常量 `5` 或运行时值名 `%t3` 皆可），原样拼入 `i64 <offset>`，
 /// 与迁移前 `getelementptr i8, ptr BASE, i64 \(idx)` 逐字符一致。
 public func fmtGEPByteOffset(name: String, base: String, offset: String, offsetType: String = "i64") -> String {
 " \(name) = getelementptr i8, ptr \(base), \(offsetType) \(offset)"
 }

 public func fmtAlloca(name: String, type: String) -> String {
 " \(name) = alloca \(type)"
 }

 public func fmtLoad(name: String, type: String, ptr: String) -> String {
 " \(name) = load \(type), ptr \(ptr)"
 }

 public func fmtStore(value: String, type: String, ptr: String) -> String {
 " store \(type) \(value), ptr \(ptr)"
 }

 // MARK: - 调用（#46-A 后续迁移 call 站点时使用；callee 含 @ / 函数指针，retType 含 vararg 签名）

 public func fmtCall(name: String, retType: String, callee: String, args: [(type: String, value: String)]) -> String {
 let argList = args.map { "\($0.type) \($0.value)" }.joined(separator: ", ")
 return " \(name) = call \(retType) \(callee)(\(argList))"
 }

 public func fmtCallVoid(callee: String, args: [(type: String, value: String)]) -> String {
 let argList = args.map { "\($0.type) \($0.value)" }.joined(separator: ", ")
 return " call void \(callee)(\(argList))"
 }

 // MARK: - 分支（标签目标均为命名标签，如 `if_cond_5`）

 public func fmtBr(labelName: String) -> String {
 " br label %\(labelName)"
 }

 public func fmtCondBr(cond: String, thenLabelName: String, elseLabelName: String) -> String {
 " br i1 \(cond), label %\(thenLabelName), label %\(elseLabelName)"
 }

 public func fmtLabelDef(_ name: String) -> String {
 "\(name):"
 }
}
