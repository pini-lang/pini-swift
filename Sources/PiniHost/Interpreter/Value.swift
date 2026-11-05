import Foundation
import PiniSyntax

/// 并发工作节点同时是取消节点：取消沿 `Future` 树传播，不另立 `CancelScope`。
/// 三重身份——结果载体（`resolve`/`reject`/`wait`）、取消节点（`isCancelled` + 递归 `cancel()`）、
/// 树节点（`parent`/`children`，spawn 时即建链，故子句柄被丢弃也不影响父取消时连带停止）。
public final class FutureValue: @unchecked Sendable {
    // 全部可变状态由 `lock` 保护；句柄的设计目的就是跨线程传递 ⇒ 手工声明，不由编译器推断。
    // MARK: - 同步原语（后端实现细节，并发后端抽象 / 并发调度脊柱 ）

    // `lock` 及其保护的 `wait` / `resolve` / `reject` 临界区，当前以 Foundation `NSLock`
    // 实现，属**后端实现细节**。将来跨平台后端以可移植同步原语（pthread / 原子 parking）
    // 替换时，仅需改动此处，不改变 `FutureValue` 的契约语义（取消树 / 结果传播不变）。
    private let lock = NSLock()
    public private(set) var isResolved: Bool = false
    public private(set) var result: Value? = nil
    public private(set) var error: RuntimeError? = nil
    private var waiters: [() -> Void] = []
    /// 挂起式等待（`whenResolved`，Strategy B 自建续体）的续体回调。与 `waiters` 并行维护：
    /// 阻塞 `wait()` 用 `waiters`（无参回调），挂起 `whenResolved` 用 `suspendCallbacks`
    /// （携带 `Result` 值）。零 Swift 并发运行时依赖，保持「无平台限制 / Swift 5.9+」。
    private var suspendCallbacks: [(Result<Value, RuntimeError>) -> Void] = []

    // MARK: - B2-1 结构化取消

    private var cancelled: Bool = false
    /// 父节点弱引用（父强持有子，子弱引用父，避免保留环）。
    public private(set) weak var parent: FutureValue?
    private var children: [FutureValue] = []
    private var cancelHandlers: [() -> Void] = []

    /// 是否已被取消（手动 `t.cancel()` / 父任务返回自动取消 / 超时归约取消）。
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public init() {}

    /// 登记子任务：在 spawn 时调用。若父已被取消，新子任务立即被取消（不漏网）。
    public func addChild(_ child: FutureValue) {
        lock.lock()
        if cancelled {
            lock.unlock()
            child.cancel()
            return
        }
        child.parent = self
        children.append(child)
        lock.unlock()
    }

    /// 当前仍登记在册的子任务快照（B2-2 父返回自动取消用）。
    public func childrenSnapshot() -> [FutureValue] {
        lock.lock(); defer { lock.unlock() }
        return children
    }

    /// 是否已终结（resolve / reject 之一已发生）。线程安全读。
    public var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return isResolved
    }

    /// 已被 join 的子任务脱离父节点：其生命周期已被显式消费，不再受「父返回自动取消」约束。
    /// 同时起到剪枝作用，避免长生命周期任务的 `children` 无界增长。
    public func detachFromParent() {
        guard let p = parent else { return }
        p.removeChild(self)
    }

    private func removeChild(_ child: FutureValue) {
        lock.lock()
        children.removeAll { $0 === child }
        lock.unlock()
        child.parent = nil
    }

    /// 父返回自动取消：任务体结束（正常返回 / 抛错 / 被取消）时取消所有未 join 且未完成的子任务，
    /// 保证子任务生命周期不超出父任务。已 join 的子已脱钩不在册；已完成未 join 的子无占用，不取消。
    public func cancelUnjoinedChildren() {
        lock.lock()
        let kids = children
        children = []
        lock.unlock()
        for kid in kids where !kid.isFinished {
            kid.cancel()
        }
    }

    /// scope 收口：快照 `children` 后分区——未完成则 `cancel()`；已完成且为 `err(...)` 值或已 `reject` 的收集为 leaked。
    /// 已完成 `ok(...)` 不算泄漏：结果仍可读，取消不是追溯性失效。
    /// 返回 leaked 供 `return` 边界翻转成 `err(aggregate)`；已脱钩的子不在 `children`，天然不计入。
    public func closeScope() -> [Value] {
        lock.lock()
        let kids = children
        children = []
        lock.unlock()
        var leaked: [Value] = []
        for kid in kids {
            guard kid.isFinished else { kid.cancel(); continue }
            if let e = kid.error {
                // reject（运行时错误 / 取消）→ 以错误值形式计入 leaked
                leaked.append(RuntimeOps.makeError(e.description))
            } else if let r = kid.result,
                case .enumValue(let ev) = r,
                ev.parentEnum == RuntimeOps.builtinResultEnumName,
                ev.caseName == "err"
            {
                // resolve 成 `err(...)` 值（errors-as-data 的失败）→ 计入 leaked
                leaked.append(r)
            }
        }
        return leaked
    }

    /// 递归取消：标记自身 → 唤醒所有阻塞的 `wait()` → 逐个递归取消子任务。
    /// 取消是协作式的：worker 不会被强杀，而是在下一个检查点（异步体入口 / join 前）看到标志后提前结束，
    /// 故取消是最终一致的。
    public func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let kids = children
        let ws = waiters
        let handlers = cancelHandlers
        waiters = []
        cancelHandlers = []
        lock.unlock()
        // 先唤醒本节点的等待者（阻塞中的 join 立即得到 CancelError），再向下传播。
        ws.forEach { $0() }
        kids.forEach { $0.cancel() }
        // 附加取消联动（B2-4：joinAll 聚合节点据此取消其成员——成员不在子表中，
        // 因为它们的父作用域另有归属，不能被聚合节点篡改父链）。
        handlers.forEach { $0() }
    }

    /// 注册取消联动回调：本节点被取消时触发（已取消则立即触发）。
    /// 用于「非父子关系但需随之取消」的联动，如 `joinAll` 聚合节点 → 其成员任务。
    public func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        cancelHandlers.append(handler)
        lock.unlock()
    }

    public func resolve(_ value: Value) {
        lock.lock()
        guard !isResolved else { lock.unlock(); return }
        isResolved = true
        result = value
        let ws = waiters
        let scs = suspendCallbacks
        waiters = []
        suspendCallbacks = []
        lock.unlock()
        ws.forEach { $0() }
        scs.forEach { $0(.success(value)) }
    }

    public func reject(_ error: RuntimeError) {
        lock.lock()
        guard !isResolved else { lock.unlock(); return }
        isResolved = true
        self.error = error
        let ws = waiters
        let scs = suspendCallbacks
        waiters = []
        suspendCallbacks = []
        lock.unlock()
        ws.forEach { $0() }
        scs.forEach { $0(.failure(error)) }
    }

    public func onResolved(_ waiter: @escaping () -> Void) {
        lock.lock()
        if isResolved {
            lock.unlock()
            waiter()
            return
        }
        waiters.append(waiter)
        lock.unlock()
    }

    /// 阻塞当前线程直至 resolve / reject / 被取消：resolve 返回值，reject 与取消都抛出运行时错误。
    /// 取消优先级高于结果——一旦 `cancelled`，即使 worker 随后正常 resolve，join 仍恒得取消错误，
    /// 保证「取消后结果确定」而非竞态。
    public func wait() throws -> Value {
        lock.lock()
        if cancelled {
            lock.unlock()
            throw FutureValue.cancelError()
        }
        if isResolved {
            let e = error
            let r = result
            lock.unlock()
            if let e = e { throw e }
            return r ?? .null
        }
        let group = DispatchGroup()
        group.enter()
        waiters.append { group.leave() }
        lock.unlock()
        group.wait()
        lock.lock()
        let wasCancelled = cancelled
        let e = error
        let r = result
        lock.unlock()
        if wasCancelled { throw FutureValue.cancelError() }
        if let e = e { throw e }
        return r ?? .null
    }

    /// 自建续体挂起，零 Swift 并发运行时依赖。已 resolve 时同步回调，否则登记续体待 resolve/reject 唤醒。
    /// 调用方随后应返回并释放 OS 线程，由 executor 驱动续体——这是 `await` 不阻塞线程的底层机制。
    /// 子任务被取消会自行 `reject`，回调自然得到 `.failure`，此处无需特判。
    func whenResolved(_ cb: @escaping (Result<Value, RuntimeError>) -> Void) {
        lock.lock()
        if isResolved {
            let outcome: Result<Value, RuntimeError> =
                error.map { .failure($0) }
                ?? (result.map { .success($0) } ?? .success(.null))
            lock.unlock()
            cb(outcome)
            return
        }
        suspendCallbacks.append(cb)
        lock.unlock()
    }

    /// 带超时的阻塞等待：期内完成则与 `wait()` 同语义；超时返回 `nil` 且不改变 Future 状态，
    /// 取消与否由调用方决定；等待期间被取消则抛出 `taskCancelled`。
    public func wait(timeout seconds: Double) throws -> Value? {
        lock.lock()
        if cancelled {
            lock.unlock()
            throw FutureValue.cancelError()
        }
        if isResolved {
            let e = error
            let r = result
            lock.unlock()
            if let e = e { throw e }
            return r ?? .null
        }
        let group = DispatchGroup()
        group.enter()
        waiters.append { group.leave() }
        lock.unlock()
        if group.wait(timeout: .now() + max(0, seconds)) == .timedOut {
            return nil
        }
        lock.lock()
        let wasCancelled = cancelled
        let e = error
        let r = result
        lock.unlock()
        if wasCancelled { throw FutureValue.cancelError() }
        if let e = e { throw e }
        return r ?? .null
    }

    static func cancelError(reason: String = "任务已被取消") -> RuntimeError {
        return .taskCancelled(reason: reason, location: SourceLocation(line: 0, column: 0, fileName: "<builtin>"))
    }
}

public enum Value {
    case int(Int)
    case float(Double)
    case string(String)
    /// `Char`: one extended grapheme cluster. Payload type is `String`, shared with `string`, so every
    /// existing string path (printing, concatenation, runtime handles) applies without conversion;
    /// the "exactly one grapheme" invariant is the type system's, not the representation's.
    case char(String)
    case bool(Bool)
    /// 元组值。labels[i] 对应 elements[i] 的可选标签（nil = 位置元素；位置元组为全 nil 或空数组）。
    /// 与 TypeAnnotation.tuple(labels:) / Expression.tuple(labels:) 对齐（草稿 A2，批次 1.3，D1），供 `.名称` 标签访问。
    case tuple(labels: [String?], elements: [Value])
    case array([Value])
    case dictionary([(Value, Value)])
    case set([Value])
    case structInstance(StructInstance)
    case objectReference(ObjectReference)
    case enumValue(EnumValue)
    case function(FunctionValue)
    case future(FutureValue)
    /// 弱引用包装——引用语义承载（class），复制共享同一 box。
    case weakRef(WeakRefBox)
    /// 懒加载包装——引用语义承载（class），复制共享同一「锁 + once 标志 + 缓存」。
    case lazyRef(LazyRefBox)
    /// Phase 2a（FFI 子系统）：原始指针 `*T`——引用语义承载（class），复制共享同一地址。
    case rawPointer(RawPointerValue)
    case null
}

/// `*T` 原始指针的运行时承载：`pointer` 是裸地址（C ABI，不泄漏 Swift 类型），`elemType` 给 load/store 的编解码宽度，
/// `freesMemory` 表示解释器是否负责释放（`&` 快照内存归解释器，`malloc` 内存归用户的 `free`）。
/// 引用语义：复制共享同一地址，`copyIfStruct` 对非 `.structInstance` 原样返回。
public final class RawPointerValue {
    public let pointer: UnsafeMutableRawPointer
    public let elemType: TypeAnnotation?
    private let freesMemory: Bool

    public init(pointer: UnsafeMutableRawPointer, elemType: TypeAnnotation?, freesMemory: Bool) {
        self.pointer = pointer
        self.elemType = elemType
        self.freesMemory = freesMemory
    }

    deinit {
        if freesMemory { pointer.deallocate() }
    }

    /// 指针算术（`p + n`）：按元素 stride 偏移（stride 从 elemType 推断，未知元素类型按 1 字节）。
    public func advanced(by count: Int) -> UnsafeMutableRawPointer {
        let stride = RawPointerValue.stride(of: elemType) ?? 1
        return pointer.advanced(by: stride * count)
    }

    /// `*T` 元素类型的字节宽度。nil = 未知（按 1 字节）。
    public static func stride(of type: TypeAnnotation?) -> Int? {
        guard let t = type else { return nil }
        switch t {
        case .simple(let name, _):
            switch name {
            case "I8", "U8", "Bool": return 1
            case "I16", "U16": return 2
            case "I32", "U32", "F32": return 4
            case "I64", "U64", "F64": return 8
            default: return nil
            }
        case .pointer: return MemoryLayout<UnsafeMutableRawPointer>.size
        default: return nil
        }
    }

    /// 从值推断 `*T` 元素类型（`&` 快照 / addressof 用）。int→I64、float→F64、bool→Bool。
    public static func elemType(for value: Value) -> TypeAnnotation? {
        switch value {
        case .int: return .simple(name: "I64", location: SourceLocation(line: 0, column: 0, fileName: "<builtin>"))
        case .float: return .simple(name: "F64", location: SourceLocation(line: 0, column: 0, fileName: "<builtin>"))
        case .bool: return .simple(name: "Bool", location: SourceLocation(line: 0, column: 0, fileName: "<builtin>"))
        default: return nil
        }
    }
}

/// `LazyRef<T>` 的引用语义承载：独立 class box（非 `.structInstance`），`var b = a` 复制共享同一 box，
/// 锁、once 标志、缓存、初始化闭包全部共享。`.value` 同步阻塞获取，首访加锁执行初始化闭包并缓存，
/// 后续返回缓存；多线程首访竞争只有一个线程执行初始化。
public final class LazyRefBox {
    public let initializer: FunctionValue
    private let lock = NSLock()
    private var initialized = false
    private var cached: Value = .null

    public init(initializer: FunctionValue) {
        self.initializer = initializer
    }

    /// 同步阻塞获取（once）：未初始化则加锁执行 `compute`（初始化闭包求值）并缓存，已初始化直接返回缓存。
    /// 锁在临界区持有期间调用 compute——初始化闭包内**不得**再访问同一 LazyRef 的 `.value`（NSLock 非重入）。
    public func value(compute: (FunctionValue) throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        if !initialized {
            cached = try compute(initializer)
            initialized = true
        }
        return cached
    }

    public var isInitialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialized
    }
}

/// `WeakRef` 的引用语义承载：独立 class box 而非 `StructInstance`——后者会被 `copyIfStruct` 深拷贝，
/// 复制出值语义分裂的新包装，且 `weakRetain` 只在构造时调一次、`weakRelease` 无调用点，弱引用表随之泄漏。
/// 独立 box 让复制共享同一份，`weakRetain`（init）与 `weakRelease`（deinit）由 ARC 保证对称、无泄漏。
public final class WeakRefBox {
    public let target: ObjectReference
    private weak var manager: ARCManager?

    public init(target: ObjectReference, manager: ARCManager) {
        self.target = target
        self.manager = manager
        manager.weakRetain(target)
    }

    deinit {
        manager?.weakRelease(target)
    }
}

public class StructInstance {
    public let typeName: String
    public var fields: [String: Value]

    public init(typeName: String, fields: [String: Value] = [:]) {
        self.typeName = typeName
        self.fields = fields
    }
}

public final class ObjectReference {
    public let typeName: String
    public var fields: [String: Value]
    public var refCount: Int

    public init(typeName: String, fields: [String: Value] = [:]) {
        self.typeName = typeName
        self.fields = fields
        self.refCount = 1
    }
}

public struct EnumValue {
    public let caseName: String
    public let associatedValues: [Value]
    public let paramNames: [String?]
    public let parentEnum: String?

    public init(caseName: String, associatedValues: [Value] = [], paramNames: [String?] = [], parentEnum: String? = nil) {
        self.caseName = caseName
        self.associatedValues = associatedValues
        self.paramNames = paramNames
        self.parentEnum = parentEnum
    }
}

public class FunctionValue {
    public let name: String
    public let params: [Parameter]
    public let returnTypes: [TypeAnnotation]
    public let body: Block?
    public let decl: FuncDecl?
    public let closure: Environment
    public var isTypeConstructor: Bool = false
    public var typeKind: TypeKind? = nil
    public var typeName: String = ""
    public var isEnumCaseConstructor: Bool = false
    public var enumCaseName: String = ""
    /// 枚举 case 关联值默认表达式（字面量默认，注册期原样保留）。
    public var enumParamDefaults: [PiniSyntax.Expression?] = []
    public var enumIsGeneric: Bool = false
    public var enumParentName: String = ""
    public var enumGenericParamCount: Int = 0
    /// 裸名 case 消歧（静态收敛版）：关联参数声明类型名（describe），供歧义 case 裸名构造的动态消歧计分
    public var enumCaseParamTypeNames: [String] = []
    private var _isAsync: Bool = false

    public var isAsync: Bool {
        if let decl = decl { return decl.isAsync }
        return _isAsync
    }

    public enum TypeKind { case structKind, objectKind }

    /// Phase 2a（FFI 子系统）：foreign/native 函数的 Swift 实现（`[名称|foreign]` 声明经原生函数表解析）。
    public var nativeImpl: (([Value]) throws -> Value)? = nil

    public init(
        name: String,
        params: [Parameter],
        returnTypes: [TypeAnnotation] = [],
        body: Block? = nil,
        decl: FuncDecl? = nil,
        closure: Environment
    ) {
        self.name = name
        self.params = params
        self.returnTypes = returnTypes
        self.body = body
        self.decl = decl
        self.closure = closure
    }

    public func markAsync() {
        _isAsync = true
    }
}

extension Value: Equatable {
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.int(let l), .int(let r)): return l == r
        case (.float(let l), .float(let r)): return l == r
        case (.string(let l), .string(let r)): return l.utf8.elementsEqual(r.utf8)
        /// `Char` 与 `String` 是相容对（同表示），比较一律按 UTF-8 字节序列 —— 与编译通道的
        /// 「先比长度再 `memcmp`」同一条判据，不做规范等价。 行不通  用 Swift 的 `==`：它按规范等价，
        /// NFD 的 `é` 与预组合的 `é` 相等，而编译产物上那两个字节不等。
        case (.char(let l), .char(let r)): return l.utf8.elementsEqual(r.utf8)
        case (.char(let l), .string(let r)): return l.utf8.elementsEqual(r.utf8)
        case (.string(let l), .char(let r)): return l.utf8.elementsEqual(r.utf8)
        case (.bool(let l), .bool(let r)): return l == r
        case (.tuple(_, let l), .tuple(_, let r)): return l == r
        case (.structInstance(let l), .structInstance(let r)):
            return l === r || (l.typeName == r.typeName && l.fields == r.fields)
        case (.objectReference(let l), .objectReference(let r)):
            return l === r
        case (.enumValue(let l), .enumValue(let r)):
            return l.caseName == r.caseName && l.associatedValues == r.associatedValues
        case (.function(let l), .function(let r)):
            return l === r
        case (.future(let l), .future(let r)):
            return l === r
        case (.array(let l), .array(let r)):
            return l == r
        case (.dictionary(let l), .dictionary(let r)):
            guard l.count == r.count else { return false }
            for (lk, lv) in l {
                guard let rv = r.first(where: { $0.0 == lk })?.1 else { return false }
                if lv != rv { return false }
            }
            return true
        case (.set(let l), .set(let r)):
            return l == r
        case (.rawPointer(let l), .rawPointer(let r)):
            return l.pointer == r.pointer
        case (.null, .null): return true
        default: return false
        }
    }
}

extension StructInstance: Equatable {
    public static func == (lhs: StructInstance, rhs: StructInstance) -> Bool {
        lhs === rhs || (lhs.typeName == rhs.typeName && lhs.fields == rhs.fields)
    }
}
