import Foundation
import PiniSyntax

/// 下标读策略注册表（解释器侧）：按容器运行时值类型注册策略，新增容器只需 `register` 一条，分派逻辑不动。
/// 注册表首次访问时初始化默认策略集；查不到策略即抛 unsupported，故新容器忘了注册会在此处暴露。
/// LLVM 端按下标处的静态 IR 类型分派，维度不同，两端各按自身维度注册，不强行统一抽象。
enum SubscriptReadStrategy {

    /// 容器运行时值分类（与 `Value` 下标相关 case 对齐，但不耦合具体 payload）。
    enum ContainerKind {
        case array, string, dictionary
    }

    /// 读策略签名：给定容器值、索引值、位置，返回元素值。
    typealias ReadStrategy = (Value, Value, SourceLocation) throws -> Value

    /// 注册表：键为容器分类，值为读策略。首次访问时初始化默认策略集。
    /// 初始化后不再改写；策略是无捕获的纯函数，多线程同时调用不共享可变状态，故免隔离是安全的。
    nonisolated(unsafe) private static let registry: [ContainerKind: ReadStrategy] = {
        var r: [ContainerKind: ReadStrategy] = [:]

        r[.array] = { container, index, loc in
            guard case .array(let arr) = container, case .int(let i) = index else {
                throw RuntimeError.invalidOperation(reason: "数组下标需整数索引: \(container)[\(index)]", location: loc)
            }
            // P2-A：负索引尾部计数（i<0 → len+i；-1=末元素，-len=首元素）。
            let idx = i < 0 ? arr.count + i : i
            // `a[i]` 是安全断言通道：返回元素本身（静态类型 `T`），越界即 panic——与 LLVM 侧 `@bk_array_get` 一致。
            // 容错需求走 `.get(i)`（返回 Optional），界内且性能敏感处走 `unsafe .getUnchecked(i)`。
            guard idx >= 0, idx < arr.count else {
                throw RuntimeError.indexOutOfRange(location: loc)
            }
            return arr[idx]
        }

        r[.string] = { container, index, loc in
            guard case .string(let s) = container, case .int(let i) = index else {
                throw RuntimeError.invalidOperation(reason: "字符串下标需整数索引: \(container)[\(index)]", location: loc)
            }
            // 负索引尾部计数（i<0 → len+i；-1=末元素，-len=首元素）。计数与定位都走 `GraphemeCursor`（均摊 O(1)），
            // 逐字符算长度再偏移会让 `while i < len(s): s[i]` 退化到 O(n²)。
            let n = GraphemeCursor.count(of: s)
            let idx = i < 0 ? n + i : i
            // 字符串下标同为安全断言通道——越界 panic（E5-005），界内返回字符。
            guard idx >= 0, idx < n else {
                throw RuntimeError.indexOutOfRange(location: loc)
            }
            // 下标结果是 `Char`，不是 `String` —— 窄化的三个构造点之一
            // （`s[i]` / `chars` / `chr`）。想拿回 `String` 由加宽承接。
            return .char(String(GraphemeCursor.character(in: s, at: idx)))
        }

        r[.dictionary] = { container, index, loc in
            guard case .dictionary(let entries) = container else {
                throw RuntimeError.invalidOperation(reason: "字典下标需字典容器: \(container)", location: loc)
            }
            // 字典缺失键与下标越界**同义**——同走 panic（E5-005）。
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
        /// `Char` (P0d) is declared, not defaulted, on purpose: it shares
        /// `String`'s representation but is not a container, and the default arm
        /// that would have caught it silently is exactly what phase A warned about.
        case .char: return nil
        default: return nil
        }
    }

    /// 执行下标读：查表分派，缺策略抛 unsupported。
    /// 返回元素值本身（静态类型 `T`），越界/缺键抛 `RuntimeError.indexOutOfRange`，故嵌套下标可直接连写 `m[0][1]`。
    /// 容错改走 `.get(i)`：本通道的语义是「我断言存在」，不返回 Optional。
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

/// 下标写策略注册表（解释器侧），与 `SubscriptReadStrategy` 对称：容器分类维度复用同一 `ContainerKind`。
/// 写不要求容器就地可变——数组/字典在解释器侧是值语义，写返回新容器值，由调用方重新绑定到变量或字段。
/// 当前仅数组支持下标写；字符串不可变故不支持，字典下标写未接入，与 LLVM 端「仅数组」保持锁步。
enum SubscriptWriteStrategy {

    /// 写策略签名：给定容器值、索引值、新元素值、位置，返回写后的新容器值。
    typealias WriteStrategy = (Value, Value, Value, SourceLocation) throws -> Value

    /// 注册表：键复用 `SubscriptReadStrategy.ContainerKind`（容器分类维度一致）。
    /// 初始化后不再改写；策略是无捕获的纯函数，多线程同时调用不共享可变状态，故免隔离是安全的。
    nonisolated(unsafe) private static let registry: [SubscriptReadStrategy.ContainerKind: WriteStrategy] = {
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
            // 与 LLVM 端「仅数组/字典下标写」保持双后端锁步。
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
