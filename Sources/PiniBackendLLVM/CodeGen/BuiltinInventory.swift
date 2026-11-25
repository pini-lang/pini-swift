import Foundation

/// 编译器侧的运行时入口清单：LLVM 后端能发出的每一条 `pini_*` 调用。
/// 每条给四件事：符号名（跨后端的键）· 签名（`declare` 唯一来源）· 族 · 降级点。
public struct BuiltinSpec: Sendable {
    public struct Signature: Sendable {
        public let result: String
        public let parameters: [String]
        public let attributes: String

        public init(result: String, parameters: [String], attributes: String = "") {
            self.result = result
            self.parameters = parameters
            self.attributes = attributes
        }
    }

    public let symbol: String
    public let signature: Signature
    public let family: Family
    public let lowerings: [String]

    /// 声明行：签名只写在这里，调用点的实参表不再手抄第二份。
    public var declaration: String {
        let args = signature.parameters.joined(separator: ", ")
        return "declare \(signature.result) @\(symbol)(\(args))\(signature.attributes)\n"
    }
}

extension BuiltinSpec {
    /// 与运行时 ABI 契约第 2 节的族同名；族是能力声明与缺口登记的粒度。
    public enum Family: String, CaseIterable, Sendable {
        case array, dictionary, set, handle, lazyRef, weakRef, given, pointer, display, runtime
        case character, string, nominal, io, task, blocking, yielding, scheduler, error
        /// 字符串句柄：C 侧可持有的串。五个入口里只有 `new` 有发射器调用点。
        case stringHandle
    }
}

/// 降级点写 IR 节点名；节点之外的发射点用尖括号：
/// `<cleanup>` 退出或覆盖 · `<retain>` 落槽 · `<entry>` 入口 · `<print>` 打印。
/// `<panic>` 陷阱 · `<closure>` 捕获槽 · `<frame>` 帧序言 · `<yield>` 让出点。
public enum Builtins {
    public static let all: [BuiltinSpec] = [

        // MARK: 数组族
        BuiltinSpec(
            symbol: "pini_array_append",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .array, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_array_create", signature: .init(result: "ptr", parameters: ["i32"]),
            family: .array, lowerings: ["arrayLiteral", "sliceCall"]
        ),
        BuiltinSpec(
            symbol: "pini_array_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .array, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "pini_array_ensure_unique_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .array, lowerings: ["subscriptGet", "subscriptStore"]
        ),
        BuiltinSpec(
            symbol: "pini_array_get", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .array, lowerings: ["subscriptGet", "forInStmt"]
        ),
        BuiltinSpec(
            symbol: "pini_array_len", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .array, lowerings: ["lenCall", "forInStmt", "subscriptGet"]
        ),
        BuiltinSpec(
            symbol: "pini_array_set",
            signature: .init(result: "ptr", parameters: ["ptr", "i32", "ptr", "i32", "i32"]),
            family: .array, lowerings: ["arrayLiteral", "subscriptStore"]
        ),
        BuiltinSpec(
            symbol: "pini_array_set_element_hooks",
            signature: .init(result: "void", parameters: ["ptr", "ptr", "ptr"]),
            family: .array, lowerings: ["arrayLiteral", "sliceCall"]
        ),

        // MARK: 字典族
        BuiltinSpec(
            symbol: "pini_dict_create", signature: .init(result: "ptr", parameters: []),
            family: .dictionary, lowerings: ["dictLiteral"]
        ),
        BuiltinSpec(
            symbol: "pini_dict_contains",
            signature: .init(result: "i32", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .dictionary, lowerings: ["optionalGet"]
        ),
        BuiltinSpec(
            symbol: "pini_dict_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .dictionary, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "pini_dict_ensure_unique_at",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .dictionary, lowerings: ["subscriptGet", "subscriptStore"]
        ),
        BuiltinSpec(
            symbol: "pini_dict_get", signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .dictionary, lowerings: ["subscriptGet"]
        ),
        BuiltinSpec(
            symbol: "pini_dict_key_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .dictionary, lowerings: ["forInStmt"]
        ),
        BuiltinSpec(
            symbol: "pini_dict_len", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .dictionary, lowerings: ["lenCall", "forInStmt"]
        ),
        BuiltinSpec(
            symbol: "pini_dict_set",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32", "ptr", "i32", "i32"]),
            family: .dictionary, lowerings: ["dictLiteral", "subscriptStore"]
        ),
        BuiltinSpec(
            symbol: "pini_dict_val_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .dictionary, lowerings: ["forInStmt"]
        ),

        // MARK: 集合族
        BuiltinSpec(
            symbol: "pini_set_add", signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .set, lowerings: ["setLiteral"]
        ),
        BuiltinSpec(
            symbol: "pini_set_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .set, lowerings: ["forInStmt"]
        ),
        BuiltinSpec(
            symbol: "pini_set_create", signature: .init(result: "ptr", parameters: []),
            family: .set, lowerings: ["setLiteral"]
        ),
        BuiltinSpec(
            symbol: "pini_set_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .set, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "pini_set_len", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .set, lowerings: ["lenCall", "forInStmt"]
        ),

        // MARK: 句柄
        BuiltinSpec(
            symbol: "pini_handle_ensure_unique", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .handle, lowerings: ["subscriptStore", "fieldStore"]
        ),
        BuiltinSpec(
            symbol: "pini_handle_release", signature: .init(result: "void", parameters: ["ptr"]),
            family: .handle, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "pini_handle_retain", signature: .init(result: "void", parameters: ["ptr"]),
            family: .handle, lowerings: ["<retain>"]
        ),

        // MARK: 惰性引用
        BuiltinSpec(
            symbol: "pini_lazyref_create",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "ptr", "i32", "i32"]),
            family: .lazyRef, lowerings: ["lazyRefConstruct"]
        ),
        BuiltinSpec(
            symbol: "pini_lazyref_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .lazyRef, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "pini_lazyref_value", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .lazyRef, lowerings: ["lazyRefValue"]
        ),

        // MARK: 弱引用
        BuiltinSpec(
            symbol: "pini_weak_create", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .weakRef, lowerings: ["weakRefConstruct"]
        ),
        BuiltinSpec(
            symbol: "pini_weak_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .weakRef, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "pini_weak_value", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .weakRef, lowerings: ["weakRefValue"]
        ),

        // MARK: 给定块
        BuiltinSpec(
            symbol: "pini_given_get", signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i64"]),
            family: .given, lowerings: ["givenInstance", "fieldGet"]
        ),

        // MARK: 显示
        BuiltinSpec(
            symbol: "pini_cstr", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .display, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_double_to_string", signature: .init(result: "ptr", parameters: ["double"]),
            family: .display, lowerings: ["<print>"]
        ),
        BuiltinSpec(
            symbol: "pini_panic",
            signature: .init(result: "void", parameters: ["ptr"], attributes: " noreturn"),
            family: .display, lowerings: ["<panic>"]
        ),
        BuiltinSpec(
            symbol: "pini_print_lock", signature: .init(result: "void", parameters: []),
            family: .display, lowerings: ["<print>"]
        ),
        BuiltinSpec(
            symbol: "pini_print_unlock", signature: .init(result: "void", parameters: []),
            family: .display, lowerings: ["<print>"]
        ),

        // MARK: 字符
        BuiltinSpec(
            symbol: "pini_char_retain", signature: .init(result: "i64", parameters: ["i64"]),
            family: .character, lowerings: ["<retain>"]
        ),
        BuiltinSpec(
            symbol: "pini_char_release", signature: .init(result: "void", parameters: ["i64"]),
            family: .character, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "pini_char_to_heap_string", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .character, lowerings: ["interpString"]
        ),
        BuiltinSpec(
            symbol: "pini_char_equal", signature: .init(result: "i32", parameters: ["i64", "i64"]),
            family: .character, lowerings: ["binary"]
        ),
        BuiltinSpec(
            symbol: "pini_char_equal_string",
            signature: .init(result: "i32", parameters: ["i64", "ptr"]),
            family: .character, lowerings: ["binary"]
        ),
        BuiltinSpec(
            symbol: "pini_chars", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_temp_utf8_bytes", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_temp_byte_to_int", signature: .init(result: "i32", parameters: ["i8"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_temp_int_to_byte", signature: .init(result: "i8", parameters: ["i32"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_chr", signature: .init(result: "i64", parameters: ["i32"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_is_letter", signature: .init(result: "i32", parameters: ["i64"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_is_number", signature: .init(result: "i32", parameters: ["i64"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_ord", signature: .init(result: "i32", parameters: ["i64"]),
            family: .character, lowerings: ["call"]
        ),

        // MARK: string
        /// 拼接的两个入口：`concat` 的两边都带头，`append_cstr` 的右边是裸 C 串（栈缓冲 / 格式化产物）。
        /// `ownsLhs` 为真时左操作数那份引用被消耗 —— 「唯一持有就地长」的全部开关都在这个参数上。
        BuiltinSpec(
            symbol: "pini_str_concat", signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32"]),
            family: .string, lowerings: ["stringConcat"]
        ),
        BuiltinSpec(
            symbol: "pini_str_append_cstr",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32"]),
            family: .string, lowerings: ["interpString", "arrayJoin"]
        ),
        BuiltinSpec(
            symbol: "pini_str_dup", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["interpString", "arrayJoin"]
        ),
        BuiltinSpec(
            symbol: "pini_str_from_cstr", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["call"]
        ),
        /// 句柄形参位上的 Pini 串：复制一份并记 +1，指针交给 C。降载层产出 `pini.str.handle`，
        /// 发射层把它接到这里（`call` 是它的降级点，与 `fromCString` 同形）。
        BuiltinSpec(
            symbol: "pini_str_handle_new", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .stringHandle, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_str_release", signature: .init(result: "void", parameters: ["ptr"]),
            family: .string, lowerings: ["<cleanup>", "<print>"]
        ),
        BuiltinSpec(
            symbol: "pini_str_retain", signature: .init(result: "void", parameters: ["ptr"]),
            family: .string, lowerings: ["<retain>"]
        ),
        BuiltinSpec(
            symbol: "pini_string_char_at", signature: .init(result: "i64", parameters: ["ptr", "i32"]),
            family: .string, lowerings: ["subscriptGet"]
        ),
        BuiltinSpec(
            symbol: "pini_string_contains", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .string, lowerings: ["stringContains"]
        ),
        BuiltinSpec(
            symbol: "pini_string_count", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .string, lowerings: ["lenCall", "subscriptGet"]
        ),
        BuiltinSpec(
            symbol: "pini_string_index_of", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .string, lowerings: ["stringIndexOf"]
        ),
        BuiltinSpec(
            symbol: "pini_string_lower", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["stringCase"]
        ),
        BuiltinSpec(
            symbol: "pini_string_slice",
            signature: .init(result: "ptr", parameters: ["ptr", "i32", "i32", "i32", "i32"]),
            family: .string, lowerings: ["sliceCall"]
        ),
        BuiltinSpec(
            symbol: "pini_string_split", signature: .init(result: "ptr", parameters: ["ptr", "ptr"]),
            family: .string, lowerings: ["stringSplit"]
        ),
        BuiltinSpec(
            symbol: "pini_string_trim_left", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["stringTrimLeft"]
        ),
        BuiltinSpec(
            symbol: "pini_string_trim_right", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["stringTrimRight"]
        ),
        BuiltinSpec(
            symbol: "pini_string_upper", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["stringCase"]
        ),
        BuiltinSpec(
            symbol: "pini_substring", signature: .init(result: "ptr", parameters: ["ptr", "i32", "i32"]),
            family: .string, lowerings: ["stringSubstring"]
        ),

        // MARK: 名义类型
        BuiltinSpec(
            symbol: "pini_nominal_alloc", signature: .init(result: "ptr", parameters: ["i64", "i32"]),
            family: .nominal, lowerings: ["construct", "enumConstruct"]
        ),
        BuiltinSpec(
            symbol: "pini_nominal_release", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .nominal, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "pini_nominal_retain", signature: .init(result: "void", parameters: ["ptr"]),
            family: .nominal, lowerings: ["<retain>"]
        ),
        BuiltinSpec(
            symbol: "pini_slot_alloc", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .nominal, lowerings: ["<closure>"]
        ),

        // MARK: 文件 IO
        BuiltinSpec(
            symbol: "pini_append_file", signature: .init(result: "void", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileAppend"]
        ),
        BuiltinSpec(
            symbol: "pini_argv", signature: .init(result: "ptr", parameters: []),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_ensure_dir", signature: .init(result: "void", parameters: ["ptr"]),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_exists", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_is_dir", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_list_dir", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_module_root", signature: .init(result: "ptr", parameters: []),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_read_file", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .io, lowerings: ["fileRead"]
        ),
        BuiltinSpec(
            symbol: "pini_set_program_base", signature: .init(result: "void", parameters: ["ptr"]),
            family: .io, lowerings: ["<entry>"]
        ),
        BuiltinSpec(
            symbol: "pini_try_append_file", signature: .init(result: "i64", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileTryAppend"]
        ),
        BuiltinSpec(
            symbol: "pini_try_read_file", signature: .init(result: "ptr", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileTryRead"]
        ),
        BuiltinSpec(
            symbol: "pini_try_write_file", signature: .init(result: "i64", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileTryWrite"]
        ),
        BuiltinSpec(
            symbol: "pini_write_file", signature: .init(result: "void", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileWrite"]
        ),

        // MARK: 任务
        BuiltinSpec(
            symbol: "pini_task_cancel", signature: .init(result: "void", parameters: ["ptr"]),
            family: .task, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_task_detach", signature: .init(result: "void", parameters: ["ptr"]),
            family: .task, lowerings: ["detachStmt"]
        ),
        BuiltinSpec(
            symbol: "pini_task_join", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .task, lowerings: ["join"]
        ),
        BuiltinSpec(
            symbol: "pini_task_join_within", signature: .init(result: "i32", parameters: ["ptr", "i32", "ptr"]),
            family: .task, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_task_join_all", signature: .init(result: "i32", parameters: ["ptr", "i32", "ptr"]),
            family: .task, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_task_join_all_box", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .task, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_task_spawn",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "ptr", "i32", "i32"]),
            family: .task, lowerings: ["call"]
        ),

        // MARK: 阻塞等待
        BuiltinSpec(
            symbol: "pini_sleep", signature: .init(result: "void", parameters: ["i32"]),
            family: .blocking, lowerings: ["call"]
        ),

        // MARK: 让出
        BuiltinSpec(
            symbol: "pini_task_await", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .yielding, lowerings: ["<yield>"]
        ),
        BuiltinSpec(
            symbol: "pini_task_frame", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .yielding, lowerings: ["<frame>", "call"]
        ),
        BuiltinSpec(
            symbol: "pini_task_slot", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .yielding, lowerings: ["<frame>"]
        ),

        // MARK: 调度器
        BuiltinSpec(
            symbol: "pini_task_bind_sched", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .scheduler, lowerings: ["<entry>"]
        ),

        // MARK: 运行时
        BuiltinSpec(
            symbol: "pini_runtime_cleanup", signature: .init(result: "void", parameters: []),
            family: .runtime, lowerings: ["<cleanup>"]
        ),

        // MARK: 错误
        BuiltinSpec(
            symbol: "pini_cancel_error_create", signature: .init(result: "i64", parameters: ["ptr"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_error_create", signature: .init(result: "i64", parameters: ["ptr"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_error_is_cancel", signature: .init(result: "i32", parameters: ["i64"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_error_message", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_error_from_enum",
            signature: .init(result: "i64", parameters: ["i64", "i32", "ptr", "ptr"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_error_with_code",
            signature: .init(result: "i64", parameters: ["i32"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_error_code", signature: .init(result: "i32", parameters: ["i64"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "pini_error_lookup",
            signature: .init(result: "ptr", parameters: ["i32", "ptr", "ptr", "i32"]),
            family: .error, lowerings: ["call"]
        ),
    ]

    private static let bySymbol: [String: BuiltinSpec] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.symbol, $0) })

    public static func spec(for symbol: String) -> BuiltinSpec? { bySymbol[symbol] }

    /// 发射一条 `declare`；查不到即停 —— 静默跳过会产出「调用无声明」的模块。
    public static func declaration(for symbol: String) -> String {
        guard let spec = bySymbol[symbol] else {
            preconditionFailure("Builtins: \(symbol) 不在清单里；先登记再发声明")
        }
        return spec.declaration
    }
}
