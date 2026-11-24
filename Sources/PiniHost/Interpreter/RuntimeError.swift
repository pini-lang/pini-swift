import Foundation
import PiniSyntax

public enum ControlSignal: Error {
    case returnSignal(Value?)
    case breakSignal(label: String?)
    case continueSignal(label: String?)
}

public struct ErrorSignal {
    public let value: Value
    public init(value: Value) {
        self.value = value
    }
}

public enum RuntimeError: Error, CustomStringConvertible {
    case undefinedVariable(name: String, location: SourceLocation)
    case immutableVariable(name: String, location: SourceLocation)
    case typeMismatch(expected: String, got: String, location: SourceLocation)
    case divisionByZero(location: SourceLocation)
    case indexOutOfRange(location: SourceLocation)
    case invalidOperation(reason: String, location: SourceLocation)
    case mainNotFound(location: SourceLocation)
    /// 清单声明了 `[[bin]].entry` / `[lib].entry`，但 `main` 不在其中。
    /// 声明入口即承诺「程序从这里开始」，`main` 落在别处就是配置与代码不一致；
    /// 静默退化为全局找 `main` 会让 entry 字段形同虚设。
    case entryMainMismatch(entries: [String], declaredIn: String, location: SourceLocation)
    case notCallable(location: SourceLocation)
    case arityMismatch(expected: Int, got: Int, location: SourceLocation)
    /// 访问了以 `_` 前缀声明的字段，而访问点不在该字段声明类型自身的方法内：
    /// 同文件的普通函数、跨类型方法、跨文件访问都会被拒。
    case inaccessibleField(typeName: String, fieldName: String, location: SourceLocation)
    /// 并发任务被取消：手动 `t.cancel()`、父任务返回自动取消或超时归约。
    /// join 时会被归约成 `err(CancelError)` 数据值，不作为异常冒泡到用户代码 —— 错误即数据。
    case taskCancelled(reason: String, location: SourceLocation)
    /// 枚举值没有任何 case 命中，也没有 default / 通配子块兜底时抛出，而非静默跳过。
    case matchNotExhaustive(value: String, location: SourceLocation)
    /// `assert` 内建的条件为 false 时抛出；测试运行器捕获它并记为测试失败。
    case assertionFailed(message: String, location: SourceLocation)
    /// 原生函数实参个数与签名不符（`load` / `store` / `malloc` 等）。
    case argumentCountMismatch(name: String, expected: Int, got: Int, location: SourceLocation)
    /// `[名称|foreign]` 声明的 C 函数不在原生函数表里（未预注册）。
    case undefinedNativeFunction(name: String, available: [String], location: SourceLocation)
    /// `[名称|foreign]` 块名对应的库在搜索路径中找不到（解释器经 dlsym 加载）。
    case libraryNotFound(library: String, searched: [String], location: SourceLocation)
    /// 符号在 `[ffi].libs` 预加载的库与进程映像里都找不到。`searched` 是查过的库标签，
    /// 顺序与解析顺序一致 —— 报错要能回答「到底找过哪些地方」。
    case symbolNotFound(symbol: String, searched: [String], location: SourceLocation)
    /// 变参调用落到解释器上：转发靠把地址位转成固定槽位，而 Apple arm64 把变参放在栈上。
    /// 这不是「还没实现」，是这条路本身走不通 —— 文案给两条能走的路。
    case variadicCallUnsupported(name: String, location: SourceLocation)
    /// 句柄调用落到解释器上：`bk_str_handle_*` 只活在运行时段里，`pini` 进程没有这些符号。
    /// 与变参同一条性质 —— 换通道，或把句柄留在 C 侧。
    case stringHandleCallUnsupported(name: String, location: SourceLocation)

    public var description: String {
        switch self {
        case .undefinedVariable(let name, let loc):
            return "未定义变量: \(name) at \(loc)"
        case .immutableVariable(let name, let loc):
            return "不可修改的变量: \(name) at \(loc)"
        case .typeMismatch(let expected, let got, let loc):
            return "类型不匹配: 期望 \(expected), 得到 \(got) at \(loc)"
        case .divisionByZero(let loc):
            return "除以零 at \(loc)"
        case .indexOutOfRange(let loc):
            return "索引越界 at \(loc)"
        case .invalidOperation(let reason, let loc):
            return "无效操作: \(reason) at \(loc)"
        case .mainNotFound(let loc):
            return "未找到 main 函数 at \(loc)"
        case .entryMainMismatch(let entries, let declaredIn, let loc):
            return "入口配置与代码不一致：清单声明入口为 \(entries.joined(separator: " / "))，"
                + "但 main 定义在 \(declaredIn)。请修正 entry，或删掉 entry 以回到「全局找 main」默认行为 at \(loc)"
        case .notCallable(let loc):
            return "不可调用 at \(loc)"
        case .arityMismatch(let expected, let got, let loc):
            return "参数数量不匹配: 期望 \(expected), 得到 \(got) at \(loc)"
        case .inaccessibleField(let typeName, let fieldName, let loc):
            return "无法访问私有字段 '\(typeName).\(fieldName)': 该字段为 type-private，仅 \(typeName) 类型自身的方法可访问 at \(loc)"
        case .taskCancelled(let reason, let loc):
            return "\(reason) at \(loc)"
        case .matchNotExhaustive(let value, let loc):
            return "match 未穷尽: 值 '\(value)' 未匹配任何 case 且无 default/通配子块兜底 at \(loc)"
        case .assertionFailed(let message, let loc):
            return "断言失败: \(message) at \(loc)"
        case .argumentCountMismatch(let name, let expected, let got, let loc):
            return "原生函数 \(name) 参数数量不匹配: 期望 \(expected), 得到 \(got) at \(loc)"
        case .undefinedNativeFunction(let name, let available, let loc):
            return "未注册的原生函数 '\(name)'（`[名称|foreign]` 声明的 C 函数须在原生函数表内）；可用: \(available.isEmpty ? "（无）" : available.joined(separator: ", ")) at \(loc)"
        case .libraryNotFound(let library, let searched, let loc):
            return "FFI 库 '\(library)' 未找到（已搜索：\(searched.isEmpty ? "（无搜索路径）" : searched.joined(separator: ", "))）at \(loc)"
        case .symbolNotFound(let symbol, let searched, let loc):
            return "未找到外部符号 '\(symbol)'（已查：\(searched.isEmpty ? "（无）" : searched.joined(separator: ", "))）at \(loc)"
        case .variadicCallUnsupported(let name, let loc):
            return "变参调用 '\(name)' 需要 C 变参 ABI：解释器只能按固定签名转发，"
                + "变参在 Apple arm64 上走栈而不走寄存器。改用 `pini run-llvm`，"
                + "或在 C 侧写一个固定参数的 shim 再声明它 at \(loc)"
        case .stringHandleCallUnsupported(let name, let loc):
            return "调用 '\(name)' 要用字符串句柄：句柄由运行时段持有，`pini` 进程里没有这些符号。"
                + "改用 `pini run-llvm` 或 `pini build --shared`，"
                + "或把句柄的创建与读取都留在 C 侧 at \(loc)"
        }
    }

    /// 位置补齐：占位位置（行号 0）换成语句边界的真实位置，已有位置的一律不动。
    /// 判据在「缺不缺」而不在调用点 —— 内层语句边界先补，外层拿到的是已补过的错误。
    public func fillingLocation(_ location: SourceLocation) -> RuntimeError {
        guard self.location.isPlaceholder else { return self }
        switch self {
        case .undefinedVariable(let name, _): return .undefinedVariable(name: name, location: location)
        case .immutableVariable(let name, _): return .immutableVariable(name: name, location: location)
        case .typeMismatch(let expected, let got, _):
            return .typeMismatch(expected: expected, got: got, location: location)
        case .divisionByZero: return .divisionByZero(location: location)
        case .indexOutOfRange: return .indexOutOfRange(location: location)
        case .invalidOperation(let reason, _):
            return .invalidOperation(reason: reason, location: location)
        case .mainNotFound: return .mainNotFound(location: location)
        case .entryMainMismatch(let entries, let declaredIn, _):
            return .entryMainMismatch(entries: entries, declaredIn: declaredIn, location: location)
        case .notCallable: return .notCallable(location: location)
        case .arityMismatch(let expected, let got, _):
            return .arityMismatch(expected: expected, got: got, location: location)
        case .inaccessibleField(let typeName, let fieldName, _):
            return .inaccessibleField(typeName: typeName, fieldName: fieldName, location: location)
        case .taskCancelled(let reason, _):
            return .taskCancelled(reason: reason, location: location)
        case .matchNotExhaustive(let value, _):
            return .matchNotExhaustive(value: value, location: location)
        case .assertionFailed(let message, _):
            return .assertionFailed(message: message, location: location)
        case .argumentCountMismatch(let name, let expected, let got, _):
            return .argumentCountMismatch(name: name, expected: expected, got: got, location: location)
        case .undefinedNativeFunction(let name, let available, _):
            return .undefinedNativeFunction(name: name, available: available, location: location)
        case .libraryNotFound(let library, let searched, _):
            return .libraryNotFound(library: library, searched: searched, location: location)
        case .symbolNotFound(let symbol, let searched, _):
            return .symbolNotFound(symbol: symbol, searched: searched, location: location)
        case .variadicCallUnsupported(let name, _):
            return .variadicCallUnsupported(name: name, location: location)
        case .stringHandleCallUnsupported(let name, _):
            return .stringHandleCallUnsupported(name: name, location: location)
        }
    }

    /// 错误携带的位置：报告与诊断共用同一个读口，免得两处各解一次枚举。
    public var location: SourceLocation {
        switch self {
        case .undefinedVariable(_, let loc), .immutableVariable(_, let loc),
            .typeMismatch(_, _, let loc), .divisionByZero(let loc), .indexOutOfRange(let loc),
            .invalidOperation(_, let loc), .mainNotFound(let loc),
            .entryMainMismatch(_, _, let loc), .notCallable(let loc),
            .arityMismatch(_, _, let loc), .inaccessibleField(_, _, let loc),
            .taskCancelled(_, let loc), .matchNotExhaustive(_, let loc),
            .assertionFailed(_, let loc), .argumentCountMismatch(_, _, _, let loc),
            .undefinedNativeFunction(_, _, let loc), .libraryNotFound(_, _, let loc),
            .symbolNotFound(_, _, let loc), .variadicCallUnsupported(_, let loc),
            .stringHandleCallUnsupported(_, let loc):
            return loc
        }
    }
}
