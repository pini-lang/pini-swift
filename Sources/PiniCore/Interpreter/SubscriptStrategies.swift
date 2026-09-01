import Foundation

/// 下标读策略注册表（解释器侧）。
///
/// ## 架构演进 #45 的核心交付
/// 原 `Interpreter.evaluateSubscript` 用硬编码 `switch` 按容器运行时值类型
/// （array / string / dictionary）分派下标读。新增容器类型（如 set、自定义集合）
/// 需改动该 `switch` 且易穿透多文件分派、漂移分叉。
/// 现改为**按容器值类型注册的策略表**：新增类型只需 `register` 一条策略，
/// 分派逻辑零改动——这正是「语法/容器创新成本从穿透多文件收敛到单一注册点」的实证。
///
/// ## 与 LLVM 端的关系
/// LLVM 端下标分派维度不同（静态 IR 类型而非运行时值类型），在
/// `IRGenerator.generateSubscriptRead` 以类型化分派骨架承载。两端各自按自身维度
/// 注册，不强行统一抽象（避免过度耦合、反而不易演进）。
enum SubscriptReadStrategy {

 /// 容器运行时值分类（与 `Value` 下标相关 case 对齐，但不耦合具体 payload）。
 enum ContainerKind {
 case array, string, dictionary
 }

 /// 读策略签名：给定容器值、索引值、位置，返回元素值。
 typealias ReadStrategy = (Value, Value, SourceLocation) throws -> Value

 /// 注册表：键为容器分类，值为读策略。首次访问时初始化默认策略集。
 private static var registry: [ContainerKind: ReadStrategy] = {
 var r: [ContainerKind: ReadStrategy] = [:]

 r[.array] = { container, index, loc in
 guard case .array(let arr) = container, case .int(let i) = index else {
 throw RuntimeError.invalidOperation(reason: "数组下标需整数索引: \(container)[\(index)]", location: loc)
 }
 // P2-A：负索引尾部计数（i<0 → len+i；-1=末元素，-len=首元素）。
 let idx = i < 0 ? arr.count + i : i
 // 批 2（G48 三通道，proposal-subscript-safety-channels-2026-09-01）：`a[i]` 是
 // **安全断言通道**——返回元素本身（静态类型 `T`），越界 **panic**（E5-005）。
 // 与 LLVM 运行时 `@bk_array_get` 的既有行为一致（越界 `bk_panic`），此前解释器返回
 // Optional.none 造成双后端不一致（issue-host-optional-slice-2026-08-28）。
 // 容错需求走 `.get(i)`（返回 Optional），性能敏感且已证明界内走 `unsafe .getUnchecked(i)`。
 guard idx >= 0, idx < arr.count else {
 throw RuntimeError.indexOutOfRange(location: loc)
 }
 return arr[idx]
 }

 r[.string] = { container, index, loc in
 guard case .string(let s) = container, case .int(let i) = index else {
 throw RuntimeError.invalidOperation(reason: "字符串下标需整数索引: \(container)[\(index)]", location: loc)
 }
 // P2-A：负索引尾部计数（i<0 → len+i；-1=末元素，-len=首元素）。
 let idx = i < 0 ? s.count + i : i
 // 批 2（G48 三通道）：字符串下标同为安全断言通道——越界 panic（E5-005），界内返回字符。
 guard idx >= 0, idx < s.count else {
 throw RuntimeError.indexOutOfRange(location: loc)
 }
 let cidx = s.index(s.startIndex, offsetBy: idx)
 return .string(String(s[cidx]))
 }

 r[.dictionary] = { container, index, loc in
 guard case .dictionary(let entries) = container else {
 throw RuntimeError.invalidOperation(reason: "字典下标需字典容器: \(container)", location: loc)
 }
 // 批 2（G48 三通道）：字典缺失键与下标越界**同义**（D-5 裁决）——同走 panic（E5-005）。
 for (k, v) in entries {
 if k == index { return v }
 }
 throw RuntimeError.indexOutOfRange(location: loc)
 }

 return r
 }()

 /// 由运行时容器值推断分类；非下标容器返回 nil。
 static func kind(of value: Value) -> ContainerKind? {
 switch value {
 case .array: return .array
 case .string: return .string
 case .dictionary: return .dictionary
 default: return nil
 }
 }

 /// 执行下标读：查表分派，缺策略抛 unsupported。
 ///
 /// 批 2（G48 三通道）：下标读返回**元素值本身**（静态类型 `T`），越界/缺键抛
 /// `RuntimeError.indexOutOfRange`（E5-005）。旧行为为返回 Optional 枚举 some/none，
 /// 经 `!` 剥壳（须 unsafe 上下文）；现下标是「我断言存在」的通道，容错改走 `.get(i)`。
 /// 嵌套下标因此可直接连写：`m[0][1]`（旧写法 `unsafe m[0]![1]!` 已失效且 `!` 会报错）。
 static func read(container: Value, index: Value, location: SourceLocation) throws -> Value {
 guard let k = kind(of: container) else {
 throw RuntimeError.invalidOperation(reason: "不支持的下标容器类型: \(container)", location: location)
 }
 guard let strategy = registry[k] else {
 throw RuntimeError.invalidOperation(reason: "不支持的下标访问: \(container)[\(index)]", location: location)
 }
 return try strategy(container, index, location)
 }
}

/// 下标写策略注册表（解释器侧），与 `SubscriptReadStrategy` 对称（架构演进 #45 / #46-D D1.5）。
///
/// 与读策略的差别：写不需要容器「就地可变」，因为 Pini 数组/字典在解释器侧是**值语义**
/// （`Value.array` / `Value.dictionary` 为值），写操作返回**新的容器值**，由调用方重新绑定到
/// 变量 / 对象字段（与 `let a=[...]; a = [...]` 整体重赋值走同一条 `Environment.assign` 路径）。
/// 因此策略签名返回 `Value`（新容器），而非就地修改。
///
/// 当前仅数组支持下标写；字符串下标写因不可变语义暂不支持；字典下标写留待 D2 dict 后端时接入
/// （与 LLVM 端「仅数组下标写」保持双后端锁步）。
enum SubscriptWriteStrategy {

 /// 写策略签名：给定容器值、索引值、新元素值、位置，返回写后的新容器值。
 typealias WriteStrategy = (Value, Value, Value, SourceLocation) throws -> Value

 /// 注册表：键复用 `SubscriptReadStrategy.ContainerKind`（容器分类维度一致）。
 private static var registry: [SubscriptReadStrategy.ContainerKind: WriteStrategy] = {
 var r: [SubscriptReadStrategy.ContainerKind: WriteStrategy] = [:]

 r[.array] = { container, index, newValue, loc in
 guard case .array(var arr) = container, case .int(let i) = index else {
 throw RuntimeError.invalidOperation(reason: "数组下标写需整数索引: \(container)[\(index)]", location: loc)
 }
 // P2-A：负索引尾部计数（i<0 → len+i）。
 let idx = i < 0 ? arr.count + i : i
 // 写通道越界仍报错：不能经赋值越界扩容器（与 Python `a[5]=x` 越界 IndexError 一致）；
 // 读通道越界返回 nil（P2-C），读写不对称是有意设计（见 issue-lexer-gaps P2-C 论证）。
 guard idx >= 0, idx < arr.count else {
 throw RuntimeError.invalidOperation(reason: "数组下标写越界: \(i)", location: loc)
 }
 arr[idx] = newValue
 return .array(arr)
 }

 r[.string] = { _, _, _, loc in
 throw RuntimeError.invalidOperation(reason: "字符串不可下标赋值（不可变）", location: loc)
 }

 r[.dictionary] = { container, index, newValue, loc in
 guard case .dictionary(var entries) = container else {
 throw RuntimeError.invalidOperation(reason: "字典下标写需字典容器: \(container)", location: loc)
 }
 // 值语义：命中键则替换，未命中则追加；返回新字典值，由调用方重新绑定到变量 / 对象字段
 // （与 `let d = [...]; d = [...]` 整体重赋值走同一条 `Environment.assign` 路径）。
 // 与 LLVM 端「仅数组/字典下标写」保持双后端锁步（#46-D D1.5 / D2）。
 if let idx = entries.firstIndex(where: { $0.0 == index }) {
 entries[idx] = (index, newValue)
 } else {
 entries.append((index, newValue))
 }
 return .dictionary(entries)
 }

 return r
 }()

 /// 执行下标写：查表分派，缺策略抛 unsupported。
 static func write(container: Value, index: Value, newValue: Value, location: SourceLocation) throws -> Value {
 // 同 read：严格枚举语义下不做 `some(x)` → `x` 透明解包。嵌套写须经显式 `!` 剥壳
 // （`a[i]![j] = v`，且 `!` 须处于 unsafe 上下文），或经 `match` 取内层后写回。
 guard let k = SubscriptReadStrategy.kind(of: container) else {
 throw RuntimeError.invalidOperation(reason: "不支持的下标容器类型: \(container)", location: location)
 }
 guard let strategy = registry[k] else {
 throw RuntimeError.invalidOperation(reason: "不支持的下标写: \(container)[\(index)]", location: location)
 }
 return try strategy(container, index, newValue, location)
 }
}
