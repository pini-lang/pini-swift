import Foundation
import PiniIR

/// 解释器侧的回调桥：C 拿到的地址必须真的能执行，所以这里备一组固定签名的桩。
/// 一组四个槽位，按线程局部登记「槽位 → Pini 可调用体」；调用前压入、返回即弹出，嵌套自然成栈。
/// 桩的签名固定为八个 GPR —— 含 `F64` 的回调不走这里，浮点走向量寄存器，与整数桩不是一个约定。
enum CallbackBridge {
    /// 槽位数。C 侧没有上下文区分两个同类指针，所以同一次调用里同类回调最多这么多路。
    static let slotCount = 4

    /// 回调的 Pini 可调用体：参数已解码成 `Value`，返回值由桥再编码回去。
    typealias Body = ([Value]) throws -> Value

    /// 一次绑定：签名决定解码宽度，体负责真正执行。
    final class Binding {
        let params: [IRType]
        let returnType: IRType?
        let body: Body

        init(params: [IRType], returnType: IRType?, body: @escaping Body) {
            self.params = params
            self.returnType = returnType
            self.body = body
        }
    }

    /// 每次调用一份的槽位表。线程局部：桩在 C 的线程上执行，读不到调用方的全局变量。
    private final class SlotTable {
        var slots: [Binding?] = Array(repeating: nil, count: CallbackBridge.slotCount)
    }

    /// 回调体抛出的错误。C 没有错误通道，先记在这里，等外层调用返回后由 thunk 抛出 ——
    /// 这样 Pini 的程序错误仍然是一条正常诊断，而不是把进程杀掉。
    private final class PendingError {
        var error: Error?
    }

    private static let tableKey = "pini.callback.slots"
    private static let errorKey = "pini.callback.error"

    private static var table: SlotTable {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[tableKey] as? SlotTable { return existing }
        let created = SlotTable()
        dictionary[tableKey] = created
        return created
    }

    private static var pendingError: PendingError {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[errorKey] as? PendingError { return existing }
        let created = PendingError()
        dictionary[errorKey] = created
        return created
    }

    // MARK: - 绑定

    /// 占一个槽位并返回桩的地址。没有空槽时返回 nil —— 调用方据此报错，不静默复用别人的槽。
    static func bind(
        params: [IRType], returnType: IRType?, body: @escaping Body
    ) -> (slot: Int, address: UnsafeMutableRawPointer)? {
        let table = self.table
        guard let slot = table.slots.firstIndex(where: { $0 == nil }) else { return nil }
        table.slots[slot] = Binding(params: params, returnType: returnType, body: body)
        return (slot, trampoline(slot))
    }

    static func unbind(slot: Int) {
        let table = self.table
        guard table.slots.indices.contains(slot) else { return }
        table.slots[slot] = nil
    }

    /// 取出并清空待抛的错误：外层 thunk 在 C 调用返回后立刻查它。
    static func takePendingError() -> Error? {
        let pending = pendingError
        defer { pending.error = nil }
        return pending.error
    }

    private static func trampoline(_ slot: Int) -> UnsafeMutableRawPointer {
        let function: Trampoline
        switch slot {
        case 0: function = piniCallback0
        case 1: function = piniCallback1
        case 2: function = piniCallback2
        default: function = piniCallback3
        }
        return unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
    }

    // MARK: - 桩

    typealias Trampoline = @convention(c) (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) -> UInt64

    /// 桩体：查槽位、解码参数、调 Pini、编码返回。错误记进 `pendingError` 并返回 0 ——
    /// 让 C 侧走完它自己的流程，外层调用返回后 Pini 侧照常抛错。
    fileprivate static func invoke(
        slot: Int, _ bits: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
    ) -> UInt64 {
        guard let binding = table.slots[slot] else {
            fail("Pini 回调桩：槽位 \(slot) 没有登记。C 在另一个线程调用了这个地址，"
                + "或地址在本次调用之外被保存了下来。")
        }
        let all = [bits.0, bits.1, bits.2, bits.3, bits.4, bits.5, bits.6, bits.7]
        do {
            let args = try decode(all, types: binding.params)
            let result = try binding.body(args)
            return try encode(result, type: binding.returnType)
        } catch {
            let pending = pendingError
            if pending.error == nil { pending.error = error }
            return 0
        }
    }

    /// 桥接层无法继续时只能终止：C 的栈帧没法 unwind 回解释器，静默返回会让 C 把失败当结果。
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(70)
    }

    private static func decode(_ bits: [UInt64], types: [IRType]) throws -> [Value] {
        var values: [Value] = []
        for (index, type) in types.enumerated() {
            let word = bits[index]
            switch type {
            case .i8:
                values.append(.int(Int(Int8(bitPattern: UInt8(truncatingIfNeeded: word)))))
            case .u8:
                values.append(.int(Int(UInt8(truncatingIfNeeded: word))))
            case .i32:
                values.append(.int(Int(Int32(bitPattern: UInt32(truncatingIfNeeded: word)))))
            case .i64, .u64:
                values.append(.int(Int(Int64(bitPattern: word))))
            case .pointer(let element):
                let pointer = withUnsafeBytes(of: word) { $0.load(as: UnsafeMutableRawPointer.self) }
                values.append(
                    .rawPointer(
                        RawPointerValue(
                            pointer: pointer, elemType: ForeignThunk.annotation(for: element),
                            freesMemory: false)))
            default:
                throw RuntimeError.invalidOperation(
                    reason: "Pini 回调桩只接整数与指针参数：第 \(index + 1) 个是 \(type.describe())",
                    location: IRExecutor.noLocation)
            }
        }
        return values
    }

    private static func encode(_ value: Value, type: IRType?) throws -> UInt64 {
        guard let type else { return 0 }
        switch type {
        case .i8, .u8:
            guard case .int(let number) = value else { throw mismatch(value, type) }
            return UInt64(UInt8(truncatingIfNeeded: number))
        case .i32:
            guard case .int(let number) = value else { throw mismatch(value, type) }
            return UInt64(UInt32(truncatingIfNeeded: number))
        case .i64, .u64:
            guard case .int(let number) = value else { throw mismatch(value, type) }
            return UInt64(bitPattern: Int64(number))
        case .pointer:
            guard case .rawPointer(let pointer) = value else { throw mismatch(value, type) }
            return UInt64(UInt(bitPattern: pointer.pointer))
        default:
            throw RuntimeError.invalidOperation(
                reason: "Pini 回调桩只接整数与指针返回：声明为 \(type.describe())",
                location: IRExecutor.noLocation)
        }
    }

    private static func mismatch(_ value: Value, _ type: IRType) -> RuntimeError {
        RuntimeError.invalidOperation(
            reason: "Pini 回调桩：\(type.describe()) 位置拿到的不是同类值（\(value))",
            location: IRExecutor.noLocation)
    }
}

// 四个槽位的桩。`@_cdecl` 让它按 C 约定导出，`unsafeBitCast` 取到的就是 C 要的地址。
@_cdecl("pini_cb_0")
public func piniCallback0(
    _ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64,
    _ e: UInt64, _ f: UInt64, _ g: UInt64, _ h: UInt64
) -> UInt64 {
    CallbackBridge.invoke(slot: 0, (a, b, c, d, e, f, g, h))
}

@_cdecl("pini_cb_1")
public func piniCallback1(
    _ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64,
    _ e: UInt64, _ f: UInt64, _ g: UInt64, _ h: UInt64
) -> UInt64 {
    CallbackBridge.invoke(slot: 1, (a, b, c, d, e, f, g, h))
}

@_cdecl("pini_cb_2")
public func piniCallback2(
    _ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64,
    _ e: UInt64, _ f: UInt64, _ g: UInt64, _ h: UInt64
) -> UInt64 {
    CallbackBridge.invoke(slot: 2, (a, b, c, d, e, f, g, h))
}

@_cdecl("pini_cb_3")
public func piniCallback3(
    _ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64,
    _ e: UInt64, _ f: UInt64, _ g: UInt64, _ h: UInt64
) -> UInt64 {
    CallbackBridge.invoke(slot: 3, (a, b, c, d, e, f, g, h))
}
